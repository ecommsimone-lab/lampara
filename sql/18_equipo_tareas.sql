-- Ner · 18 · Equipo: responsables, fecha límite, prioridad (matriz de Eisenhower), papelera e historial
-- Prioridades: 'ui' = Urgente e importante (hacer ya) · 'i' = Importante, no urgente (planear)
--              'u' = Urgente, no importante (resolver rápido) · 'n' = Ni urgente ni importante (cuando haya tiempo)
-- A quien le asignan algo le llega un aviso. Cada cambio queda en el historial (quién y cuándo).
-- Los descartados se pueden mover a la papelera; desde ahí se restauran o se borran para siempre.
-- Requiere haber corrido 11 y 13.
-- Supabase → SQL Editor → pegar → Run (una sola vez).

-- 1) Columnas nuevas
alter table public.feedback
  add column if not exists asignados uuid[] not null default '{}',
  add column if not exists fecha_limite date,
  add column if not exists prioridad text,
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_por text;
alter table public.feedback drop constraint if exists feedback_prioridad_ok;
alter table public.feedback add constraint feedback_prioridad_ok
  check (prioridad is null or prioridad in ('ui','i','u','n')) not valid;

-- Historial: una fila por cada cambio
create table if not exists public.feedback_historial (
  id          bigint generated always as identity primary key,
  feedback_id text not null,
  user_id     uuid default auth.uid(),
  quien       text,
  accion      text not null,      -- creado, estado, prioridad, asignados, fecha, nota, papelera, restaurado
  detalle     text,
  created_at  timestamptz not null default now()
);
create index if not exists feedback_historial_item on public.feedback_historial (feedback_id, created_at desc);
alter table public.feedback_historial enable row level security;   -- sin políticas: solo por las funciones

create or replace function public.team_log(p_id text, p_accion text, p_detalle text, p_name text)
returns void language sql security definer set search_path = '' as $$
  insert into public.feedback_historial (feedback_id, user_id, quien, accion, detalle)
  values (p_id, auth.uid(), left(coalesce(nullif(p_name, ''), 'Alguien'), 80), p_accion, left(p_detalle, 300));
$$;

-- La lista del equipo ya no muestra lo que está en la papelera
create or replace function public.team_items() returns setof public.feedback
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query select * from public.feedback where deleted_at is null order by created_at desc limit 500;
end $$;

-- 2) Nombres de las personas del equipo (para asignar y filtrar)
drop function if exists public.team_members();
create or replace function public.team_members()
returns table (user_id uuid, nombre text, email text, avatar_url text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query
    select t.user_id,
           coalesce(nullif(p.display_name, ''), split_part(u.email, '@', 1))::text,
           u.email::text,
           p.avatar_url::text
    from public.team t
    join auth.users u on u.id = t.user_id
    left join public.profiles p on p.user_id = t.user_id
    order by 2;
end $$;

-- 3) Aviso a quienes asignan (no a quien asigna)
create or replace function public.team_notify_assigned(p_id text, p_nuevos uuid[], p_name text)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid; msg text;
begin
  select left(f.message, 90) into msg from public.feedback f where f.id::text = p_id;
  foreach u in array coalesce(p_nuevos, '{}') loop
    if u <> auth.uid() and exists (select 1 from public.team t where t.user_id = u) then
      perform public.notify(u, auth.uid(), 'team_assigned',
        coalesce(nullif(p_name, ''), 'Alguien del equipo') || ' te asignó una tarea', coalesce(msg, ''),
        jsonb_build_object('item', p_id));
    end if;
  end loop;
end $$;

-- 4) Guardar responsables, fecha y prioridad (junto con estado y nota)
create or replace function public.team_plan(p_id text, p_estado text, p_nota text, p_name text,
                                            p_asignados uuid[], p_fecha date, p_prioridad text)
returns void language plpgsql security definer set search_path = '' as $$
declare f public.feedback; v_nota text := nullif(left(trim(coalesce(p_nota, '')), 2000), ''); asg uuid[] := coalesce(p_asignados, '{}');
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  select * into f from public.feedback where id::text = p_id;
  if not found then raise exception 'no_existe'; end if;
  update public.feedback
     set estado = p_estado::public.estado_feedback, nota = v_nota, asignados = asg, fecha_limite = p_fecha,
         prioridad = nullif(p_prioridad, ''), actualizado_por = left(p_name, 80), actualizado_at = now()
   where id::text = p_id;
  -- historial: solo lo que cambió
  if f.estado::text is distinct from p_estado then perform public.team_log(p_id, 'estado', p_estado, p_name); end if;
  if f.prioridad is distinct from nullif(p_prioridad, '') then perform public.team_log(p_id, 'prioridad', coalesce(nullif(p_prioridad, ''), ''), p_name); end if;
  if (select array_agg(x order by x) from unnest(coalesce(f.asignados, '{}')) x) is distinct from (select array_agg(x order by x) from unnest(asg) x)
    then perform public.team_log(p_id, 'asignados', array_to_string(asg, ','), p_name); end if;
  if f.fecha_limite is distinct from p_fecha then perform public.team_log(p_id, 'fecha', coalesce(p_fecha::text, ''), p_name); end if;
  if f.nota is distinct from v_nota then perform public.team_log(p_id, 'nota', left(coalesce(v_nota, ''), 120), p_name); end if;
  perform public.team_notify_assigned(p_id,
    array(select x from unnest(asg) x where not (x = any(coalesce(f.asignados, '{}')))), p_name);
end $$;

-- 5) Agregar ya con responsables, fecha y prioridad
create or replace function public.team_add_plan(p_kind text, p_message text, p_nota text, p_name text,
                                                p_asignados uuid[], p_fecha date, p_prioridad text)
returns text language plpgsql security definer set search_path = '' as $$
declare nid text;
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  if coalesce(length(trim(p_message)), 0) < 3 then raise exception 'mensaje_vacio'; end if;
  insert into public.feedback (user_id, kind, message, context, name, email, user_agent, origen, nota,
                               actualizado_por, actualizado_at, asignados, fecha_limite, prioridad)
  values (auth.uid(), p_kind, left(trim(p_message), 2000), 'Equipo', left(coalesce(p_name, ''), 80),
          (select u.email from auth.users u where u.id = auth.uid()), 'Equipo', 'equipo',
          nullif(left(trim(coalesce(p_nota, '')), 2000), ''), left(coalesce(p_name, ''), 80), now(),
          coalesce(p_asignados, '{}'), p_fecha, nullif(p_prioridad, ''))
  returning id::text into nid;
  perform public.team_log(nid, 'creado', null, p_name);
  perform public.team_notify_assigned(nid, p_asignados, p_name);
  return nid;
end $$;

-- 6) Papelera (solo para lo descartado) e historial
create or replace function public.team_trash_move(p_ids text[], p_name text) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  for r in update public.feedback set deleted_at = now(), deleted_por = left(p_name, 80)
           where id::text = any(p_ids) and deleted_at is null and estado::text = '⚫ descartado'
           returning id::text as id loop
    perform public.team_log(r.id, 'papelera', null, p_name); n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.team_trash() returns setof public.feedback
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query select * from public.feedback where deleted_at is not null order by deleted_at desc limit 500;
end $$;
create or replace function public.team_restore(p_id text, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  update public.feedback set deleted_at = null, deleted_por = null where id::text = p_id and deleted_at is not null;
  if found then perform public.team_log(p_id, 'restaurado', null, p_name); end if;
end $$;
-- Borrar para siempre (solo lo que ya está en la papelera)
create or replace function public.team_purge(p_ids text[]) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  with d as (delete from public.feedback where id::text = any(p_ids) and deleted_at is not null returning id::text as id)
  select count(*) into n from d;
  delete from public.feedback_historial h where h.feedback_id = any(p_ids)
    and not exists (select 1 from public.feedback f where f.id::text = h.feedback_id);
  return n;
end $$;
create or replace function public.team_history(p_id text)
returns table (quien text, accion text, detalle text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query select h.quien, h.accion, h.detalle, h.created_at from public.feedback_historial h
    where h.feedback_id = p_id order by h.created_at desc limit 100;
end $$;

revoke all on function public.team_members() from public, anon;
revoke all on function public.team_notify_assigned(text, uuid[], text) from public, anon, authenticated;
revoke all on function public.team_plan(text, text, text, text, uuid[], date, text) from public, anon;
revoke all on function public.team_add_plan(text, text, text, text, uuid[], date, text) from public, anon;
revoke all on function public.team_log(text, text, text, text) from public, anon, authenticated;
revoke all on function public.team_trash_move(text[], text) from public, anon;
revoke all on function public.team_trash() from public, anon;
revoke all on function public.team_restore(text, text) from public, anon;
revoke all on function public.team_purge(text[]) from public, anon;
revoke all on function public.team_history(text) from public, anon;
grant execute on function public.team_members() to authenticated;
grant execute on function public.team_trash_move(text[], text) to authenticated;
grant execute on function public.team_trash() to authenticated;
grant execute on function public.team_restore(text, text) to authenticated;
grant execute on function public.team_purge(text[]) to authenticated;
grant execute on function public.team_history(text) to authenticated;
grant execute on function public.team_plan(text, text, text, text, uuid[], date, text) to authenticated;
grant execute on function public.team_add_plan(text, text, text, text, uuid[], date, text) to authenticated;
