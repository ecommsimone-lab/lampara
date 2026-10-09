-- Lámpara Bíblica · Lista de amigos en el perfil.
-- Tus amigos pueden ver quiénes son tus amigos (nombre, foto y @usuario) para agregarse entre ellos.
-- Requiere haber corrido antes 03. Pegar en Supabase → SQL Editor → Run (una sola vez).

create or replace function public.friend_list(p_uid uuid)
returns table (user_id uuid, display_name text, avatar_url text, username text)
language sql stable security definer set search_path = '' as $$
  select p.user_id, p.display_name, p.avatar_url, p.username
  from public.friendships f
  join public.profiles p on p.user_id = case when f.requester = p_uid then f.addressee else f.requester end
  where f.status = 'accepted' and p_uid in (f.requester, f.addressee)
    and (p_uid = auth.uid() or public.are_friends(auth.uid(), p_uid))
  order by p.display_name
  limit 500;
$$;

revoke all on function public.friend_list(uuid) from public, anon;
grant execute on function public.friend_list(uuid) to authenticated;
