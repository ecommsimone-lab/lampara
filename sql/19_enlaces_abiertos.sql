-- Ner · 19 · Enlaces que avisan cuando alguien los abre (por ejemplo, el enlace enviado a los revisores de licencias)
-- Se guarda solo: qué enlace fue (?revisores=abs, ?r=tyndale…), en qué sitio (Lámpara o Ner), tipo de dispositivo,
-- idioma y país aproximado (según la zona horaria y el idioma del navegador) y la fecha. No se guarda la IP.
-- También se registran las visitas sin cuenta al enlace normal (ref "inicio") y el botón "Para revisores" del inicio.
-- Cada vez que alguien abre un enlace de revisores (o el enlace normal desde fuera de Colombia), al equipo le llega un aviso al celular
-- (máximo uno cada 30 minutos por enlace, para no llenar de avisos). El resumen se ve en vivo al final del Tablero.
-- Supabase → SQL Editor → pegar → Run. Se puede correr aunque ya se haya corrido una versión anterior.

create table if not exists public.link_opens (
  id         bigint generated always as identity primary key,
  ref        text not null,
  host       text,
  device     text,
  lang       text,
  created_at timestamptz not null default now()
);
alter table public.link_opens add column if not exists country text;
create index if not exists link_opens_ref on public.link_opens (ref, created_at desc);
alter table public.link_opens enable row level security;   -- sin políticas: solo por las funciones de abajo

-- Nombres que se muestran en el aviso
create or replace function public.link_ref_name(r text) returns text
language sql immutable set search_path = '' as $$
  select case r when 'abs' then 'Sociedades Bíblicas (RVR1960)' when 'tyndale' then 'Tyndale (NTV)'
                when 'lockman' then 'Lockman (NBLA)' when 'revisores' then 'la página para revisores'
                when 'inicio' then 'la app (enlace normal)' else r end;
$$;

-- Registrar una apertura (lo puede llamar cualquiera, incluso sin cuenta)
drop function if exists public.log_link_open(text, text, text, text);
create or replace function public.log_link_open(p_ref text, p_host text, p_device text, p_lang text, p_country text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text := lower(trim(coalesce(p_ref, ''))); reciente boolean; t record; sitio text;
begin
  if r !~ '^[a-z0-9_-]{1,30}$' then return; end if;
  -- freno contra abusos: máximo 300 registros por enlace en una hora
  if (select count(*) from public.link_opens where ref = r and created_at > now() - interval '1 hour') >= 300 then return; end if;
  -- (para "inicio" se cuenta por país, así una visita desde Colombia no tapa la de un revisor de otro país)
  reciente := exists (select 1 from public.link_opens where ref = r and created_at > now() - interval '30 minutes'
                      and (r <> 'inicio' or coalesce(country, '') = coalesce(p_country, '')));
  insert into public.link_opens (ref, host, device, lang, country)
  values (r, left(coalesce(p_host, ''), 60), left(coalesce(p_device, ''), 20), left(coalesce(p_lang, ''), 12), left(coalesce(p_country, ''), 40));
  -- aviso al equipo (solo enlaces de revisores, y no más de uno cada 30 minutos por enlace)
  -- y para las visitas sin cuenta al enlace normal ("inicio"), solo si vienen de fuera de Colombia (posibles revisores)
  if not reciente and (r in ('abs', 'tyndale', 'lockman', 'revisores')
                       or (r = 'inicio' and coalesce(p_country, '') not in ('', 'Colombia'))) then
    sitio := case when coalesce(p_host, '') like '%lamparabiblica%' then 'Ner' when coalesce(p_host, '') like '%ecommsimone%' then 'Lámpara' else coalesce(p_host, '') end;
    for t in select user_id from public.team loop
      perform public.notify(t.user_id, null, 'link_open',
        case when r = 'inicio' then '👀 Alguien abrió la app sin cuenta' else '👀 Abrieron el enlace de ' || public.link_ref_name(r) end,
        concat_ws(' · ', nullif('Desde ' || nullif(p_country, ''), 'Desde '), nullif(p_device, ''), nullif('en ' || sitio, 'en ')),
        jsonb_build_object('ref', r));
    end loop;
  end if;
end $$;

-- Resumen para el equipo
drop function if exists public.team_link_opens();
create or replace function public.team_link_opens()
returns table (ref text, host text, veces bigint, primera timestamptz, ultima timestamptz, dispositivos text, paises text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query
    select l.ref, l.host, count(*), min(l.created_at), max(l.created_at),
           string_agg(distinct l.device, ', '), string_agg(distinct nullif(l.country, ''), ', ')
    from public.link_opens l
    group by l.ref, l.host
    order by max(l.created_at) desc
    limit 50;
end $$;

revoke all on function public.log_link_open(text, text, text, text, text) from public;
revoke all on function public.team_link_opens() from public, anon;
revoke all on function public.link_ref_name(text) from public, anon;
grant execute on function public.log_link_open(text, text, text, text, text) to anon, authenticated;
grant execute on function public.team_link_opens() to authenticated;
