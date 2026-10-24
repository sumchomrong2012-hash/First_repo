-- =====================================================================================
--  Khmer Chess — "adjust your pieces before the game" (run ONCE in Supabase -> SQL Editor -> Run)
--  Run it AFTER schema.sql. Safe to run again. Existing games and accounts are not touched.
-- =====================================================================================

-- 1) rooms: "setup_pending" = the two players are still choosing their pieces (no moves, clocks stopped)
alter table public.rooms add column if not exists setup_pending boolean not null default false;

-- 2) each player's choice lives in its own table. A player can read the OTHER player's choice only
--    after both are ready, so nobody can peek and then decide.
create table if not exists public.room_setups (
  room_id    uuid not null references public.rooms (id) on delete cascade,
  color      text not null check (color in ('w', 'b')),
  pieces     jsonb not null,                     -- "std" = normal start, or [[square, "type"], ...]
  created_at timestamptz not null default now(),
  primary key (room_id, color)
);
alter table public.room_setups enable row level security;
drop policy if exists room_setups_select on public.room_setups;
create policy room_setups_select on public.room_setups for select to authenticated
  using (exists (select 1 from public.rooms r
                 where r.id = room_setups.room_id
                   and (r.host_id = auth.uid() or r.guest_id = auth.uid())
                   and (r.setup_pending = false
                        or (r.host_id  = auth.uid() and r.host_color  = room_setups.color)
                        or (r.guest_id = auth.uid() and r.host_color <> room_setups.color))));
revoke all on public.room_setups from anon, authenticated;
grant select on public.room_setups to authenticated;

-- 3) room_json: tell the apps whether setup is pending and who is ready (not WHAT they chose)
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
    'setup_ready_b', exists (select 1 from public.room_setups s where s.room_id = r.id and s.color = 'b'));
$$;

-- 4) joining a room now starts in "setup" mode
create or replace function public.join_room(p_code text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where rooms.code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'room_not_found'; end if;
  if v_room.host_id = v_uid or v_room.guest_id = v_uid then return public.room_json(v_room); end if;   -- already in: just resume
  if v_room.status <> 'waiting' then raise exception 'room_not_open'; end if;
  update public.rooms set guest_id = v_uid, status = 'playing', started_at = now(), turn = first_turn, ply = 0,
                          setup_pending = true
   where id = v_room.id returning * into v_room;
  return public.room_json(v_room);
end $$;

-- 5) each player sends their choice: NULL = normal start, or a list of [square, type] for THEIR OWN side only.
--    Squares: 0..63 = row*8 + column, row 0 = Black's back row. White may use 40..63, Black 0..23.
--    Types: k q r b n p u (u = promoted pawn). Exactly one king, at most 1 q, 2 r, 2 b, 2 n, and 8 pawns+promoted pawns.
create or replace function public.submit_setup(p_room uuid, p_pieces jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid(); v_room public.rooms; v_color text; v_el jsonb; v_sq int; v_t text;
  v_seen int[] := '{}'; c_k int := 0; c_q int := 0; c_r int := 0; c_b int := 0; c_n int := 0; c_p int := 0;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  v_color := public.room_color_of(v_room, v_uid);
  if v_room.status <> 'playing' or not v_room.setup_pending then raise exception 'no_setup'; end if;
  if exists (select 1 from public.room_setups where room_id = p_room and color = v_color) then raise exception 'setup_done'; end if;

  if p_pieces is not null and jsonb_typeof(p_pieces) <> 'null' then
    if jsonb_typeof(p_pieces) <> 'array' or jsonb_array_length(p_pieces) > 16 then raise exception 'bad_setup'; end if;
    for v_el in select * from jsonb_array_elements(p_pieces) loop
      if jsonb_typeof(v_el) <> 'array' or jsonb_array_length(v_el) <> 2 then raise exception 'bad_setup'; end if;
      v_sq := (v_el ->> 0)::int; v_t := v_el ->> 1;
      if v_color = 'w' and v_sq not between 40 and 63 then raise exception 'bad_setup'; end if;
      if v_color = 'b' and v_sq not between 0 and 23 then raise exception 'bad_setup'; end if;
      if v_sq = any (v_seen) then raise exception 'bad_setup'; end if;
      v_seen := v_seen || v_sq;
      if    v_t = 'k' then c_k := c_k + 1;
      elsif v_t = 'q' then c_q := c_q + 1;
      elsif v_t = 'r' then c_r := c_r + 1;
      elsif v_t = 'b' then c_b := c_b + 1;
      elsif v_t = 'n' then c_n := c_n + 1;
      elsif v_t in ('p', 'u') then c_p := c_p + 1;
      else raise exception 'bad_setup'; end if;
    end loop;
    if c_k <> 1 or c_q > 1 or c_r > 2 or c_b > 2 or c_n > 2 or c_p > 8 then raise exception 'bad_setup'; end if;
  end if;

  insert into public.room_setups (room_id, color, pieces)
  values (p_room, v_color, case when p_pieces is null or jsonb_typeof(p_pieces) = 'null' then '"std"'::jsonb else p_pieces end);

  if (select count(*) from public.room_setups where room_id = p_room) >= 2 then
    -- both ready: the game really starts now (clocks start now)
    update public.rooms set setup_pending = false, started_at = now(), last_move_at = null, turn = first_turn, ply = 0
     where id = p_room returning * into v_room;
  else
    update public.rooms set setup_pending = true where id = p_room returning * into v_room;   -- wakes the other player's screen
  end if;
  return public.room_json(v_room);
end $$;

-- 6) no moves / time-outs while the players are still choosing
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
  if v_room.setup_pending then raise exception 'setup_pending'; end if;
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

create or replace function public.claim_timeout(p_room uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_used double precision;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  perform public.room_color_of(v_room, v_uid);
  if v_room.status <> 'playing' or v_room.minutes = 0 or v_room.setup_pending then raise exception 'not_expired'; end if;
  v_used := public.room_used_seconds(p_room, v_room.turn);
  if v_used < v_room.minutes * 60 then raise exception 'not_expired'; end if;
  perform public.finish_room(p_room, case when v_room.turn = 'w' then 'b' else 'w' end, 'timeout');
  return public.room_json((select r from public.rooms r where r.id = p_room));
end $$;

-- 7) leaving while the other player is still choosing = the room is simply cancelled (nobody gets a win/loss)
create or replace function public.resign(p_room uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_color text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  v_color := public.room_color_of(v_room, v_uid);
  if v_room.status = 'waiting' or (v_room.status = 'playing' and v_room.setup_pending) then
    update public.rooms set status = 'cancelled', finished_at = now(), setup_pending = false where id = p_room;
  elsif v_room.status = 'playing' then
    perform public.finish_room(p_room, case when v_color = 'w' then 'b' else 'w' end, 'resign');
  end if;
  return public.room_json((select r from public.rooms r where r.id = p_room));
end $$;

-- permissions for the new function
revoke execute on function public.submit_setup(uuid, jsonb) from public, anon;
grant  execute on function public.submit_setup(uuid, jsonb) to authenticated;
