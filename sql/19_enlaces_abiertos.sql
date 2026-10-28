-- Ner · 19 · Enlaces que avisan cuando alguien los abre (por ejemplo, el enlace enviado a los revisores de licencias)
-- Se guarda solo: qué enlace fue (?revisores=abs, ?r=tyndale…), en qué sitio (Lámpara o Ner), tipo de dispositivo,
-- idioma del navegador y la fecha. No se guarda la IP ni datos personales.
-- Solo el equipo (tabla "team") puede ver el resumen, en el Tablero.
-- Supabase → SQL Editor → pegar → Run (una sola vez).

create table if not exists public.link_opens (
  id         bigint generated always as identity primary key,
  ref        text not null,
  host       text,
  device     text,
  lang       text,
  created_at timestamptz not null default now()
);
create index if not exists link_opens_ref on public.link_opens (ref, created_at desc);
alter table public.link_opens enable row level security;   -- sin políticas: solo por las funciones de abajo

-- Registrar una apertura (lo puede llamar cualquiera, incluso sin cuenta)
create or replace function public.log_link_open(p_ref text, p_host text, p_device text, p_lang text)
returns void language plpgsql security definer set search_path = '' as $$
declare r text := lower(trim(coalesce(p_ref, '')));
begin
  if r !~ '^[a-z0-9_-]{1,30}$' then return; end if;
  -- freno contra abusos: máximo 300 registros por enlace en una hora
  if (select count(*) from public.link_opens where ref = r and created_at > now() - interval '1 hour') >= 300 then return; end if;
  insert into public.link_opens (ref, host, device, lang)
  values (r, left(coalesce(p_host, ''), 60), left(coalesce(p_device, ''), 20), left(coalesce(p_lang, ''), 12));
end $$;

-- Resumen para el equipo
create or replace function public.team_link_opens()
returns table (ref text, host text, veces bigint, primera timestamptz, ultima timestamptz, dispositivos text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_team() then raise exception 'no_equipo'; end if;
  return query
    select l.ref, l.host, count(*), min(l.created_at), max(l.created_at), string_agg(distinct l.device, ', ')
    from public.link_opens l
    group by l.ref, l.host
    order by max(l.created_at) desc
    limit 50;
end $$;

revoke all on function public.log_link_open(text, text, text, text) from public;
revoke all on function public.team_link_opens() from public, anon;
grant execute on function public.log_link_open(text, text, text, text) to anon, authenticated;
grant execute on function public.team_link_opens() to authenticated;
