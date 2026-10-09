-- Lámpara Bíblica · Logros visibles para tus amigos.
-- Cada persona publica en su perfil la lista de logros que ha ganado (solo ella puede cambiarla;
-- la ven sus amigos, solicitudes y rivales de esgrima, igual que el nombre y la foto).
-- Pegar en Supabase → SQL Editor → Run (una sola vez).

alter table public.profiles add column if not exists badges jsonb not null default '[]'::jsonb;
alter table public.profiles drop constraint if exists profiles_badges_formato;
alter table public.profiles add constraint profiles_badges_formato
  check (jsonb_typeof(badges) = 'array' and jsonb_array_length(badges) <= 200 and pg_column_size(badges) < 16000);
