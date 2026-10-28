-- Ner · 20 · Detalle de aperturas (para la sección "Revisores" en el Perfil del equipo)
-- Muestra cada vez que se abrió la demo o la página para revisores: fecha y hora, país aproximado, dispositivo y sitio.
-- Requiere haber corrido el 19. Supabase → SQL Editor → pegar → Run (una sola vez).

create or replace function public.team_link_events(p_limit int default 30)
returns table (ref text, host text, device text, country text, lang text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query
    select l.ref, l.host, l.device, l.country, l.lang, l.created_at
    from public.link_opens l
    where l.ref in ('demo', 'revisores', 'abs', 'tyndale', 'lockman')
    order by l.created_at desc
    limit least(greatest(coalesce(p_limit, 30), 1), 100);
end $$;

revoke all on function public.team_link_events(int) from public, anon;
grant execute on function public.team_link_events(int) to authenticated;
