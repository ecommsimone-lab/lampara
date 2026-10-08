-- Lámpara Bíblica · Notificaciones: avisos dentro de la app y en el celular,
-- preferencias de cada persona, racha juntos por invitación, ánimos entre amigos,
-- recordatorio diario y aviso de racha en riesgo.
-- Requiere haber corrido antes Comunidad (02) y Amigos (03).
-- Pegar completo en Supabase → SQL Editor → Run (una sola vez).

-- 0) Extensiones: pg_net (llamar la función que envía al celular) y pg_cron (tareas cada hora)
do $$ begin
  create extension if not exists pg_net with schema extensions;
exception when others then raise notice 'No se pudo activar pg_net: %', sqlerrm; end $$;
do $$ begin
  create extension if not exists pg_cron with schema pg_catalog;
exception when others then raise notice 'No se pudo activar pg_cron: %', sqlerrm; end $$;

-- 1) Configuración del envío (las llaves del celular las crea la función "push"; nadie más las ve)
create table if not exists public.push_config (
  id            int primary key default 1 check (id = 1),
  fn_url        text not null,
  anon_key      text not null,
  subject       text not null,
  vapid_public  text,
  vapid_private text
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;
insert into public.push_config (id, fn_url, anon_key, subject)
values (1, 'https://vapcakmrzyjazjhfjeqa.supabase.co/functions/v1/push', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZhcGNha21yenlqYXpqaGZqZXFhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE0ODA2MzksImV4cCI6MjEwNzA1NjYzOX0.neh231Jbi_NxP9_JpypPo24Xv3ygWPupGG3iK-JO9Mg', 'https://ecommsimone-lab.github.io/lampara/')
on conflict (id) do update set fn_url = excluded.fn_url, anon_key = excluded.anon_key, subject = excluded.subject;

create or replace function public.vapid_public_key()
returns text language sql stable security definer set search_path = '' as $$
  select vapid_public from public.push_config where id = 1;
$$;

-- 2) Preferencias: cada persona elige qué avisos recibe
create table if not exists public.notif_prefs (
  user_id      uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  amistad      boolean not null default true,
  retos        boolean not null default true,
  rachas       boolean not null default true,
  animos       boolean not null default true,
  recordatorio boolean not null default false,
  hora         smallint not null default 19 check (hora between 0 and 23),
  tz           text not null default 'America/Bogota' check (char_length(tz) <= 60),
  updated_at   timestamptz not null default now()
);
alter table public.notif_prefs enable row level security;
drop policy if exists "ver mis preferencias" on public.notif_prefs;
drop policy if exists "crear mis preferencias" on public.notif_prefs;
drop policy if exists "editar mis preferencias" on public.notif_prefs;
create policy "ver mis preferencias" on public.notif_prefs for select to authenticated using (auth.uid() = user_id);
create policy "crear mis preferencias" on public.notif_prefs for insert to authenticated with check (auth.uid() = user_id);
create policy "editar mis preferencias" on public.notif_prefs for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
revoke all on public.notif_prefs from anon;
grant select, insert, update on public.notif_prefs to authenticated;

-- 3) Celulares y navegadores donde cada persona activó los avisos
create table if not exists public.push_subs (
  endpoint   text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subs_usuario on public.push_subs (user_id);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;

create or replace function public.save_push_sub(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 then raise exception 'suscripcion_invalida'; end if;
  delete from public.push_subs where endpoint = p_endpoint;
  if (select count(*) from public.push_subs where user_id = auth.uid()) >= 10 then
    delete from public.push_subs where endpoint = (select endpoint from public.push_subs where user_id = auth.uid() order by created_at limit 1);
  end if;
  insert into public.push_subs (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth);
end; $$;
create or replace function public.remove_push_sub(p_endpoint text)
returns void language sql security definer set search_path = '' as $$
  delete from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- 4) Los avisos
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  actor      uuid references auth.users(id) on delete cascade,
  type       text not null,
  data       jsonb not null default '{}'::jsonb,
  read_at    timestamptz,
  pushed_at  timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_usuario on public.notifications (user_id, created_at desc);
alter table public.notifications enable row level security;
drop policy if exists "ver mis avisos" on public.notifications;
drop policy if exists "borrar mis avisos" on public.notifications;
create policy "ver mis avisos" on public.notifications for select to authenticated using (auth.uid() = user_id);
create policy "borrar mis avisos" on public.notifications for delete to authenticated using (auth.uid() = user_id);
revoke all on public.notifications from anon, authenticated;
grant select, delete on public.notifications to authenticated;

create or replace function public.mark_notifications_read()
returns void language sql security definer set search_path = '' as $$
  update public.notifications set read_at = now() where user_id = auth.uid() and read_at is null;
$$;

-- Nombre visible de una persona (para el texto del aviso)
create or replace function public.person_name(p uuid)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(nullif((select display_name from public.profiles where user_id = p), ''), 'Alguien');
$$;

-- Crea un aviso solo si la persona tiene activado ese tipo
create or replace function public.notify(p_user uuid, p_actor uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare cat text; ok boolean;
begin
  if p_user is null then return; end if;
  cat := case
    when p_type in ('friend_request','friend_accepted') then 'amistad'
    when p_type in ('duel_challenge','duel_result') then 'retos'
    when p_type in ('streak_invite','streak_accepted','streak_risk') then 'rachas'
    when p_type = 'cheer' then 'animos'
    when p_type = 'reminder' then 'recordatorio' end;
  select case cat when 'amistad' then amistad when 'retos' then retos when 'rachas' then rachas
                  when 'animos' then animos when 'recordatorio' then recordatorio end
    into ok from public.notif_prefs where user_id = p_user;
  if ok is null then ok := coalesce(cat, '') <> 'recordatorio'; end if;
  if not ok then return; end if;
  insert into public.notifications (user_id, actor, type, data)
  values (p_user, p_actor, p_type, coalesce(p_data, '{}'::jsonb) || jsonb_build_object('title', p_title, 'body', p_body));
end; $$;

-- Al crear un aviso, se pide a la función "push" que lo envíe al celular
create or replace function public.push_on_notification()
returns trigger language plpgsql security definer set search_path = '' as $$
declare c public.push_config;
begin
  if not exists (select 1 from public.push_subs where user_id = new.user_id) then return new; end if;
  select * into c from public.push_config where id = 1;
  begin
    perform net.http_post(
      url := c.fn_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || c.anon_key, 'apikey', c.anon_key),
      body := jsonb_build_object('id', new.id)
    );
  exception when others then null; -- si falla el envío, el aviso igual queda en la app
  end;
  return new;
end; $$;
drop trigger if exists enviar_al_celular on public.notifications;
create trigger enviar_al_celular after insert on public.notifications
  for each row execute function public.push_on_notification();

-- 5) Avisos de amistad
create or replace function public.on_friendship_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    perform public.notify(new.addressee, new.requester, 'friend_request',
      public.person_name(new.requester) || ' quiere ser tu amigo', 'Abre Lámpara para aceptar o rechazar.', '{}'::jsonb);
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'accepted' then
    perform public.notify(new.requester, new.addressee, 'friend_accepted',
      public.person_name(new.addressee) || ' aceptó tu solicitud', 'Ahora son amigos. Invítalo a una racha juntos.', '{}'::jsonb);
  end if;
  return new;
end; $$;
drop trigger if exists avisos_amistad on public.friendships;
create trigger avisos_amistad after insert or update of status on public.friendships
  for each row execute function public.on_friendship_change();

-- 6) Racha juntos por invitación
alter table public.friendships add column if not exists streak text check (streak in ('pending','accepted'));
alter table public.friendships add column if not exists streak_by uuid references auth.users(id) on delete set null;
alter table public.friendships add column if not exists streak_since date;

create or replace function public.invite_streak(p_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare f public.friendships; other uuid;
begin
  select * into f from public.friendships where id = p_id and status = 'accepted' and auth.uid() in (requester, addressee);
  if not found then raise exception 'no_son_amigos'; end if;
  other := case when f.requester = auth.uid() then f.addressee else f.requester end;
  if f.streak = 'accepted' then return 'accepted'; end if;
  if f.streak = 'pending' then
    if f.streak_by <> auth.uid() then  -- la otra persona ya me había invitado: se acepta
      update public.friendships set streak = 'accepted', streak_since = current_date where id = p_id;
      perform public.notify(other, auth.uid(), 'streak_accepted', public.person_name(auth.uid()) || ' aceptó la racha juntos',
        'Practiquen los dos cada día para que suba.', jsonb_build_object('friendship', p_id));
      return 'accepted';
    end if;
    return 'pending';
  end if;
  update public.friendships set streak = 'pending', streak_by = auth.uid(), streak_since = null where id = p_id;
  perform public.notify(other, auth.uid(), 'streak_invite', public.person_name(auth.uid()) || ' te invitó a una racha juntos',
    'Si aceptan, la racha sube cada día que los dos practiquen.', jsonb_build_object('friendship', p_id));
  return 'pending';
end; $$;

create or replace function public.respond_streak(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare f public.friendships;
begin
  select * into f from public.friendships
   where id = p_id and status = 'accepted' and streak = 'pending' and streak_by <> auth.uid() and auth.uid() in (requester, addressee);
  if not found then return; end if;
  if p_accept then
    update public.friendships set streak = 'accepted', streak_since = current_date where id = p_id;
    perform public.notify(f.streak_by, auth.uid(), 'streak_accepted', public.person_name(auth.uid()) || ' aceptó la racha juntos',
      'Practiquen los dos cada día para que suba.', jsonb_build_object('friendship', p_id));
  else
    update public.friendships set streak = null, streak_by = null, streak_since = null where id = p_id;
  end if;
end; $$;

create or replace function public.end_streak(p_id uuid)
returns void language sql security definer set search_path = '' as $$
  update public.friendships set streak = null, streak_by = null, streak_since = null
   where id = p_id and auth.uid() in (requester, addressee);
$$;

-- my_friends ahora incluye el estado de la racha
drop function if exists public.my_friends();
create function public.my_friends()
returns table (id uuid, user_id uuid, display_name text, avatar_url text, username text, status text, incoming boolean, since timestamptz,
               streak text, streak_mine boolean, streak_since date)
language sql stable security definer set search_path = '' as $$
  select f.id, p.user_id, p.display_name, p.avatar_url, p.username, f.status, (f.addressee = auth.uid()),
         coalesce(f.accepted_at, f.created_at), f.streak, (f.streak_by = auth.uid()), f.streak_since
  from public.friendships f
  join public.profiles p on p.user_id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where auth.uid() in (f.requester, f.addressee)
  order by f.status, p.display_name;
$$;

-- 7) Avisos de retos 1 a 1
create or replace function public.on_duel_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_first uuid; other uuid; my int; their int; myms int; theirms int; res text;
begin
  if tg_op = 'INSERT' then
    if new.opponent is not null then
      perform public.notify(new.opponent, new.creator, 'duel_challenge', public.person_name(new.creator) || ' te retó a un esgrima bíblico',
        'Responde las mismas 10 preguntas y descubre quién gana.', jsonb_build_object('duel', new.id));
    end if;
  elsif new.creator_score is not null and new.opponent_score is not null
        and (old.creator_score is null or old.opponent_score is null) then
    -- avisar a quien jugó primero
    if old.creator_score is not null then
      v_first := new.creator; other := new.opponent; my := new.creator_score; their := new.opponent_score; myms := new.creator_ms; theirms := new.opponent_ms;
    else
      v_first := new.opponent; other := new.creator; my := new.opponent_score; their := new.creator_score; myms := new.opponent_ms; theirms := new.creator_ms;
    end if;
    res := case when my > their or (my = their and myms < theirms) then 'Ganaste ' || my || '–' || their
                when my = their and myms = theirms then 'Empataron ' || my || '–' || their
                else 'Perdiste ' || my || '–' || their end;
    perform public.notify(v_first, other, 'duel_result', public.person_name(other) || ' ya jugó tu esgrima',
      res || '. Toca para ver el resultado.', jsonb_build_object('duel', new.id));
  end if;
  return new;
end; $$;
drop trigger if exists avisos_retos on public.duels;
create trigger avisos_retos after insert or update on public.duels
  for each row execute function public.on_duel_change();

-- 8) Ánimos entre amigos (máximo 3 al día a la misma persona)
create or replace function public.send_cheer(p_user uuid, p_msg int)
returns text language plpgsql security definer set search_path = '' as $$
declare msgs text[] := array[
  '¡Vamos a practicar hoy!',
  'Estoy orando por ti.',
  '«Esforzaos y cobrad ánimo… Jehová tu Dios es el que va contigo» (Deuteronomio 31:6).',
  'Gracias por animarme a seguir en la Palabra.'];
begin
  if not public.are_friends(auth.uid(), p_user) then raise exception 'no_son_amigos'; end if;
  if p_msg < 1 or p_msg > array_length(msgs, 1) then raise exception 'mensaje_invalido'; end if;
  if (select count(*) from public.notifications where type = 'cheer' and actor = auth.uid() and user_id = p_user
        and created_at > now() - interval '1 day') >= 3 then
    raise exception 'demasiados_animos';
  end if;
  perform public.notify(p_user, auth.uid(), 'cheer', public.person_name(auth.uid()) || ' te envió ánimo', msgs[p_msg], '{}'::jsonb);
  return 'ok';
end; $$;

-- 9) Cada hora: recordatorio diario y racha en riesgo (a las 8 p. m. hora local)
create or replace function public.run_scheduled_notifications()
returns void language plpgsql security definer set search_path = '' as $$
declare r record; tz text; localnow timestamp; today date; other uuid;
begin
  -- recordatorio diario a la hora que eligió cada persona
  for r in select * from public.notif_prefs where recordatorio loop
    begin
      localnow := now() at time zone r.tz;
    exception when others then localnow := now() at time zone 'America/Bogota'; end;
    today := localnow::date;
    if extract(hour from localnow) = r.hora
       and not exists (select 1 from public.activity a where a.user_id = r.user_id and a.day = today)
       and not exists (select 1 from public.notifications n where n.user_id = r.user_id and n.type = 'reminder' and n.created_at > now() - interval '20 hours') then
      perform public.notify(r.user_id, null, 'reminder', 'Es hora de tu práctica', 'Unos minutos con la Palabra hoy. «Lámpara es a mis pies tu palabra» (Salmos 119:105).', '{}'::jsonb);
    end if;
  end loop;
  -- racha en riesgo: tu amigo ya practicó hoy y tú todavía no
  for r in select f.id, x.me, case when x.me = f.requester then f.addressee else f.requester end as friend
           from public.friendships f cross join lateral (values (f.requester), (f.addressee)) as x(me)
           where f.status = 'accepted' and f.streak = 'accepted' loop
    tz := coalesce((select p.tz from public.notif_prefs p where p.user_id = r.me), 'America/Bogota');
    begin
      localnow := now() at time zone tz;
    exception when others then localnow := now() at time zone 'America/Bogota'; end;
    today := localnow::date;
    if extract(hour from localnow) = 20
       and exists (select 1 from public.activity a where a.user_id = r.friend and a.day = today)
       and not exists (select 1 from public.activity a where a.user_id = r.me and a.day = today)
       and not exists (select 1 from public.notifications n where n.user_id = r.me and n.type = 'streak_risk' and n.actor = r.friend and n.created_at > now() - interval '20 hours') then
      perform public.notify(r.me, r.friend, 'streak_risk', 'Tu racha con ' || public.person_name(r.friend) || ' está en riesgo',
        public.person_name(r.friend) || ' ya practicó hoy. ¡Te toca a ti!', jsonb_build_object('friendship', r.id));
    end if;
  end loop;
end; $$;

do $$ begin
  perform cron.schedule('lampara-avisos', '0 * * * *', 'select public.run_scheduled_notifications()');
exception when others then raise notice 'No se pudo programar la tarea cada hora: %', sqlerrm; end $$;

-- 10) Permisos de las funciones
revoke all on function public.vapid_public_key() from public, anon;
revoke all on function public.save_push_sub(text, text, text) from public, anon;
revoke all on function public.remove_push_sub(text) from public, anon;
revoke all on function public.mark_notifications_read() from public, anon;
revoke all on function public.person_name(uuid) from public, anon, authenticated;
revoke all on function public.notify(uuid, uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.push_on_notification() from public, anon, authenticated;
revoke all on function public.on_friendship_change() from public, anon, authenticated;
revoke all on function public.on_duel_change() from public, anon, authenticated;
revoke all on function public.invite_streak(uuid) from public, anon;
revoke all on function public.respond_streak(uuid, boolean) from public, anon;
revoke all on function public.end_streak(uuid) from public, anon;
revoke all on function public.my_friends() from public, anon;
revoke all on function public.send_cheer(uuid, int) from public, anon;
revoke all on function public.run_scheduled_notifications() from public, anon, authenticated;
grant execute on function public.vapid_public_key() to authenticated;
grant execute on function public.save_push_sub(text, text, text) to authenticated;
grant execute on function public.remove_push_sub(text) to authenticated;
grant execute on function public.mark_notifications_read() to authenticated;
grant execute on function public.invite_streak(uuid) to authenticated;
grant execute on function public.respond_streak(uuid, boolean) to authenticated;
grant execute on function public.end_streak(uuid) to authenticated;
grant execute on function public.my_friends() to authenticated;
grant execute on function public.send_cheer(uuid, int) to authenticated;
