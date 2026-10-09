-- Lámpara Bíblica · Escudos de racha: regalar un escudo a un amigo.
-- Los escudos se guardan en el progreso de cada persona; aquí solo se envía el regalo como aviso.
-- Requiere haber corrido antes 03 y 04. Pegar en Supabase → SQL Editor → Run (una sola vez).

create or replace function public.send_shield(p_user uuid)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if not public.are_friends(auth.uid(), p_user) then raise exception 'no_son_amigos'; end if;
  -- máximo un escudo a la misma persona por semana, y tres al día en total
  if exists (select 1 from public.notifications where type = 'shield' and actor = auth.uid() and user_id = p_user
             and created_at > now() - interval '7 days') then
    raise exception 'escudo_reciente';
  end if;
  if (select count(*) from public.notifications where type = 'shield' and actor = auth.uid()
      and created_at > now() - interval '1 day') >= 3 then
    raise exception 'demasiados_escudos';
  end if;
  perform public.notify(p_user, auth.uid(), 'shield',
    public.person_name(auth.uid()) || ' te regaló un escudo de racha 🛡️',
    'Si un día no alcanzas a practicar, protegerá tu racha.', '{}'::jsonb);
  return 'ok';
end; $$;

revoke all on function public.send_shield(uuid) from public, anon;
grant execute on function public.send_shield(uuid) to authenticated;
