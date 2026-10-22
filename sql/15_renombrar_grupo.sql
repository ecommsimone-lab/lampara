-- Ner · 15 · Cambiar el nombre de un grupo de oración (solo administradores)
-- Supabase → SQL Editor → pegar → Run (una sola vez).
create or replace function public.prayer_group_rename(p_group uuid, p_name text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.pr_is_admin(p_group, auth.uid()) then raise exception 'no_permitido'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'nombre_corto'; end if;
  update public.prayer_groups set name = left(trim(p_name), 40) where id = p_group;
end; $$;
revoke all on function public.prayer_group_rename(uuid, text) from public, anon;
grant execute on function public.prayer_group_rename(uuid, text) to authenticated;
