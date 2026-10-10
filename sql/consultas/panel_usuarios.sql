-- Lámpara Bíblica · PANEL DE USUARIOS (solo lectura: no cambia nada)
-- Supabase → SQL Editor → pegar → Run. Muestra una fila por persona, de la más reciente a la más antigua.
-- Fechas en hora de Bogotá.

with base as (
  select u.id, u.email, u.created_at, u.last_sign_in_at,
         coalesce(nullif(pf.display_name, ''), p.name, split_part(u.email, '@', 1)) as nombre,
         pf.username, p.updated_at,
         coalesce(p.state::jsonb, '{}'::jsonb) as s, (p.user_id is not null) as tiene_progreso
  from auth.users u
  left join public.progress p on p.user_id = u.id
  left join public.profiles pf on pf.user_id = u.id
),
dias as (   -- días practicados (con al menos una respuesta)
  select b.id, (k)::date as d, coalesce((b.s->'log'->k->>'n')::int, 0) as n,
         coalesce((b.s->'log'->k->>'sum')::numeric, 0) as suma
  from base b, jsonb_object_keys(case when jsonb_typeof(b.s->'log') = 'object' then b.s->'log' else '{}'::jsonb end) k
),
dias_ok as (select * from dias where n > 0),
racha as (  -- días seguidos que terminan hoy o ayer (incluye días cubiertos por escudo)
  select id, count(*) as racha from (
    select id, d, grp, max(d) over (partition by id) as ultimo,
           last_value(grp) over (partition by id order by d rows between unbounded preceding and unbounded following) as grp_ultimo
    from (
      select id, d, d - (row_number() over (partition by id order by d))::int as grp
      from (select id, d from dias_ok
            union select b.id, (x)::date from base b, jsonb_array_elements_text(coalesce(b.s->'shieldDays', '[]'::jsonb)) x) t
    ) t2
  ) g
  where ultimo >= (now() at time zone 'America/Bogota')::date - 1 and grp = grp_ultimo
  group by id
),
versos as (
  select b.id,
         count(*) filter (where (v.value->>'box')::int >= 4) as aprendidos,
         count(*) filter (where (v.value->>'box')::int between 1 and 3) as en_proceso
  from base b, jsonb_each(case when jsonb_typeof(b.s->'progress') = 'object' then b.s->'progress' else '{}'::jsonb end) v
  group by b.id
),
amigos as (
  select x.uid, count(*) as amigos from (
    select requester as uid from public.friendships where status = 'accepted'
    union all select addressee from public.friendships where status = 'accepted') x
  group by x.uid
)
select
  b.nombre,
  coalesce('@' || b.username, '') as usuario,
  b.email as correo,
  to_char(b.created_at at time zone 'America/Bogota', 'DD/MM HH24:MI') as registrado,
  case
    when not b.tiene_progreso then '1 · Solo se registró'
    when b.s->'placed' is null and not exists (select 1 from dias_ok d where d.id = b.id) then '2 · No terminó la bienvenida o la prueba'
    when not exists (select 1 from dias_ok d where d.id = b.id) then '3 · Entró pero no ha practicado'
    when (select count(*) from dias_ok d where d.id = b.id) = 1 then '4 · Practicó 1 día'
    else '5 · Volvió a practicar'
  end as paso,
  case when b.s->'placed' is null then '—'
       when (b.s->'placed'->>'skipped')::boolean then 'Desde cero'
       else (b.s->'placed'->>'level') || ' (' || coalesce(b.s->'placed'->>'score', '?') || ' %)' end as prueba,
  coalesce(b.s->'prefs'->>'ritmo',
    case when (b.s->'prefs'->>'minutes')::int <= 5 then 'tranquilo*' when (b.s->'prefs'->>'minutes')::int >= 20 then 'intensivo*'
         when b.s->'prefs' is not null then 'constante*' end, '—') as ritmo,
  (select count(*) from dias_ok d where d.id = b.id) as dias_practicados,
  coalesce(r.racha, 0) as racha,
  to_char((select max(d) from dias_ok d where d.id = b.id), 'DD/MM') as ultimo_dia_practica,
  (now() at time zone 'America/Bogota')::date - (select max(d) from dias_ok d where d.id = b.id) as dias_sin_practicar,
  coalesce((select sum(n) from dias_ok d where d.id = b.id), 0) as respuestas,
  case when (select sum(n) from dias_ok d where d.id = b.id) > 0
       then round(100 * (select sum(suma) from dias_ok d where d.id = b.id) / (select sum(n) from dias_ok d where d.id = b.id)) end as acierto_pct,
  coalesce((b.s->>'xp')::int, 0) as puntos,
  floor((1 + sqrt(1 + 0.16 * coalesce((b.s->>'xp')::int, 0))) / 2)::int as nivel,
  coalesce(v.en_proceso, 0) as en_proceso,
  coalesce(v.aprendidos, 0) as aprendidos,
  coalesce(a.amigos, 0) as amigos,
  (select count(*) from jsonb_object_keys(case when jsonb_typeof(b.s->'badges') = 'object' then b.s->'badges' else '{}'::jsonb end)) as logros,
  coalesce((b.s->>'shields')::int, 0) as escudos,
  to_char(greatest(b.last_sign_in_at, b.updated_at) at time zone 'America/Bogota', 'DD/MM HH24:MI') as ultima_actividad
from base b
left join racha r on r.id = b.id
left join versos v on v.id = b.id
left join amigos a on a.uid = b.id
order by b.created_at desc;
-- * ritmo deducido de los minutos (se registró antes de que existiera el paso de ritmo)
