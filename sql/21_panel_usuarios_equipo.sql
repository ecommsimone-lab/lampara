-- Ner · 21 · Panel de usuarios dentro del Tablero (solo para el equipo)
-- Es la misma información de la consulta "PANEL DE USUARIOS", pero como función: el Tablero la muestra
-- a Gabriel, Juliana y Cristian sin tener que entrar a Supabase. Solo lectura: no cambia nada.
-- Supabase → SQL Editor → pegar → Run (una sola vez).

create or replace function public.team_users_panel()
returns table (
  user_id uuid, nombre text, usuario text, correo text, avatar_url text,
  registrado timestamptz, paso int, ritmo text, dias_practicados int, racha int,
  ultimo_dia date, respuestas int, acierto int, puntos int, nivel int,
  en_proceso int, aprendidos int, amigos int, logros int, escudos int, ultima_actividad timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query
  with base as (
    select u.id, u.email::text as email, u.created_at, u.last_sign_in_at,
           coalesce(nullif(pf.display_name, ''), p.name, split_part(u.email, '@', 1))::text as nombre,
           pf.username::text as username, pf.avatar_url::text as avatar_url, p.updated_at,
           coalesce(p.state::jsonb, '{}'::jsonb) as s, (p.user_id is not null) as tiene_progreso
    from auth.users u
    left join public.progress p on p.user_id = u.id
    left join public.profiles pf on pf.user_id = u.id
  ),
  dias as (
    select b.id, (k)::date as d, coalesce((b.s->'log'->k->>'n')::int, 0) as n,
           coalesce((b.s->'log'->k->>'sum')::numeric, 0) as suma
    from base b, jsonb_object_keys(case when jsonb_typeof(b.s->'log') = 'object' then b.s->'log' else '{}'::jsonb end) k
  ),
  dias_ok as (select * from dias where dias.n > 0),
  resumen as (
    select d.id, count(*)::int as dias, max(d.d) as ultimo, sum(d.n)::int as resp,
           case when sum(d.n) > 0 then round(100 * sum(d.suma) / sum(d.n))::int end as acierto
    from dias_ok d group by d.id
  ),
  racha as (
    select g.id, count(*)::int as racha from (
      select t2.id, t2.d, t2.grp, max(t2.d) over (partition by t2.id) as ultimo,
             last_value(t2.grp) over (partition by t2.id order by t2.d rows between unbounded preceding and unbounded following) as grp_ultimo
      from (
        select t.id, t.d, t.d - (row_number() over (partition by t.id order by t.d))::int as grp
        from (select dd.id, dd.d from dias_ok dd
              union select b.id, (x)::date from base b, jsonb_array_elements_text(coalesce(b.s->'shieldDays', '[]'::jsonb)) x) t
      ) t2
    ) g
    where g.ultimo >= (now() at time zone 'America/Bogota')::date - 1 and g.grp = g.grp_ultimo
    group by g.id
  ),
  versos as (
    select b.id,
           (count(*) filter (where (v.value->>'box')::int >= 4))::int as aprendidos,
           (count(*) filter (where (v.value->>'box')::int between 1 and 3))::int as en_proceso
    from base b, jsonb_each(case when jsonb_typeof(b.s->'progress') = 'object' then b.s->'progress' else '{}'::jsonb end) v
    group by b.id
  ),
  amigos as (
    select x.uid, count(*)::int as amigos from (
      select f.requester as uid from public.friendships f where f.status = 'accepted'
      union all select f.addressee from public.friendships f where f.status = 'accepted') x
    group by x.uid
  )
  select
    b.id, b.nombre, b.username, b.email, b.avatar_url, b.created_at,
    case
      when not b.tiene_progreso then 1
      when b.s->'placed' is null and rs.id is null then 2
      when rs.id is null then 3
      when rs.dias = 1 then 4
      else 5
    end,
    coalesce(b.s->'prefs'->>'ritmo',
      case when (b.s->'prefs'->>'minutes')::int <= 5 then 'tranquilo' when (b.s->'prefs'->>'minutes')::int >= 20 then 'intensivo'
           when b.s->'prefs' is not null then 'constante' end, ''),
    coalesce(rs.dias, 0), coalesce(r.racha, 0), rs.ultimo, coalesce(rs.resp, 0), rs.acierto,
    coalesce((b.s->>'xp')::int, 0),
    floor((1 + sqrt(1 + 0.16 * coalesce((b.s->>'xp')::int, 0))) / 2)::int,
    coalesce(v.en_proceso, 0), coalesce(v.aprendidos, 0), coalesce(a.amigos, 0),
    (select count(*) from jsonb_object_keys(case when jsonb_typeof(b.s->'badges') = 'object' then b.s->'badges' else '{}'::jsonb end))::int,
    coalesce((b.s->>'shields')::int, 0),
    greatest(b.last_sign_in_at, b.updated_at)
  from base b
  left join resumen rs on rs.id = b.id
  left join racha r on r.id = b.id
  left join versos v on v.id = b.id
  left join amigos a on a.uid = b.id
  order by b.created_at desc;
end $$;

revoke all on function public.team_users_panel() from public, anon;
grant execute on function public.team_users_panel() to authenticated;
