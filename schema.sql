-- =====================================================================================
--  Khmer Chess (អុកចត្រង្គ) — online multiplayer schema for Supabase
--
--  HOW TO USE: Supabase Dashboard -> SQL Editor -> New query -> paste this whole file -> Run.
--  It is safe to run again (it uses "if not exists" / "create or replace").
--
--  What it creates
--    profiles       one row per account (display name + win/loss/draw counts)
--    rooms          one row per game room (code, host, guest, time control, whose turn, result ...)
--    moves          every move of every game (this is what both players' screens replay)
--    room_messages  in-game chat
--    functions      create_room, join_room, submit_move, resign, claim_timeout, offer_draw ...
--
--  Security model
--    * Players can only READ rooms/moves/chat of games they are in (plus open public rooms in the lobby).
--    * Nobody can write to the tables directly. All changes go through the functions below, which check
--      "are you signed in?", "are you in this room?", "is it your turn?", "is the game still running?".
--    * Time limits are checked on the server from move timestamps, so a client cannot cheat the clock.
--    * NOTE: chess-rule legality (is this a legal move?) is checked by the players' browsers, not by the
--      database. That is fine for games among friends; see README "Limits" for the upgrade path.
-- =====================================================================================

-- ------------------------------------------------------------------------------ profiles
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  wins         int  not null default 0,
  losses       int  not null default 0,
  draws        int  not null default 0,
  created_at   timestamptz not null default now(),
  constraint profiles_display_name_len check (char_length(display_name) between 2 and 24)
);
create unique index if not exists profiles_display_name_key on public.profiles (lower(display_name));

-- A profile is created automatically for every new account.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_base text; v_name text; v_try int := 0;
begin
  v_base := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), '');
  if v_base is null then v_base := nullif(split_part(coalesce(new.email, ''), '@', 1), ''); end if;
  if v_base is null then v_base := 'Guest'; end if;
  v_base := left(v_base, 20);
  if char_length(v_base) < 2 then v_base := v_base || 'Player'; end if;
  v_name := v_base;
  while exists (select 1 from public.profiles where lower(display_name) = lower(v_name)) and v_try < 25 loop
    v_try := v_try + 1;
    v_name := left(v_base, 20) || floor(random() * 9000 + 1000)::int::text;
  end loop;
  insert into public.profiles (id, display_name) values (new.id, left(v_name, 24));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Back-fill profiles for accounts that existed before this script ran.
insert into public.profiles (id, display_name)
select u.id, left(coalesce(nullif(split_part(coalesce(u.email, ''), '@', 1), ''), 'Guest') || floor(random() * 9000 + 1000)::int::text, 24)
from auth.users u where not exists (select 1 from public.profiles p where p.id = u.id);

-- ------------------------------------------------------------------------------ rooms
create table if not exists public.rooms (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,                                   -- 6 characters shared with a friend
  host_id       uuid not null references public.profiles (id) on delete cascade,
  guest_id      uuid references public.profiles (id) on delete set null,
  host_color    text not null check (host_color in ('w', 'b')),         -- w = White, b = Black
  first_turn    text not null default 'w' check (first_turn in ('w', 'b')),
  minutes       int  not null default 20 check (minutes in (0, 1, 3, 5, 10, 20, 60)),   -- per player; 0 = no clock
  is_public     boolean not null default true,                          -- listed in the lobby?
  status        text not null default 'waiting' check (status in ('waiting', 'playing', 'finished', 'cancelled')),
  turn          text not null default 'w' check (turn in ('w', 'b')),
  ply           int  not null default 0,                                -- number of moves played so far
  result        text check (result in ('w', 'b', 'draw')),
  result_reason text,
  draw_offer    text check (draw_offer in ('w', 'b')),
  created_at    timestamptz not null default now(),
  started_at    timestamptz,
  last_move_at  timestamptz,
  finished_at   timestamptz
);
create index if not exists rooms_host_idx   on public.rooms (host_id);
create index if not exists rooms_guest_idx  on public.rooms (guest_id);
create index if not exists rooms_lobby_idx  on public.rooms (status, is_public, created_at desc);

create table if not exists public.moves (
  room_id    uuid not null references public.rooms (id) on delete cascade,
  ply        int  not null check (ply >= 0),
  from_sq    int  not null check (from_sq between 0 and 63),            -- row * 8 + column (row 0 = rank 8)
  to_sq      int  not null check (to_sq between 0 and 63),
  by_color   text not null check (by_color in ('w', 'b')),
  created_at timestamptz not null default now(),
  primary key (room_id, ply)
);

create table if not exists public.room_messages (
  id         bigint generated always as identity primary key,
  room_id    uuid not null references public.rooms (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists room_messages_room_idx on public.room_messages (room_id, id);

-- ------------------------------------------------------------------------------ row level security
alter table public.profiles      enable row level security;
alter table public.rooms         enable row level security;
alter table public.moves         enable row level security;
alter table public.room_messages enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated using (true);

drop policy if exists rooms_select on public.rooms;
create policy rooms_select on public.rooms for select to authenticated
  using (auth.uid() = host_id or auth.uid() = guest_id or (is_public and status = 'waiting'));

drop policy if exists moves_select on public.moves;
create policy moves_select on public.moves for select to authenticated
  using (exists (select 1 from public.rooms r where r.id = moves.room_id and (auth.uid() = r.host_id or auth.uid() = r.guest_id)));

drop policy if exists messages_select on public.room_messages;
create policy messages_select on public.room_messages for select to authenticated
  using (exists (select 1 from public.rooms r where r.id = room_messages.room_id and (auth.uid() = r.host_id or auth.uid() = r.guest_id)));

-- Read-only for signed-in users; no direct writes at all (writes happen in the functions below).
revoke all on public.profiles, public.rooms, public.moves, public.room_messages from anon, authenticated;
grant select on public.profiles, public.rooms, public.moves, public.room_messages to authenticated;

-- ------------------------------------------------------------------------------ helpers (not callable from the browser)
create or replace function public.room_json(r public.rooms)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', r.id, 'code', r.code, 'host_id', r.host_id, 'guest_id', r.guest_id,
    'host_name',  (select display_name from public.profiles where id = r.host_id),
    'guest_name', (select display_name from public.profiles where id = r.guest_id),
    'host_color', r.host_color, 'first_turn', r.first_turn, 'minutes', r.minutes, 'is_public', r.is_public,
    'status', r.status, 'turn', r.turn, 'ply', r.ply, 'result', r.result, 'result_reason', r.result_reason,
    'draw_offer', r.draw_offer, 'created_at', r.created_at, 'started_at', r.started_at,
    'last_move_at', r.last_move_at, 'finished_at', r.finished_at, 'server_now', clock_timestamp());
$$;

-- Seconds a player has used so far: time between consecutive moves, plus the time they have been thinking now.
create or replace function public.room_used_seconds(p_room uuid, p_color text)
returns double precision language sql stable security definer set search_path = public, pg_temp as $$
  with r as (select * from public.rooms where id = p_room),
       m as (select by_color, created_at, lag(created_at) over (order by ply) as prev from public.moves where room_id = p_room)
  select coalesce((select sum(extract(epoch from (m.created_at - coalesce(m.prev, (select started_at from r)))))
                   from m where m.by_color = p_color), 0)
       + coalesce((select case when r.status = 'playing' and r.turn = p_color
                               then extract(epoch from (clock_timestamp() - coalesce(r.last_move_at, r.started_at))) else 0 end
                   from r), 0);
$$;

create or replace function public.gen_room_code()
returns text language plpgsql volatile as $$
declare v_chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; v_code text; i int;
begin
  loop
    v_code := '';
    for i in 1..6 loop v_code := v_code || substr(v_chars, 1 + floor(random() * 32)::int, 1); end loop;
    exit when not exists (select 1 from public.rooms where rooms.code = v_code);
  end loop;
  return v_code;
end $$;

-- Ends a game that is currently running and updates both players' statistics (only once per game).
create or replace function public.finish_room(p_room uuid, p_result text, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_room public.rooms; v_winner uuid; v_loser uuid;
begin
  select * into v_room from public.rooms where id = p_room for update;
  if not found or v_room.status <> 'playing' then return; end if;
  update public.rooms set status = 'finished', result = p_result, result_reason = p_reason,
         finished_at = now(), draw_offer = null where id = p_room;
  if p_result = 'draw' then
    update public.profiles set draws = draws + 1 where id in (v_room.host_id, v_room.guest_id);
  else
    if p_result = v_room.host_color then v_winner := v_room.host_id; v_loser := v_room.guest_id;
    else v_winner := v_room.guest_id; v_loser := v_room.host_id; end if;
    update public.profiles set wins = wins + 1 where id = v_winner;
    update public.profiles set losses = losses + 1 where id = v_loser;
  end if;
end $$;

-- Returns the caller's colour in a room ('w' / 'b') or raises an error if the caller is not a player.
create or replace function public.room_color_of(r public.rooms, p_uid uuid)
returns text language plpgsql immutable as $$
begin
  if p_uid is not null and p_uid = r.host_id then return r.host_color; end if;
  if p_uid is not null and p_uid = r.guest_id then return case when r.host_color = 'w' then 'b' else 'w' end; end if;
  raise exception 'not_in_room';
end $$;

-- ------------------------------------------------------------------------------ functions called by the app
create or replace function public.set_display_name(p_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_name text := btrim(coalesce(p_name, ''));
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 24 then raise exception 'bad_name'; end if;
  if exists (select 1 from public.profiles where lower(display_name) = lower(v_name) and id <> v_uid) then raise exception 'name_taken'; end if;
  update public.profiles set display_name = v_name where id = v_uid;
  return (select to_jsonb(p) from public.profiles p where p.id = v_uid);
end $$;

create or replace function public.create_room(p_color text default 'random', p_minutes int default 20,
                                              p_first_turn text default 'w', p_public boolean default true)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_color text := p_color; v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid) then raise exception 'no_profile'; end if;
  if v_color not in ('w', 'b', 'random') then raise exception 'bad_color'; end if;
  if p_first_turn not in ('w', 'b') then raise exception 'bad_first_turn'; end if;
  if p_minutes not in (0, 1, 3, 5, 10, 20, 60) then raise exception 'bad_minutes'; end if;
  if v_color = 'random' then v_color := case when random() < 0.5 then 'w' else 'b' end; end if;
  if (select count(*) from public.rooms where host_id = v_uid and status = 'waiting') >= 3 then raise exception 'too_many_waiting_rooms'; end if;
  if (select count(*) from public.rooms where (host_id = v_uid or guest_id = v_uid) and status = 'playing') >= 10 then raise exception 'too_many_games'; end if;
  insert into public.rooms (code, host_id, host_color, first_turn, minutes, is_public, turn)
  values (public.gen_room_code(), v_uid, v_color, p_first_turn, p_minutes, coalesce(p_public, true), p_first_turn)
  returning * into v_room;
  return public.room_json(v_room);
end $$;

create or replace function public.join_room(p_code text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where rooms.code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'room_not_found'; end if;
  if v_room.host_id = v_uid or v_room.guest_id = v_uid then return public.room_json(v_room); end if;   -- already in: just resume
  if v_room.status <> 'waiting' then raise exception 'room_not_open'; end if;
  update public.rooms set guest_id = v_uid, status = 'playing', started_at = now(), turn = first_turn, ply = 0
   where id = v_room.id returning * into v_room;
  return public.room_json(v_room);
end $$;

create or replace function public.submit_move(p_room uuid, p_ply int, p_from int, p_to int,
                                              p_result text default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_color text; v_used double precision;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  v_color := public.room_color_of(v_room, v_uid);
  if v_room.status <> 'playing' then raise exception 'game_not_active'; end if;
  if v_room.turn <> v_color then raise exception 'not_your_turn'; end if;
  if p_ply is distinct from v_room.ply then raise exception 'bad_ply'; end if;
  if p_from is null or p_to is null or p_from not between 0 and 63 or p_to not between 0 and 63 or p_from = p_to then raise exception 'bad_move'; end if;
  if p_result is not null and p_result not in (v_color, 'draw') then raise exception 'bad_result'; end if;

  -- server-side clock: a player who already ran out of time cannot move
  if v_room.minutes > 0 then
    v_used := public.room_used_seconds(p_room, v_color);
    if v_used > v_room.minutes * 60 + 3 then
      perform public.finish_room(p_room, case when v_color = 'w' then 'b' else 'w' end, 'timeout');
      return public.room_json((select r from public.rooms r where r.id = p_room));
    end if;
  end if;

  insert into public.moves (room_id, ply, from_sq, to_sq, by_color) values (p_room, p_ply, p_from, p_to, v_color);
  update public.rooms set ply = ply + 1, turn = case when turn = 'w' then 'b' else 'w' end,
         last_move_at = now(), draw_offer = null where id = p_room;
  if p_result is not null then
    perform public.finish_room(p_room, p_result, coalesce(nullif(left(p_reason, 40), ''), case when p_result = 'draw' then 'draw' else 'checkmate' end));
  end if;
  return public.room_json((select r from public.rooms r where r.id = p_room));
end $$;

create or replace function public.resign(p_room uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_color text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  v_color := public.room_color_of(v_room, v_uid);
  if v_room.status = 'waiting' then
    update public.rooms set status = 'cancelled', finished_at = now() where id = p_room;
  elsif v_room.status = 'playing' then
    perform public.finish_room(p_room, case when v_color = 'w' then 'b' else 'w' end, 'resign');
  end if;
  return public.room_json((select r from public.rooms r where r.id = p_room));
end $$;

create or replace function public.claim_timeout(p_room uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_used double precision;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  perform public.room_color_of(v_room, v_uid);
  if v_room.status <> 'playing' or v_room.minutes = 0 then raise exception 'not_expired'; end if;
  v_used := public.room_used_seconds(p_room, v_room.turn);
  if v_used < v_room.minutes * 60 then raise exception 'not_expired'; end if;
  perform public.finish_room(p_room, case when v_room.turn = 'w' then 'b' else 'w' end, 'timeout');
  return public.room_json((select r from public.rooms r where r.id = p_room));
end $$;

create or replace function public.offer_draw(p_room uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_color text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  v_color := public.room_color_of(v_room, v_uid);
  if v_room.status <> 'playing' then raise exception 'game_not_active'; end if;
  if v_room.draw_offer is not null and v_room.draw_offer <> v_color then      -- the opponent already offered: this is an acceptance
    perform public.finish_room(p_room, 'draw', 'agreement');
  else
    update public.rooms set draw_offer = v_color where id = p_room;
  end if;
  return public.room_json((select r from public.rooms r where r.id = p_room));
end $$;

create or replace function public.respond_draw(p_room uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_color text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  v_color := public.room_color_of(v_room, v_uid);
  if v_room.status <> 'playing' then raise exception 'game_not_active'; end if;
  if v_room.draw_offer is null or v_room.draw_offer = v_color then raise exception 'no_offer'; end if;
  if p_accept then perform public.finish_room(p_room, 'draw', 'agreement');
  else update public.rooms set draw_offer = null where id = p_room; end if;
  return public.room_json((select r from public.rooms r where r.id = p_room));
end $$;

create or replace function public.send_message(p_room uuid, p_body text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_body text := btrim(coalesce(p_body, ''));
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room;
  if not found then raise exception 'room_not_found'; end if;
  perform public.room_color_of(v_room, v_uid);
  if char_length(v_body) < 1 or char_length(v_body) > 300 then raise exception 'bad_message'; end if;
  insert into public.room_messages (room_id, user_id, body) values (p_room, v_uid, v_body);
end $$;

create or replace function public.get_room(p_room uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room;
  if not found then raise exception 'room_not_found'; end if;
  perform public.room_color_of(v_room, v_uid);
  return public.room_json(v_room);
end $$;

-- Open public rooms waiting for an opponent (the lobby list). Rooms nobody joined for 2 hours are closed.
create or replace function public.list_open_rooms()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  update public.rooms set status = 'cancelled', finished_at = now() where status = 'waiting' and created_at < now() - interval '2 hours';
  return coalesce((select jsonb_agg(public.room_json(r) order by r.created_at desc)
                   from (select * from public.rooms where status = 'waiting' and is_public and host_id <> v_uid
                         order by created_at desc limit 30) r), '[]'::jsonb);
end $$;

-- The caller's own rooms: waiting / playing, plus games that finished in the last 3 days.
create or replace function public.my_rooms()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  return coalesce((select jsonb_agg(public.room_json(r) order by coalesce(r.last_move_at, r.created_at) desc)
                   from (select * from public.rooms
                         where (host_id = v_uid or guest_id = v_uid)
                           and (status in ('waiting', 'playing') or (status = 'finished' and finished_at > now() - interval '3 days'))
                         order by coalesce(last_move_at, created_at) desc limit 20) r), '[]'::jsonb);
end $$;

-- ------------------------------------------------------------------------------ who may call what
revoke execute on all functions in schema public from public, anon;
revoke execute on function public.handle_new_user(), public.room_json(public.rooms), public.room_used_seconds(uuid, text),
       public.gen_room_code(), public.finish_room(uuid, text, text), public.room_color_of(public.rooms, uuid) from authenticated;
grant execute on function
  public.set_display_name(text), public.create_room(text, int, text, boolean), public.join_room(text),
  public.submit_move(uuid, int, int, int, text, text), public.resign(uuid), public.claim_timeout(uuid),
  public.offer_draw(uuid), public.respond_draw(uuid, boolean), public.send_message(uuid, text),
  public.get_room(uuid), public.list_open_rooms(), public.my_rooms()
to authenticated;

-- ------------------------------------------------------------------------------ live updates
-- Lets the browsers receive new moves / room changes / chat instantly (Realtime "postgres changes").
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.rooms;         exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.moves;         exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.room_messages; exception when duplicate_object then null; end;
  end if;
end $$;
