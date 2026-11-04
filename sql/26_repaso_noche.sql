-- Ner · 26 · Aviso opcional "Repaso de la noche" (8 p. m. hora local)
-- Si la persona lo activa en Ajustes → Avisos y ese día empezó un versículo nuevo, le llega un aviso
-- para repasarlo antes de dormir (el sueño ayuda a fijar lo que se aprendió en el día).
-- Supabase → SQL Editor → pegar → Run (una sola vez).

alter table public.notif_prefs add column if not exists repaso_noche boolean not null default false;

create or replace function public.run_night_review()
returns void language plpgsql security definer set search_path = '' as $$
declare r record; localnow timestamp; t0 bigint; n int;
begin
  for r in select np.user_id, np.tz, p.state::jsonb as s
           from public.notif_prefs np join public.progress p on p.user_id = np.user_id
           where np.repaso_noche loop
    begin localnow := now() at time zone coalesce(r.tz, 'America/Bogota');
    exception when others then localnow := now() at time zone 'America/Bogota'; end;
    if extract(hour from localnow) <> 20 then continue; end if;
    -- inicio del día de la persona, en milisegundos (como lo guarda la app)
    t0 := (extract(epoch from (date_trunc('day', localnow) at time zone coalesce(r.tz, 'America/Bogota'))) * 1000)::bigint;
    select count(*) into n
      from jsonb_each(case when jsonb_typeof(r.s->'progress') = 'object' then r.s->'progress' else '{}'::jsonb end) v
      where coalesce((v.value->>'introduced')::numeric, 0) >= t0
        and coalesce((v.value->>'reps')::int, 0) > 0
        and coalesce((v.value->>'placed')::boolean, false) = false
        and coalesce((v.value->>'known')::boolean, false) = false
        and coalesce((v.value->>'last')::numeric, 0) < extract(epoch from now()) * 1000 - 2 * 3600 * 1000;
    if n > 0 and not exists (select 1 from public.notifications x where x.user_id = r.user_id and x.type = 'night_review' and x.created_at > now() - interval '20 hours') then
      perform public.notify(r.user_id, null, 'night_review', '🌙 Repaso de la noche',
        case when n = 1 then 'Repasa el versículo que empezaste hoy. Toma 1 minuto y te ayuda a no olvidarlo.'
             else 'Repasa los ' || n || ' versículos que empezaste hoy. Toma 1 minuto y te ayuda a no olvidarlos.' end, '{}'::jsonb);
    end if;
  end loop;
end; $$;

revoke all on function public.run_night_review() from public, anon, authenticated;

select cron.unschedule('lampara-repaso-noche') where exists (select 1 from cron.job where jobname = 'lampara-repaso-noche');
select cron.schedule('lampara-repaso-noche', '5 * * * *', 'select public.run_night_review()');
