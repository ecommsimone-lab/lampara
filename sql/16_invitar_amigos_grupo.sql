-- Ner · 16 · Invitar amigos a un grupo de oración (reemplaza unirse con código)
-- Supabase → SQL Editor → pegar → Run (una sola vez).

create table if not exists public.prayer_invites (
  group_id   uuid not null references public.prayer_groups(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  invited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
alter table public.prayer_invites enable row level security;   -- solo se usa desde las funciones

-- Mis amigos y si ya están en el grupo o invitados
create or replace function public.prayer_group_invitable(p_group uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if not exists (select 1 from public.prayer_members where group_id = p_group and user_id = u) then raise exception 'no_eres_miembro'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('user_id', f.friend, 'name', public.person_name(f.friend),
             'avatar', (select pf.avatar_url from public.profiles pf where pf.user_id = f.friend),
             'status', case when exists (select 1 from public.prayer_members m where m.group_id = p_group and m.user_id = f.friend) then 'member'
                            when exists (select 1 from public.prayer_invites i where i.group_id = p_group and i.user_id = f.friend) then 'invited'
                            else 'none' end) order by public.person_name(f.friend))
    from (select case when requester = u then addressee else requester end as friend
          from public.friendships where status = 'accepted' and (requester = u or addressee = u)) f), '[]'::jsonb);
end; $$;

-- Invitar: cualquier miembro puede invitar a sus amigos
create or replace function public.prayer_group_invite(p_group uuid, p_users uuid[])
returns int language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); x uuid; n int := 0; gname text;
begin
  if not exists (select 1 from public.prayer_members where group_id = p_group and user_id = u) then raise exception 'no_eres_miembro'; end if;
  select name into gname from public.prayer_groups where id = p_group;
  foreach x in array coalesce(p_users, '{}') loop
    if public.are_friends(u, x)
       and not exists (select 1 from public.prayer_members where group_id = p_group and user_id = x)
       and not exists (select 1 from public.prayer_invites where group_id = p_group and user_id = x) then
      insert into public.prayer_invites (group_id, user_id, invited_by) values (p_group, x, u);
      perform public.notify(x, u, 'group_invite', public.person_name(u) || ' te invitó a un grupo de oración',
        'Únete a “' || gname || '” para orar juntos.', jsonb_build_object('group', p_group, 'group_name', gname));
      n := n + 1;
    end if;
  end loop;
  return n;
end; $$;

-- Mis invitaciones pendientes
create or replace function public.prayer_invites_mine()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('group_id', i.group_id, 'group_name', g.name, 'color', g.color,
           'by', i.invited_by, 'by_name', public.person_name(i.invited_by),
           'members', (select count(*) from public.prayer_members m where m.group_id = i.group_id)) order by i.created_at desc), '[]'::jsonb)
  from public.prayer_invites i join public.prayer_groups g on g.id = i.group_id where i.user_id = auth.uid();
$$;

-- Aceptar o rechazar
create or replace function public.prayer_invite_respond(p_group uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); g public.prayer_groups;
begin
  if not exists (select 1 from public.prayer_invites where group_id = p_group and user_id = u) then raise exception 'no_disponible'; end if;
  delete from public.prayer_invites where group_id = p_group and user_id = u;
  if not p_accept then return null; end if;
  insert into public.prayer_members (group_id, user_id) values (p_group, u) on conflict do nothing;
  select * into g from public.prayer_groups where id = p_group;
  return public.pr_group_row(g, u);
end; $$;

-- La invitación entra en el grupo de avisos "Amistad"
create or replace function public.notify(p_user uuid, p_actor uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare cat text; ok boolean;
begin
  if p_user is null then return; end if;
  cat := case
    when p_type in ('friend_request','friend_accepted','group_invite') then 'amistad'
    when p_type in ('duel_challenge','duel_result') then 'retos'
    when p_type in ('streak_invite','streak_accepted','streak_risk','streak_mine') then 'rachas'
    when p_type in ('cheer','prayer_pray','prayer_comment','prayer_answered') then 'animos'
    when p_type = 'reminder' then 'recordatorio' end;
  select case cat when 'amistad' then amistad when 'retos' then retos when 'rachas' then rachas
                  when 'animos' then animos when 'recordatorio' then recordatorio end
    into ok from public.notif_prefs where user_id = p_user;
  if ok is null then ok := coalesce(cat, '') <> 'recordatorio'; end if;
  if not ok then return; end if;
  insert into public.notifications (user_id, actor, type, data)
  values (p_user, p_actor, p_type, coalesce(p_data, '{}'::jsonb) || jsonb_build_object('title', p_title, 'body', p_body));
end; $$;

revoke all on function public.prayer_group_invitable(uuid) from public, anon;
revoke all on function public.prayer_group_invite(uuid, uuid[]) from public, anon;
revoke all on function public.prayer_invites_mine() from public, anon;
revoke all on function public.prayer_invite_respond(uuid, boolean) from public, anon;
grant execute on function public.prayer_group_invitable(uuid) to authenticated;
grant execute on function public.prayer_group_invite(uuid, uuid[]) to authenticated;
grant execute on function public.prayer_invites_mine() to authenticated;
grant execute on function public.prayer_invite_respond(uuid, boolean) to authenticated;
