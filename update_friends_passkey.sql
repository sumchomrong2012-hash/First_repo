-- =====================================================================================
--  Khmer Chess — room PASSKEY + FRIEND LIST + INVITES
--  Run ONCE in Supabase -> SQL Editor -> Run. Run it AFTER schema.sql, update_avatar.sql, update_setup.sql
--  (and update_setup_pawns.sql). Do NOT run update_setup.sql again afterwards.
--  Safe to run again. Your accounts, games and pictures are not touched.
-- =====================================================================================

-- ---------- 1) passkey on rooms (stored only as a salted hash, never as plain text)
alter table public.rooms add column if not exists passkey_hash text;

create or replace function public.passkey_ok(p_hash text, p_pass text)
returns boolean language sql immutable as $$
  select p_hash is null
      or (p_pass is not null
          and split_part(p_hash, ':', 2) = encode(sha256(convert_to(split_part(p_hash, ':', 1) || btrim(p_pass), 'UTF8')), 'hex'));
$$;

-- room_json now also says whether the room has a passkey (never the passkey itself)
create or replace function public.room_json(r public.rooms)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', r.id, 'code', r.code, 'host_id', r.host_id, 'guest_id', r.guest_id,
    'host_name',  (select display_name from public.profiles where id = r.host_id),
    'guest_name', (select display_name from public.profiles where id = r.guest_id),
    'host_color', r.host_color, 'first_turn', r.first_turn, 'minutes', r.minutes, 'is_public', r.is_public,
    'status', r.status, 'turn', r.turn, 'ply', r.ply, 'result', r.result, 'result_reason', r.result_reason,
    'draw_offer', r.draw_offer, 'created_at', r.created_at, 'started_at', r.started_at,
    'last_move_at', r.last_move_at, 'finished_at', r.finished_at, 'server_now', clock_timestamp(),
    'setup_pending', r.setup_pending,
    'setup_ready_w', exists (select 1 from public.room_setups s where s.room_id = r.id and s.color = 'w'),
    'setup_ready_b', exists (select 1 from public.room_setups s where s.room_id = r.id and s.color = 'b'),
    'has_passkey', (r.passkey_hash is not null));
$$;

-- create_room: new optional 5th argument = passkey (empty = no passkey)
drop function if exists public.create_room(text, int, text, boolean);
create or replace function public.create_room(p_color text default 'random', p_minutes int default 20,
                                              p_first_turn text default 'w', p_public boolean default true,
                                              p_passkey text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid(); v_color text := p_color; v_room public.rooms;
  v_pass text := nullif(btrim(coalesce(p_passkey, '')), ''); v_hash text; v_salt text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid) then raise exception 'no_profile'; end if;
  if v_color not in ('w', 'b', 'random') then raise exception 'bad_color'; end if;
  if p_first_turn not in ('w', 'b') then raise exception 'bad_first_turn'; end if;
  if p_minutes not in (0, 1, 3, 5, 10, 20, 60) then raise exception 'bad_minutes'; end if;
  if v_color = 'random' then v_color := case when random() < 0.5 then 'w' else 'b' end; end if;
  if (select count(*) from public.rooms where host_id = v_uid and status = 'waiting') >= 3 then raise exception 'too_many_waiting_rooms'; end if;
  if (select count(*) from public.rooms where (host_id = v_uid or guest_id = v_uid) and status = 'playing') >= 10 then raise exception 'too_many_games'; end if;
  if v_pass is not null then
    if char_length(v_pass) < 2 or char_length(v_pass) > 20 then raise exception 'bad_passkey'; end if;
    v_salt := replace(gen_random_uuid()::text, '-', '');
    v_hash := v_salt || ':' || encode(sha256(convert_to(v_salt || v_pass, 'UTF8')), 'hex');
  end if;
  insert into public.rooms (code, host_id, host_color, first_turn, minutes, is_public, turn, passkey_hash)
  values (public.gen_room_code(), v_uid, v_color, p_first_turn, p_minutes, coalesce(p_public, true), p_first_turn, v_hash)
  returning * into v_room;
  return public.room_json(v_room);
end $$;

-- join_room: new optional 2nd argument = passkey
drop function if exists public.join_room(text);
create or replace function public.join_room(p_code text, p_passkey text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where rooms.code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'room_not_found'; end if;
  if v_room.host_id = v_uid or v_room.guest_id = v_uid then return public.room_json(v_room); end if;   -- already in: just resume
  if v_room.status <> 'waiting' then raise exception 'room_not_open'; end if;
  if v_room.passkey_hash is not null then
    if p_passkey is null or btrim(p_passkey) = '' then raise exception 'passkey_required'; end if;
    if not public.passkey_ok(v_room.passkey_hash, p_passkey) then raise exception 'wrong_passkey'; end if;
  end if;
  update public.rooms set guest_id = v_uid, status = 'playing', started_at = now(), turn = first_turn, ply = 0,
                          setup_pending = true
   where id = v_room.id returning * into v_room;
  return public.room_json(v_room);
end $$;

-- ---------- 2) friends
create table if not exists public.friendships (
  id         bigint generated always as identity primary key,
  requester  uuid not null references public.profiles (id) on delete cascade,
  addressee  uuid not null references public.profiles (id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
create unique index if not exists friendships_pair_idx on public.friendships (least(requester, addressee), greatest(requester, addressee));
alter table public.friendships enable row level security;
drop policy if exists friendships_select on public.friendships;
create policy friendships_select on public.friendships for select to authenticated
  using (requester = auth.uid() or addressee = auth.uid());
revoke all on public.friendships from anon, authenticated;
grant select on public.friendships to authenticated;

create or replace function public.friend_request(p_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_other public.profiles; v_rel public.friendships;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_other from public.profiles where lower(display_name) = lower(btrim(coalesce(p_name, ''))) limit 1;
  if not found then raise exception 'user_not_found'; end if;
  if v_other.id = v_uid then raise exception 'cannot_add_self'; end if;
  select * into v_rel from public.friendships
   where least(requester, addressee) = least(v_uid, v_other.id) and greatest(requester, addressee) = greatest(v_uid, v_other.id);
  if found then
    if v_rel.status = 'accepted' then raise exception 'already_friends'; end if;
    if v_rel.requester = v_uid then raise exception 'already_requested'; end if;
    update public.friendships set status = 'accepted' where id = v_rel.id;          -- they had already asked me: now friends
    return jsonb_build_object('state', 'friend', 'id', v_other.id, 'name', v_other.display_name);
  end if;
  insert into public.friendships (requester, addressee) values (v_uid, v_other.id);
  return jsonb_build_object('state', 'outgoing', 'id', v_other.id, 'name', v_other.display_name);
end $$;

create or replace function public.friend_respond(p_user uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_accept then
    update public.friendships set status = 'accepted' where requester = p_user and addressee = v_uid and status = 'pending';
  else
    delete from public.friendships where requester = p_user and addressee = v_uid and status = 'pending';
  end if;
end $$;

create or replace function public.friend_remove(p_user uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  delete from public.friendships
   where (requester = v_uid and addressee = p_user) or (requester = p_user and addressee = v_uid);
end $$;

create or replace function public.my_friends()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id, 'name', o.display_name,
           'state', case when f.status = 'accepted' then 'friend' when f.requester = auth.uid() then 'outgoing' else 'incoming' end)
         order by o.display_name), '[]'::jsonb)
    from public.friendships f
    join public.profiles o on o.id = case when f.requester = auth.uid() then f.addressee else f.requester end
   where f.requester = auth.uid() or f.addressee = auth.uid();
$$;

-- ---------- 3) invitations ("Invite friend": your friend gets a Join button)
create table if not exists public.invites (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms (id) on delete cascade,
  from_user  uuid not null references public.profiles (id) on delete cascade,
  to_user    uuid not null references public.profiles (id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now()
);
create index if not exists invites_to_idx on public.invites (to_user, status);
alter table public.invites enable row level security;
drop policy if exists invites_select on public.invites;
create policy invites_select on public.invites for select to authenticated
  using (to_user = auth.uid() or from_user = auth.uid());
revoke all on public.invites from anon, authenticated;
grant select on public.invites to authenticated;
do $$ begin alter publication supabase_realtime add table public.invites; exception when duplicate_object then null; end $$;

create or replace function public.send_invite(p_room uuid, p_friend uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_id uuid;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room;
  if not found or v_room.host_id <> v_uid then raise exception 'not_in_room'; end if;
  if v_room.status <> 'waiting' then raise exception 'room_not_open'; end if;
  if not exists (select 1 from public.friendships
                  where status = 'accepted'
                    and ((requester = v_uid and addressee = p_friend) or (requester = p_friend and addressee = v_uid))) then
    raise exception 'not_friends';
  end if;
  select id into v_id from public.invites where room_id = p_room and to_user = p_friend and status = 'pending';
  if v_id is null then
    if (select count(*) from public.invites where from_user = v_uid and status = 'pending') >= 20 then raise exception 'too_many_invites'; end if;
    insert into public.invites (room_id, from_user, to_user) values (p_room, v_uid, p_friend) returning id into v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.my_invites()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'room_id', r.id, 'code', r.code, 'from_id', i.from_user, 'from_name', p.display_name,
           'minutes', r.minutes, 'has_passkey', (r.passkey_hash is not null), 'created_at', i.created_at)
         order by i.created_at desc), '[]'::jsonb)
    from public.invites i
    join public.rooms r on r.id = i.room_id
    join public.profiles p on p.id = i.from_user
   where i.to_user = auth.uid() and i.status = 'pending' and r.status = 'waiting'
     and i.created_at > now() - interval '1 day';
$$;

-- accepting an invitation joins the room (the host invited you, so no passkey is asked)
create or replace function public.accept_invite(p_invite uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_inv public.invites; v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_inv from public.invites where id = p_invite and to_user = v_uid for update;
  if not found then raise exception 'invite_not_found'; end if;
  select * into v_room from public.rooms where id = v_inv.room_id for update;
  if not found then raise exception 'room_not_found'; end if;
  if v_room.host_id = v_uid or v_room.guest_id = v_uid then return public.room_json(v_room); end if;
  if v_room.status <> 'waiting' then
    update public.invites set status = 'declined' where id = p_invite;
    raise exception 'room_not_open';
  end if;
  update public.rooms set guest_id = v_uid, status = 'playing', started_at = now(), turn = first_turn, ply = 0,
                          setup_pending = true
   where id = v_room.id returning * into v_room;
  update public.invites set status = case when id = p_invite then 'accepted' else 'declined' end
   where room_id = v_room.id and status = 'pending';
  return public.room_json(v_room);
end $$;

create or replace function public.decline_invite(p_invite uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  update public.invites set status = 'declined' where id = p_invite and to_user = auth.uid() and status = 'pending';
end $$;

-- ---------- 4) permissions
revoke execute on function public.passkey_ok(text, text) from public, anon, authenticated;
revoke execute on function public.create_room(text, int, text, boolean, text) from public, anon;
revoke execute on function public.join_room(text, text) from public, anon;
revoke execute on function public.friend_request(text), public.friend_respond(uuid, boolean), public.friend_remove(uuid), public.my_friends(),
                           public.send_invite(uuid, uuid), public.my_invites(), public.accept_invite(uuid), public.decline_invite(uuid)
  from public, anon;
grant execute on function public.create_room(text, int, text, boolean, text), public.join_room(text, text),
                          public.friend_request(text), public.friend_respond(uuid, boolean), public.friend_remove(uuid), public.my_friends(),
                          public.send_invite(uuid, uuid), public.my_invites(), public.accept_invite(uuid), public.decline_invite(uuid)
  to authenticated;

notify pgrst, 'reload schema';
