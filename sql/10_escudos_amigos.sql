-- Lámpara Bíblica · Los escudos de racha también protegen las rachas con amigos.
-- Marca los días cubiertos por un escudo (no se cuentan como días practicados).
-- Pegar en Supabase → SQL Editor → Run (una sola vez).

alter table public.activity add column if not exists shield boolean not null default false;
