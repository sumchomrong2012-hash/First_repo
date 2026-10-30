-- =====================================================================================
--  Khmer Chess — turn timer (time per move) for online games + message inbox
--  Run ONCE in Supabase -> SQL Editor -> Run. Run it AFTER update_v4.sql. Safe to run again.
-- =====================================================================================

-- 1) rooms: time allowed for each move (0 = no limit)
alter table public.rooms add column if not exists turn_seconds int not null default 0;
alter table public.rooms drop constraint if exists rooms_turn_seconds_check;
alter table public.rooms add constraint rooms_turn_seconds_check check (turn_seconds in (0, 30, 60, 120, 180, 300));

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
    'has_passkey', (r.passkey_hash is not null), 'turn_seconds', r.turn_seconds);
$$;

-- create_room: new optional 6th argument = seconds per move
drop function if exists public.create_room(text, int, text, boolean, text);
create or replace function public.create_room(p_color text default 'random', p_minutes int default 20,
                                              p_first_turn text default 'w', p_public boolean default true,
                                              p_passkey text default null, p_turn_seconds int default 0)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid(); v_color text := p_color; v_room public.rooms;
  v_pass text := nullif(btrim(coalesce(p_passkey, '')), ''); v_hash text; v_salt text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from public.profiles where id = v_uid) then raise exception 'no_profile'; end if;
  if v_color not in ('w', 'b', 'random') then raise exception 'bad_color'; end if;
  if p_first_turn not in ('w', 'b') then raise exception 'bad_first_turn'; end if;
  if p_minutes not in (0, 1, 3, 5, 10, 20, 30, 60) then raise exception 'bad_minutes'; end if;
  if p_turn_seconds is null or p_turn_seconds not in (0, 30, 60, 120, 180, 300) then raise exception 'bad_turn_seconds'; end if;
  if v_color = 'random' then v_color := case when random() < 0.5 then 'w' else 'b' end; end if;
  if (select count(*) from public.rooms where host_id = v_uid and status = 'waiting') >= 3 then raise exception 'too_many_waiting_rooms'; end if;
  if (select count(*) from public.rooms where (host_id = v_uid or guest_id = v_uid) and status = 'playing') >= 10 then raise exception 'too_many_games'; end if;
  if v_pass is not null then
    if char_length(v_pass) < 2 or char_length(v_pass) > 20 then raise exception 'bad_passkey'; end if;
    v_salt := replace(gen_random_uuid()::text, '-', '');
    v_hash := v_salt || ':' || encode(sha256(convert_to(v_salt || v_pass, 'UTF8')), 'hex');
  end if;
  insert into public.rooms (code, host_id, host_color, first_turn, minutes, is_public, turn, passkey_hash, turn_seconds)
  values (public.gen_room_code(), v_uid, v_color, p_first_turn, p_minutes, coalesce(p_public, true), p_first_turn, v_hash, p_turn_seconds)
  returning * into v_room;
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

  -- per-move limit: a player who already used more than the allowed time for this move cannot move
  if v_room.turn_seconds > 0
     and extract(epoch from (now() - coalesce(v_room.last_move_at, v_room.started_at))) > v_room.turn_seconds + 3 then
    perform public.finish_room(p_room, case when v_color = 'w' then 'b' else 'w' end, 'timeout');
    return public.room_json((select r from public.rooms r where r.id = p_room));
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
declare v_uid uuid := auth.uid(); v_room public.rooms; v_used double precision; v_move_out boolean := false; v_match_out boolean := false;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  perform public.room_color_of(v_room, v_uid);
  if v_room.status <> 'playing' or v_room.setup_pending or (v_room.minutes = 0 and v_room.turn_seconds = 0) then raise exception 'not_expired'; end if;
  if v_room.minutes > 0 then
    v_used := public.room_used_seconds(p_room, v_room.turn);
    v_match_out := v_used >= v_room.minutes * 60;
  end if;
  if v_room.turn_seconds > 0 then
    v_move_out := extract(epoch from (now() - coalesce(v_room.last_move_at, v_room.started_at))) >= v_room.turn_seconds;
  end if;
  if not (v_match_out or v_move_out) then raise exception 'not_expired'; end if;
  perform public.finish_room(p_room, case when v_room.turn = 'w' then 'b' else 'w' end, 'timeout');
  return public.room_json((select r from public.rooms r where r.id = p_room));
end $$;


-- 2) message inbox: one line per friend I talk to (last message + how many are unread)
create or replace function public.my_conversations()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'other_id', x.other, 'other_name', p.display_name, 'last_body', x.last_body, 'last_at', x.last_at,
           'last_from_me', x.last_from_me, 'unread', x.unread) order by x.last_at desc), '[]'::jsonb)
    from (select case when m.from_user = auth.uid() then m.to_user else m.from_user end as other,
                 max(m.created_at) as last_at,
                 (array_agg(m.body order by m.id desc))[1] as last_body,
                 (array_agg(m.from_user = auth.uid() order by m.id desc))[1] as last_from_me,
                 count(*) filter (where m.to_user = auth.uid() and m.read_at is null) as unread
            from public.direct_messages m
           where m.from_user = auth.uid() or m.to_user = auth.uid()
           group by 1) x
    join public.profiles p on p.id = x.other;
$$;

-- 3) permissions
revoke execute on function public.create_room(text, int, text, boolean, text, int) from public, anon;
revoke execute on function public.my_conversations() from public, anon;
grant  execute on function public.create_room(text, int, text, boolean, text, int) to authenticated;
grant  execute on function public.my_conversations() to authenticated;
notify pgrst, 'reload schema';
