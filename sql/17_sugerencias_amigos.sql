-- Ner · 17 · Sugerencias de amigos (como en Instagram)
-- Sugiere personas de la app: primero las que tienen amigos en común contigo,
-- después las que han practicado hace poco. Nunca muestra a quien ya es tu amigo,
-- a quien tiene una solicitud pendiente contigo, ni a quien apagó "Aparecer en sugerencias".
-- Solo se ve el nombre, la foto y el @usuario (nunca el correo).
-- Supabase → SQL Editor → pegar → Run (una sola vez).

-- 1) Cada persona decide si aparece en sugerencias (por defecto sí)
alter table public.profiles add column if not exists in_suggestions boolean not null default true;

-- 2) Lista de sugerencias para quien llama
create or replace function public.friend_suggestions(p_limit int default 20)
returns table (user_id uuid, display_name text, avatar_url text, username text, mutual int, mutual_name text)
language sql stable security definer set search_path = '' as $$
  with me as (select auth.uid() as id),
  linked as (     -- amigos y solicitudes (enviadas o recibidas)
    select case when f.requester = (select id from me) then f.addressee else f.requester end as uid, f.status
    from public.friendships f where (select id from me) in (f.requester, f.addressee)),
  my_friends as (select uid as fid from linked where status = 'accepted'),
  fof as (        -- amigos de mis amigos
    select case when f.requester = mf.fid then f.addressee else f.requester end as uid, mf.fid
    from public.friendships f join my_friends mf on mf.fid in (f.requester, f.addressee)
    where f.status = 'accepted'),
  mut as (select uid, count(distinct fid)::int as n, min(fid::text)::uuid as one from fof group by uid),
  act as (select a.user_id, max(a.day) as last from public.activity a where a.day >= current_date - 30 group by a.user_id)
  select p.user_id, p.display_name, p.avatar_url, p.username, coalesce(m.n, 0),
         (select pp.display_name from public.profiles pp where pp.user_id = m.one)
  from public.profiles p
  left join mut m on m.uid = p.user_id
  left join act on act.user_id = p.user_id
  where (select id from me) is not null
    and p.user_id <> (select id from me)
    and p.in_suggestions
    and coalesce(trim(p.display_name), '') <> ''
    and p.user_id not in (select uid from linked)
  order by coalesce(m.n, 0) desc, act.last desc nulls last, random()
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

-- 3) Ver y cambiar mi preferencia
create or replace function public.my_in_suggestions() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select in_suggestions from public.profiles where user_id = auth.uid()), true);
$$;
create or replace function public.set_in_suggestions(p_on boolean) returns void
language sql security definer set search_path = '' as $$
  update public.profiles set in_suggestions = coalesce(p_on, true) where user_id = auth.uid();
$$;

revoke all on function public.friend_suggestions(int) from public, anon;
revoke all on function public.my_in_suggestions() from public, anon;
revoke all on function public.set_in_suggestions(boolean) from public, anon;
grant execute on function public.friend_suggestions(int) to authenticated;
grant execute on function public.my_in_suggestions() to authenticated;
grant execute on function public.set_in_suggestions(boolean) to authenticated;
