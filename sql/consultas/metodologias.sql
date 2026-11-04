-- Ner · Consulta (solo lectura): qué forma de practicar escogió cada usuario
-- Tipo de práctica (Mixto, Espacios, Iniciales, Escribir, Recitar), signos de puntuación, ritmo y duración.
-- Supabase → SQL Editor → pegar → Run. No cambia nada.

with u as (
  select p.user_id,
         case coalesce(p.state::jsonb->'prefs'->>'mode', 'mixto')
           when 'mixto' then 'Mixto' when 'blanks' then 'Espacios' when 'ini' then 'Iniciales'
           when 'iniw' then 'Iniciales (escribiendo)' when 'write' then 'Escribir' when 'recite' then 'Recitar'
           else p.state::jsonb->'prefs'->>'mode' end as tipo,
         case when p.state::jsonb->'prefs'->>'punct' = 'flexible' then 'Sin signos' else 'Exacto' end as puntuacion,
         coalesce(p.state::jsonb->'prefs'->>'ritmo', '(sin elegir)') as ritmo,
         least(coalesce(nullif(p.state::jsonb->'prefs'->>'minutes', '')::int, 10), 20) as minutos
  from public.progress p
)
-- 1) Resumen por tipo de práctica
select 'Tipo de práctica' as grupo, tipo as opcion, count(*) as usuarios, round(100.0 * count(*) / sum(count(*)) over (), 0) as "%"
from u group by tipo
union all
select 'Signos de puntuación', puntuacion, count(*), round(100.0 * count(*) / sum(count(*)) over (), 0) from u group by puntuacion
union all
select 'Ritmo', ritmo, count(*), round(100.0 * count(*) / sum(count(*)) over (), 0) from u group by ritmo
union all
select 'Duración', minutos || ' min', count(*), round(100.0 * count(*) / sum(count(*)) over (), 0) from u group by minutos
order by 1, 3 desc;

-- 2) Detalle por usuario (corre solo esta parte si quieres ver quién escogió qué)
-- select coalesce(nullif(pf.display_name, ''), split_part(au.email, '@', 1)) as nombre, u.tipo, u.puntuacion, u.ritmo, u.minutos
-- from u join auth.users au on au.id = u.user_id left join public.profiles pf on pf.user_id = u.user_id
-- order by u.tipo, nombre;
