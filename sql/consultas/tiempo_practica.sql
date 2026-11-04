-- Ner · Consulta (solo lectura): cuánto tiempo eligen los usuarios para practicar y cuánto practican de verdad
-- Supabase → SQL Editor → pegar → Run. No cambia nada.

with u as (
  select p.user_id,
         coalesce(nullif(p.state::jsonb->'prefs'->>'minutes', '')::int, 10) as minutos,
         coalesce(p.state::jsonb->'prefs'->>'ritmo', '(sin elegir)') as ritmo,
         case when jsonb_typeof(p.state::jsonb->'log') = 'object' then p.state::jsonb->'log' else '{}'::jsonb end as log
  from public.progress p
),
dias as (
  select u.user_id, (u.log->k->>'n')::int as respuestas
  from u, jsonb_object_keys(u.log) k
  where k::date >= current_date - 30 and coalesce((u.log->k->>'n')::int, 0) > 0
)
select u.minutos as "minutos elegidos",
       count(distinct u.user_id) as usuarios,
       string_agg(distinct u.ritmo, ', ') as ritmos,
       count(d.user_id) as "días practicados (30 días)",
       round(avg(d.respuestas), 1) as "preguntas por día (promedio)"
from u left join dias d on d.user_id = u.user_id
group by u.minutos
order by u.minutos;
