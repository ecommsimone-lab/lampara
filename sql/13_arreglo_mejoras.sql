-- Ner · 13 · Arreglo: agregar mejoras desde la sección del equipo
-- Permite los tipos nuevos (arreglo, mejora) y llena todas las columnas al guardar.
-- Supabase → SQL Editor → pegar → Run (una sola vez).

do $$ declare c record; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.feedback'::regclass and contype = 'c' and pg_get_constraintdef(oid) ~* 'kind' loop
    execute format('alter table public.feedback drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.feedback add constraint feedback_kind_ok
  check (kind in ('idea','problema','contenido','otro','arreglo','mejora')) not valid;

create or replace function public.team_add(p_kind text, p_message text, p_nota text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  if coalesce(length(trim(p_message)), 0) < 3 then raise exception 'mensaje_vacio'; end if;
  insert into public.feedback (user_id, kind, message, context, name, email, user_agent, origen, nota, actualizado_por, actualizado_at)
  values (auth.uid(), p_kind, left(trim(p_message), 2000), 'Equipo', left(coalesce(p_name, ''), 80),
          (select u.email from auth.users u where u.id = auth.uid()), 'Equipo', 'equipo',
          nullif(left(trim(coalesce(p_nota, '')), 2000), ''), left(coalesce(p_name, ''), 80), now());
end $$;
revoke all on function public.team_add(text, text, text, text) from public, anon;
grant execute on function public.team_add(text, text, text, text) to authenticated;
