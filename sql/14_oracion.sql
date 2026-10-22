-- Ner · 14 · Oración: grupos, peticiones (privadas, amigos o grupo), reacciones, comentarios, reportes y avisos
-- Supabase → SQL Editor → pegar → Run (una sola vez).
-- Todo se lee y se escribe por funciones seguras: nadie ve peticiones que no le corresponden
-- y las anónimas nunca revelan quién las escribió (salvo a su autor).

-- 1) Tablas
create table if not exists public.prayer_groups (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 2 and 40),
  code       text not null unique,
  color      text not null default '#2F6FED',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.prayer_members (
  group_id  uuid not null references public.prayer_groups(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  role      text not null default 'member' check (role in ('admin','member')),
  joined_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (group_id, user_id)
);
create table if not exists public.prayers (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  scope       text not null check (scope in ('private','friends','group')),
  group_id    uuid references public.prayer_groups(id) on delete cascade,
  anon        boolean not null default false,
  cat         text not null default 'fe' check (cat in ('salud','familia','trabajo','fe','estudios','gratitud')),
  body        text not null check (char_length(body) between 3 and 500),
  bg          smallint check (bg between 1 and 4),
  verse_id    text check (verse_id ~ '^[a-z0-9-]{3,30}$'),
  expires_at  timestamptz,
  answered_at timestamptz,
  answer      text check (char_length(answer) <= 500),
  hidden      boolean not null default false,
  created_at  timestamptz not null default now(),
  check ((scope = 'group') = (group_id is not null))
);
create index if not exists prayers_group_idx on public.prayers (group_id, created_at desc);
create index if not exists prayers_user_idx on public.prayers (user_id, created_at desc);
create table if not exists public.prayer_reactions (
  prayer_id  uuid not null references public.prayers(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('pray','amen','heart')),
  created_at timestamptz not null default now(),
  primary key (prayer_id, user_id, kind)
);
create table if not exists public.prayer_comments (
  id         bigint generated always as identity primary key,
  prayer_id  uuid not null references public.prayers(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create table if not exists public.prayer_reports (
  prayer_id  uuid not null references public.prayers(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  reason     text check (char_length(reason) <= 200),
  created_at timestamptz not null default now(),
  primary key (prayer_id, user_id)
);
-- sin políticas: las tablas solo se usan desde las funciones de abajo
alter table public.prayer_groups enable row level security;
alter table public.prayer_members enable row level security;
alter table public.prayers enable row level security;
alter table public.prayer_reactions enable row level security;
alter table public.prayer_comments enable row level security;
alter table public.prayer_reports enable row level security;

-- 2) Quién puede ver una petición
create or replace function public.pr_can_see(p public.prayers, u uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p.user_id = u
      or (not p.hidden and p.scope = 'friends' and public.are_friends(u, p.user_id))
      or (not p.hidden and p.scope = 'group' and exists (select 1 from public.prayer_members m where m.group_id = p.group_id and m.user_id = u));
$$;
create or replace function public.pr_is_admin(g uuid, u uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.prayer_members m where m.group_id = g and m.user_id = u and m.role = 'admin');
$$;

-- 3) Una petición como la ve quien pregunta (oculta al autor si es anónima)
create or replace function public.pr_row(p public.prayers, u uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id, 'mine', p.user_id = u,
    'author', case when p.anon and p.user_id <> u then null else p.user_id end,
    'author_name', case when p.anon and p.user_id <> u then null else public.person_name(p.user_id) end,
    'scope', p.scope, 'group_id', p.group_id, 'group_name', (select g.name from public.prayer_groups g where g.id = p.group_id),
    'anon', p.anon, 'cat', p.cat, 'body', p.body, 'bg', p.bg, 'verse_id', p.verse_id,
    'created_at', p.created_at, 'expires_at', p.expires_at, 'answered_at', p.answered_at, 'answer', p.answer,
    'pray', (select count(*) from public.prayer_reactions r where r.prayer_id = p.id and r.kind = 'pray'),
    'amen', (select count(*) from public.prayer_reactions r where r.prayer_id = p.id and r.kind = 'amen'),
    'heart', (select count(*) from public.prayer_reactions r where r.prayer_id = p.id and r.kind = 'heart'),
    'comments', (select count(*) from public.prayer_comments c where c.prayer_id = p.id),
    'my', coalesce((select jsonb_agg(r.kind) from public.prayer_reactions r where r.prayer_id = p.id and r.user_id = u), '[]'::jsonb),
    'pray_name', (select public.person_name(r.user_id) from public.prayer_reactions r where r.prayer_id = p.id and r.kind = 'pray' and r.user_id <> u order by r.created_at desc limit 1),
    'first_comment', (select jsonb_build_object('name', public.person_name(c.user_id), 'body', c.body) from public.prayer_comments c where c.prayer_id = p.id order by c.created_at limit 1),
    'can_remove', p.user_id = u or (p.scope = 'group' and public.pr_is_admin(p.group_id, u))
  );
$$;

-- 4) Lecturas
-- Feed: 'todo' (amigos + grupos), 'friends' o el id de un grupo. Nunca incluye privadas.
create or replace function public.prayer_feed(p_filter text default 'todo')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sin_sesion'; end if;
  return coalesce((
    select jsonb_agg(public.pr_row(x.p, u) order by (x.p).created_at desc)
    from (select p from public.prayers p
          where p.scope <> 'private' and public.pr_can_see(p, u)
            and (p.expires_at is null or p.expires_at > now() or (p.answered_at is not null and p.answered_at > now() - interval '14 days'))
            and (p_filter = 'todo' or (p_filter = 'friends' and p.scope = 'friends') or (p.group_id::text = p_filter))
          order by p.created_at desc limit 80) x
  ), '[]'::jsonb);
end; $$;

-- Mi diario: todas mis peticiones (privadas y compartidas)
create or replace function public.prayer_mine()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sin_sesion'; end if;
  return coalesce((select jsonb_agg(public.pr_row(x.p, u) order by (x.p).created_at desc)
                   from (select p from public.prayers p where p.user_id = u order by p.created_at desc limit 200) x), '[]'::jsonb);
end; $$;

-- Detalle: quiénes oraron, reacciones y comentarios
create or replace function public.prayer_detail(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare u uuid := auth.uid(); p public.prayers;
begin
  select * into p from public.prayers where id = p_id;
  if p.id is null or not public.pr_can_see(p, u) then raise exception 'no_disponible'; end if;
  return public.pr_row(p, u) || jsonb_build_object(
    'prayed', coalesce((select jsonb_agg(jsonb_build_object('user_id', r.user_id, 'name', public.person_name(r.user_id),
                         'avatar', (select pf.avatar_url from public.profiles pf where pf.user_id = r.user_id)) order by r.created_at)
                        from public.prayer_reactions r where r.prayer_id = p.id and r.kind = 'pray'), '[]'::jsonb),
    'comment_list', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'user_id', c.user_id, 'name', public.person_name(c.user_id), 'body', c.body,
                         'created_at', c.created_at, 'mine', c.user_id = u) order by c.created_at)
                        from public.prayer_comments c where c.prayer_id = p.id), '[]'::jsonb));
end; $$;

-- 5) Escrituras
create or replace function public.prayer_post(p_body text, p_scope text, p_group uuid, p_anon boolean, p_cat text, p_bg smallint, p_verse text, p_days int)
returns uuid language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); nid uuid; recent int;
begin
  if u is null then raise exception 'sin_sesion'; end if;
  if p_scope = 'group' and not exists (select 1 from public.prayer_members m where m.group_id = p_group and m.user_id = u) then raise exception 'no_eres_miembro'; end if;
  select count(*) into recent from public.prayers where user_id = u and created_at > now() - interval '1 day';
  if recent >= 15 then raise exception 'demasiadas_peticiones'; end if;
  insert into public.prayers (user_id, scope, group_id, anon, cat, body, bg, verse_id, expires_at)
  values (u, p_scope, case when p_scope = 'group' then p_group end, coalesce(p_anon, false) and p_scope = 'group',
          coalesce(nullif(p_cat, ''), 'fe'), trim(p_body), p_bg, nullif(p_verse, ''),
          case when coalesce(p_days, 0) > 0 then now() + make_interval(days => p_days) end)
  returning id into nid;
  return nid;
end; $$;

create or replace function public.prayer_share(p_id uuid, p_scope text, p_group uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if p_scope = 'group' and not exists (select 1 from public.prayer_members m where m.group_id = p_group and m.user_id = u) then raise exception 'no_eres_miembro'; end if;
  update public.prayers set scope = p_scope, group_id = case when p_scope = 'group' then p_group end,
         anon = case when p_scope = 'group' then anon else false end, created_at = now()
   where id = p_id and user_id = u;
end; $$;

create or replace function public.prayer_answer(p_id uuid, p_text text)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); p public.prayers; r record;
begin
  update public.prayers set answered_at = coalesce(answered_at, now()), answer = nullif(left(trim(coalesce(p_text, '')), 500), '')
   where id = p_id and user_id = u returning * into p;
  if p.id is null then raise exception 'no_disponible'; end if;
  -- avisa a quienes oraron
  for r in select distinct user_id from public.prayer_reactions where prayer_id = p.id and kind = 'pray' and user_id <> u loop
    perform public.notify(r.user_id, case when p.anon then null else u end, 'prayer_answered',
      case when p.anon then 'Dios respondió una petición' else '¡Dios respondió la petición de ' || public.person_name(u) || '!' end,
      'Gracias por orar. Toca para ver el testimonio.', jsonb_build_object('prayer', p.id));
  end loop;
end; $$;

create or replace function public.prayer_delete(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  delete from public.prayers p where p.id = p_id
     and (p.user_id = u or (p.scope = 'group' and public.pr_is_admin(p.group_id, u)));
end; $$;

create or replace function public.prayer_react(p_id uuid, p_kind text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); p public.prayers; added boolean;
begin
  select * into p from public.prayers where id = p_id;
  if p.id is null or p.scope = 'private' or not public.pr_can_see(p, u) then raise exception 'no_disponible'; end if;
  if exists (select 1 from public.prayer_reactions where prayer_id = p_id and user_id = u and kind = p_kind) then
    delete from public.prayer_reactions where prayer_id = p_id and user_id = u and kind = p_kind; added := false;
  else
    insert into public.prayer_reactions (prayer_id, user_id, kind) values (p_id, u, p_kind); added := true;
    if p_kind = 'pray' and p.user_id <> u
       and not exists (select 1 from public.notifications n where n.user_id = p.user_id and n.actor = u and n.type = 'prayer_pray' and n.data->>'prayer' = p_id::text) then
      perform public.notify(p.user_id, u, 'prayer_pray', public.person_name(u) || ' está orando por ti', left(p.body, 90), jsonb_build_object('prayer', p.id));
    end if;
  end if;
  return added;
end; $$;

create or replace function public.prayer_comment(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); p public.prayers; recent int;
begin
  select * into p from public.prayers where id = p_id;
  if p.id is null or p.scope = 'private' or not public.pr_can_see(p, u) then raise exception 'no_disponible'; end if;
  select count(*) into recent from public.prayer_comments where user_id = u and created_at > now() - interval '1 hour';
  if recent >= 30 then raise exception 'demasiados_comentarios'; end if;
  insert into public.prayer_comments (prayer_id, user_id, body) values (p_id, u, left(trim(p_body), 300));
  if p.user_id <> u then
    perform public.notify(p.user_id, u, 'prayer_comment', public.person_name(u) || ' comentó tu petición', left(trim(p_body), 120), jsonb_build_object('prayer', p.id));
  end if;
end; $$;

create or replace function public.prayer_comment_delete(p_comment bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  delete from public.prayer_comments c using public.prayers p
   where c.id = p_comment and p.id = c.prayer_id
     and (c.user_id = u or p.user_id = u or (p.scope = 'group' and public.pr_is_admin(p.group_id, u)));
end; $$;

-- Reportar: con 3 reportes la petición se oculta hasta que el administrador del grupo la revise
create or replace function public.prayer_report(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); p public.prayers; n int;
begin
  select * into p from public.prayers where id = p_id;
  if p.id is null or not public.pr_can_see(p, u) or p.user_id = u then raise exception 'no_disponible'; end if;
  insert into public.prayer_reports (prayer_id, user_id, reason) values (p_id, u, left(p_reason, 200)) on conflict do nothing;
  select count(*) into n from public.prayer_reports where prayer_id = p_id;
  if n >= 3 then update public.prayers set hidden = true where id = p_id; end if;
end; $$;

-- 6) Grupos
create or replace function public.pr_group_row(g public.prayer_groups, u uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', g.id, 'name', g.name, 'code', g.code, 'color', g.color,
    'role', (select m.role from public.prayer_members m where m.group_id = g.id and m.user_id = u),
    'members', (select count(*) from public.prayer_members m where m.group_id = g.id),
    'new', exists (select 1 from public.prayers p, public.prayer_members m
                   where m.group_id = g.id and m.user_id = u and p.group_id = g.id and p.user_id <> u and not p.hidden and p.created_at > m.last_seen),
    'reported', case when public.pr_is_admin(g.id, u) then (select count(*) from public.prayers p where p.group_id = g.id and p.hidden) else 0 end);
$$;

create or replace function public.my_prayer_groups()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(public.pr_group_row(g, auth.uid()) order by m.joined_at), '[]'::jsonb)
  from public.prayer_members m join public.prayer_groups g on g.id = m.group_id where m.user_id = auth.uid();
$$;

create or replace function public.prayer_group_create(p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); g public.prayer_groups; c text; cols text[] := array['#2F6FED','#7C5CFF','#16A36A','#D98A00','#E5484D','#2FB5A0']; n int;
begin
  if u is null then raise exception 'sin_sesion'; end if;
  select count(*) into n from public.prayer_groups where created_by = u;
  if n >= 10 then raise exception 'demasiados_grupos'; end if;
  loop
    c := 'NER-' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4));
    exit when not exists (select 1 from public.prayer_groups where code = c);
  end loop;
  insert into public.prayer_groups (name, code, color, created_by) values (left(trim(p_name), 40), c, cols[1 + floor(random()*6)::int], u) returning * into g;
  insert into public.prayer_members (group_id, user_id, role) values (g.id, u, 'admin');
  return public.pr_group_row(g, u);
end; $$;

create or replace function public.prayer_group_join(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); g public.prayer_groups;
begin
  if u is null then raise exception 'sin_sesion'; end if;
  select * into g from public.prayer_groups where code = upper(trim(p_code));
  if g.id is null then raise exception 'codigo_invalido'; end if;
  if (select count(*) from public.prayer_members where group_id = g.id) >= 300 then raise exception 'grupo_lleno'; end if;
  insert into public.prayer_members (group_id, user_id) values (g.id, u) on conflict do nothing;
  return public.pr_group_row(g, u);
end; $$;

create or replace function public.prayer_group_leave(p_group uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); next_admin uuid;
begin
  delete from public.prayer_members where group_id = p_group and user_id = u;
  -- si se fue el último administrador, el miembro más antiguo pasa a serlo; si no queda nadie, el grupo se borra
  if not exists (select 1 from public.prayer_members where group_id = p_group and role = 'admin') then
    select user_id into next_admin from public.prayer_members where group_id = p_group order by joined_at limit 1;
    if next_admin is null then delete from public.prayer_groups where id = p_group;
    else update public.prayer_members set role = 'admin' where group_id = p_group and user_id = next_admin; end if;
  end if;
end; $$;

create or replace function public.prayer_group_seen(p_group uuid)
returns void language sql security definer set search_path = '' as $$
  update public.prayer_members set last_seen = now() where group_id = p_group and user_id = auth.uid();
$$;

create or replace function public.prayer_group_members(p_group uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.prayer_members where group_id = p_group and user_id = auth.uid()) then raise exception 'no_eres_miembro'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', public.person_name(m.user_id), 'role', m.role,
                     'avatar', (select pf.avatar_url from public.profiles pf where pf.user_id = m.user_id)) order by m.role, m.joined_at)
                   from public.prayer_members m where m.group_id = p_group), '[]'::jsonb);
end; $$;

create or replace function public.prayer_group_remove(p_group uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.pr_is_admin(p_group, auth.uid()) or p_user = auth.uid() then raise exception 'no_permitido'; end if;
  delete from public.prayer_members where group_id = p_group and user_id = p_user;
end; $$;

-- Peticiones reportadas de un grupo (solo administradores): volver a mostrar o borrar
create or replace function public.prayer_group_reported(p_group uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.pr_is_admin(p_group, auth.uid()) then raise exception 'no_permitido'; end if;
  return coalesce((select jsonb_agg(public.pr_row(p, auth.uid()) || jsonb_build_object('reports', (select count(*) from public.prayer_reports r where r.prayer_id = p.id)))
                   from public.prayers p where p.group_id = p_group and p.hidden), '[]'::jsonb);
end; $$;
create or replace function public.prayer_unhide(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.prayers p set hidden = false where p.id = p_id and p.scope = 'group' and public.pr_is_admin(p.group_id, auth.uid());
  delete from public.prayer_reports r where r.prayer_id = p_id and exists (select 1 from public.prayers p where p.id = p_id and not p.hidden);
end; $$;

-- 7) Los avisos de oración entran en el grupo "Ánimos de amigos" (se pueden apagar en Perfil → Avisos)
create or replace function public.notify(p_user uuid, p_actor uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare cat text; ok boolean;
begin
  if p_user is null then return; end if;
  cat := case
    when p_type in ('friend_request','friend_accepted') then 'amistad'
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

-- 8) Permisos
do $$ declare f text; begin
  foreach f in array array[
    'pr_can_see(public.prayers, uuid)','pr_is_admin(uuid, uuid)','pr_row(public.prayers, uuid)','pr_group_row(public.prayer_groups, uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon, authenticated';
  end loop;
  foreach f in array array[
    'prayer_feed(text)','prayer_mine()','prayer_detail(uuid)','prayer_post(text, text, uuid, boolean, text, smallint, text, int)',
    'prayer_share(uuid, text, uuid)','prayer_answer(uuid, text)','prayer_delete(uuid)','prayer_react(uuid, text)',
    'prayer_comment(uuid, text)','prayer_comment_delete(bigint)','prayer_report(uuid, text)','my_prayer_groups()',
    'prayer_group_create(text)','prayer_group_join(text)','prayer_group_leave(uuid)','prayer_group_seen(uuid)',
    'prayer_group_members(uuid)','prayer_group_remove(uuid, uuid)','prayer_group_reported(uuid)','prayer_unhide(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;
