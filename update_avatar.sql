-- =====================================================================================
--  Khmer Chess — profile picture update (run ONCE in Supabase -> SQL Editor -> Run)
--  Safe to run again. Does not touch your existing games, rooms or accounts.
-- =====================================================================================

alter table public.profiles add column if not exists avatar text;

alter table public.profiles drop constraint if exists profiles_avatar_fmt;
alter table public.profiles add constraint profiles_avatar_fmt
  check (avatar is null or (char_length(avatar) <= 60000 and avatar ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$'));

-- The app resizes the picture to 128x128 before saving, so each picture is only ~5-10 KB.
create or replace function public.set_avatar(p_avatar text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_avatar is not null and (char_length(p_avatar) > 60000 or p_avatar !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$') then
    raise exception 'bad_avatar';
  end if;
  update public.profiles set avatar = p_avatar where id = v_uid;
  return (select to_jsonb(p) from public.profiles p where p.id = v_uid);
end $$;

revoke execute on function public.set_avatar(text) from public, anon;
grant  execute on function public.set_avatar(text) to authenticated;
