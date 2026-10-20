-- Ner · 12 · Aviso "Tu racha está en riesgo" (9 p. m.) y recordatorio activado por defecto
-- Supabase → SQL Editor → pegar → Run (una sola vez). Reemplaza la tarea de cada hora con una versión que incluye el aviso nuevo.

-- Las cuentas nuevas guardan el recordatorio diario activado (la app lo crea al entrar por primera vez)
alter table public.notif_prefs alter column recordatorio set default true;

-- El aviso nuevo pertenece al grupo "rachas" (se puede apagar en Perfil → Avisos)
create or replace function public.notify(p_user uuid, p_actor uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare cat text; ok boolean;
begin
  if p_user is null then return; end if;
  cat := case
    when p_type in ('friend_request','friend_accepted') then 'amistad'
    when p_type in ('duel_challenge','duel_result') then 'retos'
    when p_type in ('streak_invite','streak_accepted','streak_risk','streak_mine') then 'rachas'
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

-- Días seguidos con práctica (o escudo) que terminan en un día dado
create or replace function public.streak_until(p_user uuid, p_day date)
returns int language plpgsql stable security definer set search_path = '' as $$
declare n int := 0; d date := p_day;
begin
  while n < 1000 and exists (select 1 from public.activity a where a.user_id = p_user and a.day = d) loop
    n := n + 1; d := d - 1;
  end loop;
  return n;
end; $$;

create or replace function public.run_scheduled_notifications()
returns void language plpgsql security definer set search_path = '' as $$
declare r record; tz text; localnow timestamp; today date; n int;
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
  -- racha juntos en riesgo: tu amigo ya practicó hoy y tú todavía no (8 p. m.)
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
  -- tu racha personal en riesgo: llevas 2 días o más seguidos y hoy aún no practicas (9 p. m.)
  for r in select distinct a.user_id from public.activity a where a.day >= current_date - 2 loop
    tz := coalesce((select p.tz from public.notif_prefs p where p.user_id = r.user_id), 'America/Bogota');
    begin
      localnow := now() at time zone tz;
    exception when others then localnow := now() at time zone 'America/Bogota'; end;
    today := localnow::date;
    if extract(hour from localnow) = 21
       and not exists (select 1 from public.activity a where a.user_id = r.user_id and a.day = today)
       and not exists (select 1 from public.notifications n where n.user_id = r.user_id and n.type = 'streak_mine' and n.created_at > now() - interval '20 hours') then
      n := public.streak_until(r.user_id, today - 1);
      if n >= 2 then
        perform public.notify(r.user_id, null, 'streak_mine', 'Tu racha de ' || n || ' días está en riesgo',
          'Aún no has practicado hoy. Unos minutos bastan para no perderla.', jsonb_build_object('days', n));
      end if;
    end if;
  end loop;
end; $$;

revoke all on function public.streak_until(uuid, date) from public, anon, authenticated;
revoke all on function public.run_scheduled_notifications() from public, anon, authenticated;
