-- Texto de aviso sin el nombre de la app (sirve igual para cualquier versión).
-- Pegar en Supabase → SQL Editor → Run (una sola vez).

create or replace function public.on_friendship_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    perform public.notify(new.addressee, new.requester, 'friend_request',
      public.person_name(new.requester) || ' quiere ser tu amigo', 'Abre la app para aceptar o rechazar.', '{}'::jsonb);
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'accepted' then
    perform public.notify(new.requester, new.addressee, 'friend_accepted',
      public.person_name(new.addressee) || ' aceptó tu solicitud', 'Ahora son amigos. Invítalo a una racha juntos.', '{}'::jsonb);
  end if;
  return new;
end; $$;
