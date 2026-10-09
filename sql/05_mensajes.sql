-- Lámpara Bíblica · Mensajes personalizados entre amigos:
-- un mensaje listo o una nota propia (máximo 140 caracteres) y, si quieres, un versículo.
-- Requiere haber corrido antes 02, 03 y 04.
-- Pegar completo en Supabase → SQL Editor → Run (una sola vez).

create or replace function public.send_message(p_user uuid, p_msg int, p_note text, p_verse_id text, p_verse_ref text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  msgs text[] := array[
    '¡Vamos a practicar hoy!',
    'Estoy orando por ti.',
    'Gracias por animarme a seguir en la Palabra.',
    'Me acordé de ti con este versículo.',
    '¡Dios te bendiga hoy!',
    'Ánimo, no estás solo.'];
  note text := nullif(regexp_replace(trim(coalesce(p_note, '')), '\s+', ' ', 'g'), '');
  vid  text := nullif(trim(coalesce(p_verse_id, '')), '');
  vref text := nullif(trim(coalesce(p_verse_ref, '')), '');
  base text; title text; body text;
begin
  if not public.are_friends(auth.uid(), p_user) then raise exception 'no_son_amigos'; end if;
  if p_msg is not null and p_msg <> 0 and (p_msg < 1 or p_msg > array_length(msgs, 1)) then raise exception 'mensaje_invalido'; end if;
  if note is not null and char_length(note) > 140 then raise exception 'nota_muy_larga'; end if;
  -- el versículo viaja como identificador; quien lo recibe ve el texto desde la app, nunca un texto escrito por otra persona
  if vid is not null and vid !~ '^[a-z0-9-]{3,30}$' then raise exception 'versiculo_invalido'; end if;
  if vref is not null and (char_length(vref) > 40 or vref !~ ' [0-9]{1,3}:[0-9]{1,3}(-[0-9]{1,3})?$' or vref ~ '[<>[:cntrl:]]') then raise exception 'versiculo_invalido'; end if;
  if vid is null then vref := null; end if;
  base := case when p_msg between 1 and array_length(msgs, 1) then msgs[p_msg] end;
  if note is null and base is null and vid is null then raise exception 'mensaje_vacio'; end if;
  if (select count(*) from public.notifications where type = 'cheer' and actor = auth.uid() and user_id = p_user
        and created_at > now() - interval '1 day') >= 5 then
    raise exception 'demasiados_animos';
  end if;
  title := public.person_name(auth.uid()) || case when vid is not null then ' te envió un versículo' else ' te envió ánimo' end;
  body := coalesce(note, base, '') ;
  if vref is not null then body := case when body = '' then vref else body || ' · ' || vref end; end if;
  perform public.notify(p_user, auth.uid(), 'cheer', title, body,
    jsonb_strip_nulls(jsonb_build_object('note', note, 'msg', base, 'verse', vid, 'ref', vref)));
  return 'ok';
end; $$;

revoke all on function public.send_message(uuid, int, text, text, text) from public, anon;
grant execute on function public.send_message(uuid, int, text, text, text) to authenticated;
