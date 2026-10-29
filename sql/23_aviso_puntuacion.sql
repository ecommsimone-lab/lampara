-- Ner · 23 · Aviso a todos los usuarios: ahora eligen si practicar con o sin signos de puntuación
-- Se envía a cada usuario (le aparece en Avisos y, si activó las notificaciones, le llega al celular).
-- No se repite: si ya lo recibió, no se le vuelve a enviar. Tampoco a quien ya eligió en la bienvenida.
-- Supabase → SQL Editor → pegar → Run (una sola vez).

do $$
declare u record; n int := 0;
begin
  for u in
    select au.id from auth.users au
    left join public.progress p on p.user_id = au.id
    where coalesce(p.state::jsonb->'prefs'->>'punct', '') = ''
      and not exists (select 1 from public.notifications x
                      where x.user_id = au.id and x.type = 'app_update' and x.data->>'feature' = 'punct')
  loop
    perform public.notify(u.id, null, 'app_update',
      '✨ Novedad: tú eliges cómo escribir los versículos',
      'Ahora puedes practicar con o sin signos de puntuación (las tildes siempre cuentan). Elige aquí o cámbialo cuando quieras en Perfil → Práctica.',
      jsonb_build_object('feature', 'punct'));
    n := n + 1;
  end loop;
  raise notice 'Aviso enviado a % usuarios', n;
end $$;
