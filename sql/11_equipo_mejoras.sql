-- Ner · 11 · Equipo: lista de mejoras y arreglos dentro de la app
-- Solo los correos de la tabla "team" ven la sección "Mejoras" en su Perfil.
-- Ahí aparecen los comentarios que dejan los usuarios y lo que agregue el equipo,
-- con su estado (⚪ 🔵 🟡 🟢 ⚫) y una nota.
-- Supabase → SQL Editor → pegar → Run (una sola vez).

-- 1) Quiénes son el equipo
create table if not exists public.team (
  user_id uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.team enable row level security;   -- sin políticas: solo la leen las funciones de abajo

insert into public.team (user_id)
select id from auth.users
where lower(email) in ('2992in@gmail.com', 'juliana1507@hotmail.com', 'crex13rodriguez@gmail.com')
on conflict do nothing;

-- 2) Columnas nuevas en feedback
alter table public.feedback
  add column if not exists origen text not null default 'usuario',   -- 'usuario' o 'equipo'
  add column if not exists actualizado_por text,
  add column if not exists actualizado_at timestamptz;

-- 3) Funciones (todas comprueban que quien llama sea del equipo)
create or replace function public.is_team() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team where user_id = auth.uid());
$$;

create or replace function public.team_items() returns setof public.feedback
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query select * from public.feedback order by created_at desc limit 500;
end $$;

create or replace function public.team_add(p_kind text, p_message text, p_nota text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  if coalesce(length(trim(p_message)), 0) < 3 then raise exception 'mensaje_vacio'; end if;
  insert into public.feedback (user_id, kind, message, context, name, origen, nota, actualizado_por, actualizado_at)
  values (auth.uid(), p_kind, left(trim(p_message), 2000), 'Equipo', left(p_name, 80), 'equipo',
          nullif(left(trim(coalesce(p_nota, '')), 2000), ''), left(p_name, 80), now());
end $$;

create or replace function public.team_update(p_id text, p_estado text, p_nota text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  update public.feedback
     set estado = p_estado::public.estado_feedback,
         nota = nullif(left(trim(coalesce(p_nota, '')), 2000), ''),
         actualizado_por = left(p_name, 80),
         actualizado_at = now()
   where id::text = p_id;
end $$;

revoke all on function public.team_items() from public, anon;
revoke all on function public.team_add(text, text, text, text) from public, anon;
revoke all on function public.team_update(text, text, text, text) from public, anon;
grant execute on function public.is_team() to authenticated;
grant execute on function public.team_items() to authenticated;
grant execute on function public.team_add(text, text, text, text) to authenticated;
grant execute on function public.team_update(text, text, text, text) to authenticated;

-- Para agregar a alguien más al equipo después:
--   insert into public.team (user_id) select id from auth.users where lower(email) = 'correo@ejemplo.com';
-- Para quitarlo:
--   delete from public.team where user_id = (select id from auth.users where lower(email) = 'correo@ejemplo.com');
