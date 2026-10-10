-- Lámpara Bíblica · EMBUDO: cuántas personas llegan a cada paso (solo lectura)
-- Supabase → SQL Editor → pegar → Run.

with base as (
  select u.id, u.created_at, coalesce(p.state::jsonb, '{}'::jsonb) as s, (p.user_id is not null) as tiene_progreso
  from auth.users u left join public.progress p on p.user_id = u.id
),
dias as (
  select b.id, (k)::date as d
  from base b, jsonb_object_keys(case when jsonb_typeof(b.s->'log') = 'object' then b.s->'log' else '{}'::jsonb end) k
  where coalesce((b.s->'log'->k->>'n')::int, 0) > 0
),
por_usuario as (
  select b.id, b.tiene_progreso, (b.s->'placed' is not null) as termino_bienvenida,
         (select count(*) from dias d where d.id = b.id) as n_dias,
         (select max(d) from dias d where d.id = b.id) as ultimo,
         exists (select 1 from public.friendships f where f.status = 'accepted' and b.id in (f.requester, f.addressee)) as tiene_amigo
  from base b
),
hoy as (select (now() at time zone 'America/Bogota')::date as d),
pasos as (
  select 1 as orden, 'Se registraron' as paso, count(*) as personas from por_usuario
  union all select 2, 'Terminaron la bienvenida (prueba o desde cero)', count(*) filter (where termino_bienvenida or n_dias > 0) from por_usuario
  union all select 3, 'Practicaron al menos 1 día', count(*) filter (where n_dias >= 1) from por_usuario
  union all select 4, 'Volvieron otro día (2 o más días)', count(*) filter (where n_dias >= 2) from por_usuario
  union all select 5, 'Practicaron 7 días o más', count(*) filter (where n_dias >= 7) from por_usuario
  union all select 6, 'Activos en los últimos 7 días', count(*) filter (where ultimo >= (select d from hoy) - 6) from por_usuario
  union all select 7, 'Practicaron hoy', count(*) filter (where ultimo = (select d from hoy)) from por_usuario
  union all select 8, 'Tienen al menos 1 amigo', count(*) filter (where tiene_amigo) from por_usuario
)
select paso, personas,
       case when (select personas from pasos where orden = 1) > 0
            then round(100.0 * personas / (select personas from pasos where orden = 1)) || ' %' end as de_los_registrados
from pasos order by orden;
