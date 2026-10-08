-- Lámpara Bíblica · Comunidad: perfiles públicos, actividad diaria,
-- racha compartida, esgrima bíblico por turnos y fotos de perfil.
-- Pegar completo en Supabase → SQL Editor → Run (una sola vez).

-- 1) Perfil visible para otros usuarios (nombre y foto)
create table if not exists public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 40),
  avatar_url   text,
  updated_at   timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "perfiles visibles" on public.profiles;
drop policy if exists "crear mi perfil" on public.profiles;
drop policy if exists "editar mi perfil" on public.profiles;
create policy "perfiles visibles" on public.profiles for select to authenticated using (true);
create policy "crear mi perfil"   on public.profiles for insert to authenticated with check (auth.uid() = user_id);
create policy "editar mi perfil"  on public.profiles for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
revoke all on public.profiles from anon;
grant select, insert, update on public.profiles to authenticated;

-- 2) Compañeros de racha (dos personas unidas por un código)
create table if not exists public.partners (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  user_a     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  user_b     uuid references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.partners enable row level security;
drop policy if exists "ver mis compañeros" on public.partners;
drop policy if exists "crear invitación" on public.partners;
drop policy if exists "terminar compañía" on public.partners;
create policy "ver mis compañeros" on public.partners for select to authenticated using (auth.uid() in (user_a, user_b));
create policy "crear invitación"   on public.partners for insert to authenticated with check (auth.uid() = user_a and user_b is null);
create policy "terminar compañía"  on public.partners for delete to authenticated using (auth.uid() in (user_a, user_b));
revoke all on public.partners from anon;
grant select, insert, delete on public.partners to authenticated;

-- 3) Días en que cada persona practicó (para la racha compartida)
create table if not exists public.activity (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  day     date not null,
  primary key (user_id, day)
);
alter table public.activity enable row level security;
drop policy if exists "ver mi actividad y la de mi compañero" on public.activity;
drop policy if exists "registrar mi actividad" on public.activity;
create policy "ver mi actividad y la de mi compañero" on public.activity for select to authenticated using (
  user_id = auth.uid() or exists (
    select 1 from public.partners p
    where p.user_b is not null
      and ((p.user_a = auth.uid() and p.user_b = activity.user_id)
        or (p.user_b = auth.uid() and p.user_a = activity.user_id))
  )
);
create policy "registrar mi actividad" on public.activity for insert to authenticated with check (auth.uid() = user_id);
revoke all on public.activity from anon;
grant select, insert on public.activity to authenticated;

-- 4) Esgrima bíblico por turnos
create table if not exists public.duels (
  id             uuid primary key default gen_random_uuid(),
  code           text not null unique,
  creator        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  opponent       uuid references auth.users(id) on delete cascade,
  questions      jsonb not null,
  creator_score  int,
  creator_ms     int,
  opponent_score int,
  opponent_ms    int,
  created_at     timestamptz not null default now()
);
alter table public.duels enable row level security;
drop policy if exists "ver mis retos" on public.duels;
drop policy if exists "crear reto" on public.duels;
create policy "ver mis retos" on public.duels for select to authenticated using (auth.uid() in (creator, opponent));
create policy "crear reto"    on public.duels for insert to authenticated with check (auth.uid() = creator and opponent is null and opponent_score is null);
revoke all on public.duels from anon;
grant select, insert on public.duels to authenticated;

-- 5) Funciones para unirse con un código y guardar el resultado del reto
create or replace function public.join_partner(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  -- solo un compañero activo por persona
  if exists (select 1 from public.partners where user_b is not null and auth.uid() in (user_a, user_b)) then
    raise exception 'ya_tienes_companero';
  end if;
  update public.partners set user_b = auth.uid()
   where code = upper(p_code) and user_b is null and user_a <> auth.uid()
  returning id into v;
  return v;
end; $$;

create or replace function public.join_duel(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.duels where code = upper(p_code) and (creator = auth.uid() or opponent = auth.uid());
  if v is not null then return v; end if;
  update public.duels set opponent = auth.uid()
   where code = upper(p_code) and opponent is null and creator <> auth.uid()
     and created_at > now() - interval '7 days'
  returning id into v;
  return v;
end; $$;

create or replace function public.submit_duel(p_id uuid, p_score int, p_ms int)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_score < 0 or p_score > 20 or p_ms < 0 then raise exception 'resultado_invalido'; end if;
  update public.duels set creator_score = p_score, creator_ms = p_ms
   where id = p_id and creator = auth.uid() and creator_score is null;
  update public.duels set opponent_score = p_score, opponent_ms = p_ms
   where id = p_id and opponent = auth.uid() and opponent_score is null;
end; $$;

revoke all on function public.join_partner(text) from public, anon;
revoke all on function public.join_duel(text) from public, anon;
revoke all on function public.submit_duel(uuid, int, int) from public, anon;
grant execute on function public.join_partner(text) to authenticated;
grant execute on function public.join_duel(text) to authenticated;
grant execute on function public.submit_duel(uuid, int, int) to authenticated;

-- 6) Fotos de perfil (carpeta por usuario, máximo 1 MB, solo imágenes)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "ver mi foto" on storage.objects;
drop policy if exists "subir mi foto" on storage.objects;
drop policy if exists "cambiar mi foto" on storage.objects;
drop policy if exists "borrar mi foto" on storage.objects;
-- (la lectura pública de las fotos la da el bucket público; esta regla permite reemplazarla)
create policy "ver mi foto" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "subir mi foto" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "cambiar mi foto" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "borrar mi foto" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
