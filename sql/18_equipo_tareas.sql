-- Ner · 18 · Equipo: asignar responsables, fecha límite y prioridad (matriz de Eisenhower)
-- Prioridades: 'ui' = Urgente e importante (hacer ya) · 'i' = Importante, no urgente (planear)
--              'u' = Urgente, no importante (resolver rápido) · 'n' = Ni urgente ni importante (cuando haya tiempo)
-- A quien le asignan algo le llega un aviso. Requiere haber corrido 11 y 13.
-- Supabase → SQL Editor → pegar → Run (una sola vez).

-- 1) Columnas nuevas
alter table public.feedback
  add column if not exists asignados uuid[] not null default '{}',
  add column if not exists fecha_limite date,
  add column if not exists prioridad text;
alter table public.feedback drop constraint if exists feedback_prioridad_ok;
alter table public.feedback add constraint feedback_prioridad_ok
  check (prioridad is null or prioridad in ('ui','i','u','n')) not valid;

-- 2) Nombres de las personas del equipo (para asignar y filtrar)
create or replace function public.team_members()
returns table (user_id uuid, nombre text, email text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query
    select t.user_id,
           coalesce(nullif(p.display_name, ''), split_part(u.email, '@', 1))::text,
           u.email::text
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
declare antes uuid[];
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  select f.asignados into antes from public.feedback f where f.id::text = p_id;
  update public.feedback
     set estado = p_estado::public.estado_feedback,
         nota = nullif(left(trim(coalesce(p_nota, '')), 2000), ''),
         asignados = coalesce(p_asignados, '{}'),
         fecha_limite = p_fecha,
         prioridad = nullif(p_prioridad, ''),
         actualizado_por = left(p_name, 80),
         actualizado_at = now()
   where id::text = p_id;
  perform public.team_notify_assigned(p_id,
    array(select x from unnest(coalesce(p_asignados, '{}')) x where not (x = any(coalesce(antes, '{}')))), p_name);
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
  perform public.team_notify_assigned(nid, p_asignados, p_name);
  return nid;
end $$;

revoke all on function public.team_members() from public, anon;
revoke all on function public.team_notify_assigned(text, uuid[], text) from public, anon, authenticated;
revoke all on function public.team_plan(text, text, text, text, uuid[], date, text) from public, anon;
revoke all on function public.team_add_plan(text, text, text, text, uuid[], date, text) from public, anon;
grant execute on function public.team_members() to authenticated;
grant execute on function public.team_plan(text, text, text, text, uuid[], date, text) to authenticated;
grant execute on function public.team_add_plan(text, text, text, text, uuid[], date, text) to authenticated;
