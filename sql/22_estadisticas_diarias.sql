-- Ner · 22 · Estadísticas por día para los gráficos del Panel de control (solo para el equipo)
-- Registros por día y personas que practicaron cada día (según la tabla "activity"), en hora de Bogotá.
-- Solo lectura. Supabase → SQL Editor → pegar → Run (una sola vez).

create or replace function public.team_daily_stats(p_days int default 30)
returns table (dia date, registros int, activos int)
language plpgsql stable security definer set search_path = '' as $$
declare n int := least(greatest(coalesce(p_days, 30), 7), 120);
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query
    with dias as (
      select generate_series((now() at time zone 'America/Bogota')::date - (n - 1), (now() at time zone 'America/Bogota')::date, interval '1 day')::date as d
    )
    select d.d,
           (select count(*)::int from auth.users u where (u.created_at at time zone 'America/Bogota')::date = d.d),
           (select count(distinct a.user_id)::int from public.activity a where a.day = d.d)
    from dias d
    order by d.d;
end $$;

revoke all on function public.team_daily_stats(int) from public, anon;
grant execute on function public.team_daily_stats(int) to authenticated;
