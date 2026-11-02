-- Ner · Diagnóstico (solo lectura): ¿a quién le faltan días de práctica en su progreso?
-- Compara dos registros que la app guarda por separado cada vez que alguien practica:
--   · "activity": un registro por día practicado (no se borra)
--   · "progress": el progreso completo de la persona (lo que se sobrescribía cuando había dos dispositivos abiertos)
-- Supabase → SQL Editor → pegar → Run. No cambia nada.

with prog as (
  select p.user_id, p.updated_at,
         (select max(k::date) from jsonb_object_keys(case when jsonb_typeof(p.state::jsonb->'log') = 'object' then p.state::jsonb->'log' else '{}'::jsonb end) k
           where coalesce((p.state::jsonb->'log'->k->>'n')::int, 0) > 0) as ultimo_en_progreso
  from public.progress p
),
act as (
  select a.user_id, max(a.day) as ultimo_en_actividad,
         count(*) filter (where a.day >= current_date - 30) as dias_30
  from public.activity a group by a.user_id
),
faltan as (
  select a.user_id, count(*) as dias_que_faltan, string_agg(to_char(a.day, 'DD Mon'), ', ' order by a.day) as cuales
  from public.activity a
  join public.progress p on p.user_id = a.user_id
  where coalesce((p.state::jsonb->'log'->(a.day::text)->>'n')::int, 0) = 0
  group by a.user_id
)
select coalesce(nullif(pf.display_name, ''), split_part(u.email, '@', 1)) as nombre,
       act.ultimo_en_actividad, prog.ultimo_en_progreso,
       coalesce(f.dias_que_faltan, 0) as dias_que_faltan, f.cuales,
       prog.updated_at at time zone 'America/Bogota' as progreso_guardado
from auth.users u
left join public.profiles pf on pf.user_id = u.id
left join prog on prog.user_id = u.id
left join act on act.user_id = u.id
left join faltan f on f.user_id = u.id
where act.user_id is not null
order by coalesce(f.dias_que_faltan, 0) desc, act.ultimo_en_actividad desc nulls last;
