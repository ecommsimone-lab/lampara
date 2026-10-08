-- Lámpara Bíblica · Amigos: @usuario, búsqueda por correo exacto o @usuario,
-- solicitudes de amistad, racha compartida con cada amigo y retos directos.
-- Requiere haber corrido antes 02_comunidad.sql.
-- Pegar completo en Supabase → SQL Editor → Run (una sola vez).

-- 1) @usuario único en el perfil
alter table public.profiles add column if not exists username text;
alter table public.profiles drop constraint if exists profiles_username_formato;
alter table public.profiles add constraint profiles_username_formato
  check (username is null or username ~ '^[a-z0-9_.]{3,20}$');
create unique index if not exists profiles_username_unico on public.profiles (username);

-- 2) Amistades: una fila por pareja; 'pending' hasta que la otra persona acepta
create table if not exists public.friendships (
  id          uuid primary key default gen_random_uuid(),
  requester   uuid not null references auth.users(id) on delete cascade,
  addressee   uuid not null references auth.users(id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending','accepted')),
  created_at  timestamptz not null default now(),
  accepted_at timestamptz,
  check (requester <> addressee)
);
create unique index if not exists friendships_pareja_unica
  on public.friendships (least(requester, addressee), greatest(requester, addressee));
alter table public.friendships enable row level security;
drop policy if exists "ver mis amistades" on public.friendships;
create policy "ver mis amistades" on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));
-- crear, aceptar y eliminar se hace solo con las funciones de abajo
revoke all on public.friendships from anon, authenticated;
grant select on public.friendships to authenticated;

-- Ayudantes (no exponen datos, solo responden sí/no)
create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.requester = a and f.addressee = b) or (f.requester = b and f.addressee = a)));
$$;
create or replace function public.is_connected(other uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select other = auth.uid()
    or exists (select 1 from public.friendships f
      where (f.requester = auth.uid() and f.addressee = other) or (f.addressee = auth.uid() and f.requester = other))
    or exists (select 1 from public.duels d
      where (d.creator = auth.uid() and d.opponent = other) or (d.opponent = auth.uid() and d.creator = other))
    or exists (select 1 from public.partners p
      where (p.user_a = auth.uid() and p.user_b = other) or (p.user_b = auth.uid() and p.user_a = other));
$$;
revoke all on function public.are_friends(uuid, uuid) from public, anon;
revoke all on function public.is_connected(uuid) from public, anon;
grant execute on function public.are_friends(uuid, uuid) to authenticated;
grant execute on function public.is_connected(uuid) to authenticated;

-- 3) Privacidad: un perfil solo lo ven sus amigos, solicitudes y rivales de esgrima
drop policy if exists "perfiles visibles" on public.profiles;
create policy "perfiles visibles" on public.profiles for select to authenticated
  using (public.is_connected(user_id));

-- 4) Actividad: la ves tú y tus amigos (para racha y días practicados)
drop policy if exists "ver mi actividad y la de mi compañero" on public.activity;
create policy "ver mi actividad y la de mi compañero" on public.activity for select to authenticated using (
  user_id = auth.uid()
  or public.are_friends(auth.uid(), user_id)
  or exists (select 1 from public.partners p where p.user_b is not null
      and ((p.user_a = auth.uid() and p.user_b = activity.user_id) or (p.user_b = auth.uid() and p.user_a = activity.user_id)))
);

-- 5) Esgrima: se puede retar directamente a un amigo
drop policy if exists "crear reto" on public.duels;
create policy "crear reto" on public.duels for insert to authenticated with check (
  auth.uid() = creator and opponent_score is null
  and (opponent is null or public.are_friends(auth.uid(), opponent))
);

-- 6) Funciones
-- Asigna un @usuario la primera vez (a partir del nombre) y lo devuelve
create or replace function public.ensure_username(p_hint text)
returns text language plpgsql security definer set search_path = '' as $$
declare cur text; base text; cand text; i int := 0;
begin
  select username into cur from public.profiles where user_id = auth.uid();
  if cur is not null then return cur; end if;
  base := left(regexp_replace(translate(lower(coalesce(p_hint, '')), 'áéíóúüñàèìòù', 'aeiouunaeiou'), '[^a-z0-9_.]', '', 'g'), 14);
  if char_length(base) < 3 then base := 'lector'; end if;
  loop
    i := i + 1;
    cand := base || lpad((floor(random() * 10000))::int::text, 4, '0');
    begin
      update public.profiles set username = cand where user_id = auth.uid() and username is null;
      if not found then return null; end if;
      return cand;
    exception when unique_violation then
      if i > 20 then raise; end if;
    end;
  end loop;
end; $$;

-- Cambiar el @usuario
create or replace function public.set_username(p_name text)
returns text language plpgsql security definer set search_path = '' as $$
declare v text := lower(trim(p_name));
begin
  if v !~ '^[a-z0-9_.]{3,20}$' then raise exception 'usuario_invalido'; end if;
  begin
    update public.profiles set username = v, updated_at = now() where user_id = auth.uid();
  exception when unique_violation then raise exception 'usuario_ocupado';
  end;
  return v;
end; $$;

-- Buscar por correo exacto o @usuario exacto (nunca devuelve correos)
create or replace function public.find_user(p_query text)
returns table (user_id uuid, display_name text, avatar_url text, username text, status text, incoming boolean)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare q text := lower(trim(p_query)); uid uuid;
begin
  if q is null or char_length(q) < 3 then return; end if;
  if position('@' in q) > 1 then
    select u.id into uid from auth.users u where lower(u.email) = q;
  else
    select p.user_id into uid from public.profiles p where p.username = ltrim(q, '@');
  end if;
  if uid is null or uid = auth.uid() then return; end if;
  return query
    select p.user_id, p.display_name, p.avatar_url, p.username, f.status, (f.addressee = auth.uid())
    from public.profiles p
    left join public.friendships f
      on (f.requester = auth.uid() and f.addressee = p.user_id) or (f.addressee = auth.uid() and f.requester = p.user_id)
    where p.user_id = uid;
end; $$;

-- Enviar solicitud (si la otra persona ya te la había enviado, quedan como amigos)
create or replace function public.send_friend_request(p_user uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare f public.friendships;
begin
  if p_user is null or p_user = auth.uid() then raise exception 'solicitud_invalida'; end if;
  select * into f from public.friendships
   where (requester = auth.uid() and addressee = p_user) or (requester = p_user and addressee = auth.uid());
  if found then
    if f.status = 'pending' and f.addressee = auth.uid() then
      update public.friendships set status = 'accepted', accepted_at = now() where id = f.id;
      return 'accepted';
    end if;
    return f.status;
  end if;
  if (select count(*) from public.friendships where requester = auth.uid() and status = 'pending') >= 50 then
    raise exception 'demasiadas_solicitudes';
  end if;
  if (select count(*) from public.friendships where status = 'accepted' and auth.uid() in (requester, addressee)) >= 300 then
    raise exception 'demasiados_amigos';
  end if;
  insert into public.friendships (requester, addressee) values (auth.uid(), p_user);
  return 'pending';
end; $$;

-- Aceptar o rechazar una solicitud recibida
create or replace function public.respond_friend(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_accept then
    update public.friendships set status = 'accepted', accepted_at = now()
     where id = p_id and addressee = auth.uid() and status = 'pending';
  else
    delete from public.friendships where id = p_id and addressee = auth.uid() and status = 'pending';
  end if;
end; $$;

-- Eliminar amigo o cancelar una solicitud enviada
create or replace function public.remove_friend(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.friendships where id = p_id and auth.uid() in (requester, addressee);
end; $$;

-- Mis amigos y solicitudes, con su perfil
create or replace function public.my_friends()
returns table (id uuid, user_id uuid, display_name text, avatar_url text, username text, status text, incoming boolean, since timestamptz)
language sql stable security definer set search_path = '' as $$
  select f.id, p.user_id, p.display_name, p.avatar_url, p.username, f.status, (f.addressee = auth.uid()),
         coalesce(f.accepted_at, f.created_at)
  from public.friendships f
  join public.profiles p on p.user_id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where auth.uid() in (f.requester, f.addressee)
  order by f.status, p.display_name;
$$;

-- Cantidad de amigos (la ves tú y tus amigos)
create or replace function public.friend_count(p_uid uuid)
returns int language sql stable security definer set search_path = '' as $$
  select case when p_uid = auth.uid() or public.are_friends(auth.uid(), p_uid)
    then (select count(*)::int from public.friendships where status = 'accepted' and p_uid in (requester, addressee))
    else null end;
$$;

revoke all on function public.ensure_username(text) from public, anon;
revoke all on function public.set_username(text) from public, anon;
revoke all on function public.find_user(text) from public, anon;
revoke all on function public.send_friend_request(uuid) from public, anon;
revoke all on function public.respond_friend(uuid, boolean) from public, anon;
revoke all on function public.remove_friend(uuid) from public, anon;
revoke all on function public.my_friends() from public, anon;
revoke all on function public.friend_count(uuid) from public, anon;
grant execute on function public.ensure_username(text) to authenticated;
grant execute on function public.set_username(text) to authenticated;
grant execute on function public.find_user(text) to authenticated;
grant execute on function public.send_friend_request(uuid) to authenticated;
grant execute on function public.respond_friend(uuid, boolean) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.my_friends() to authenticated;
grant execute on function public.friend_count(uuid) to authenticated;

-- 7) Los compañeros de racha que ya existían pasan a ser amigos
insert into public.friendships (requester, addressee, status, accepted_at)
select p.user_a, p.user_b, 'accepted', now() from public.partners p
where p.user_b is not null
on conflict do nothing;
