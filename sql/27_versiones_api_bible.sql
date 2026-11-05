-- Ner · 27 · Texto de NTV y NBLA desde API.Bible (lo guarda la función "biblia")
-- Tabla privada: solo la función "biblia" la lee y la escribe (con la llave de servicio, nunca desde la app).
-- El texto se renueva cada 14 días, como pide API.Bible.
-- Supabase → SQL Editor → pegar → Run (una sola vez).

create table if not exists public.bible_cache (
  version    text not null,            -- ntv | nbla
  verse_id   text not null,            -- id del versículo en la app (ej. jn-3-16)
  passage    text,                     -- id de API.Bible (ej. JHN.3.16)
  text       text not null,
  copyright  text,
  fums       text,                     -- token para reportar cada vez que se muestra (FUMS)
  fetched_at timestamptz not null default now(),
  primary key (version, verse_id)
);
alter table public.bible_cache enable row level security;   -- sin políticas: nadie la lee desde la app
