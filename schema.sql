-- Online piece handicap / custom setup migration
-- Run this AFTER schema.sql in Supabase SQL Editor.
alter table public.rooms add column if not exists setup_choice_host boolean;
alter table public.rooms add column if not exists setup_choice_guest boolean;
alter table public.rooms add column if not exists setup_white jsonb;
alter table public.rooms add column if not exists setup_black jsonb;
alter table public.rooms add column if not exists setup_ready_host boolean not null default false;
alter table public.rooms add column if not exists setup_ready_guest boolean not null default false;
alter table public.rooms add column if not exists board_position jsonb;

alter table public.rooms drop constraint if exists rooms_status_check;
alter table public.rooms add constraint rooms_status_check
  check (status in ('waiting','setup_choice','setup','playing','finished','cancelled'));

create or replace function public.room_json(r public.rooms)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', r.id, 'code', r.code, 'host_id', r.host_id, 'guest_id', r.guest_id,
    'host_name', (select display_name from public.profiles where id = r.host_id),
    'guest_name', (select display_name from public.profiles where id = r.guest_id),
    'host_color', r.host_color, 'first_turn', r.first_turn, 'minutes', r.minutes, 'is_public', r.is_public,
    'status', r.status, 'turn', r.turn, 'ply', r.ply, 'result', r.result, 'result_reason', r.result_reason,
    'draw_offer', r.draw_offer, 'created_at', r.created_at, 'started_at', r.started_at,
    'last_move_at', r.last_move_at, 'finished_at', r.finished_at, 'server_now', clock_timestamp(),
    'setup_choice_host',r.setup_choice_host,'setup_choice_guest',r.setup_choice_guest,
    'setup_ready_host',r.setup_ready_host,'setup_ready_guest',r.setup_ready_guest,
    'board_position',r.board_position
  );
$$;

create or replace function public.join_room(p_code text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where rooms.code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'room_not_found'; end if;
  if v_room.host_id = v_uid or v_room.guest_id = v_uid then return public.room_json(v_room); end if;
  if v_room.status <> 'waiting' then raise exception 'room_not_open'; end if;
  update public.rooms set guest_id=v_uid,status='setup_choice',started_at=null,turn=first_turn,ply=0,
    setup_choice_host=null,setup_choice_guest=null,setup_white=null,setup_black=null,
    setup_ready_host=false,setup_ready_guest=false,board_position=null
  where id=v_room.id returning * into v_room;
  return public.room_json(v_room);
end $$;

create or replace function public.choose_piece_setup(p_room uuid,p_wants_setup boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id=p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  if v_room.status <> 'setup_choice' then return public.room_json(v_room); end if;
  if v_uid=v_room.host_id then
    update public.rooms set setup_choice_host=p_wants_setup where id=p_room returning * into v_room;
  elsif v_uid=v_room.guest_id then
    update public.rooms set setup_choice_guest=p_wants_setup where id=p_room returning * into v_room;
  else raise exception 'not_in_room';
  end if;
  if v_room.setup_choice_host is not null and v_room.setup_choice_guest is not null then
    if v_room.setup_choice_host or v_room.setup_choice_guest then
      update public.rooms set status='setup',setup_ready_host=false,setup_ready_guest=false,
        setup_white=null,setup_black=null,started_at=null where id=p_room returning * into v_room;
    else
      update public.rooms set status='playing',started_at=now(),last_move_at=now(),turn=first_turn,
        board_position=null where id=p_room returning * into v_room;
    end if;
  end if;
  return public.room_json(v_room);
end $$;

create or replace function public.submit_piece_setup(p_room uuid,p_color text,p_pieces jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms; v_color text; v_piece jsonb; v_i int; v_board jsonb;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_room from public.rooms where id=p_room for update;
  if not found then raise exception 'room_not_found'; end if;
  v_color := public.room_color_of(v_room,v_uid);
  if v_room.status <> 'setup' then raise exception 'setup_not_active'; end if;
  if p_color is distinct from v_color then raise exception 'wrong_setup_color'; end if;
  if jsonb_typeof(p_pieces) <> 'array' or jsonb_array_length(p_pieces) <> 64 then raise exception 'bad_setup_board'; end if;
  if (select count(*) from jsonb_array_elements(p_pieces) e where e->>'t'='k' and e->>'c'=v_color) <> 1 then
    raise exception 'setup_requires_one_king';
  end if;
  for v_i in 0..63 loop
    v_piece := p_pieces->v_i;
    if v_piece <> 'null'::jsonb then
      if v_piece->>'c' is distinct from v_color then raise exception 'wrong_setup_color'; end if;
      if coalesce(v_piece->>'t','') not in ('k','q','r','b','n','p','u') then raise exception 'bad_setup_piece'; end if;
    end if;
  end loop;
  if v_uid=v_room.host_id then
    update public.rooms set setup_white=case when v_color='w' then p_pieces else setup_white end,
      setup_black=case when v_color='b' then p_pieces else setup_black end,
      setup_ready_host=true where id=p_room returning * into v_room;
  else
    update public.rooms set setup_white=case when v_color='w' then p_pieces else setup_white end,
      setup_black=case when v_color='b' then p_pieces else setup_black end,
      setup_ready_guest=true where id=p_room returning * into v_room;
  end if;
  if v_room.setup_ready_host and v_room.setup_ready_guest and v_room.setup_white is not null and v_room.setup_black is not null then
    v_board := '[]'::jsonb;
    for v_i in 0..63 loop
      if v_room.setup_white->v_i <> 'null'::jsonb then
        v_board := v_board || jsonb_build_array(v_room.setup_white->v_i);
      else
        v_board := v_board || jsonb_build_array(v_room.setup_black->v_i);
      end if;
    end loop;
    update public.rooms set board_position=v_board,status='playing',started_at=now(),last_move_at=now(),
      turn=first_turn,ply=0,setup_ready_host=false,setup_ready_guest=false
    where id=p_room returning * into v_room;
  end if;
  return public.room_json(v_room);
end $$;

revoke execute on function public.choose_piece_setup(uuid,boolean) from public,anon;
revoke execute on function public.submit_piece_setup(uuid,text,jsonb) from public,anon;
grant execute on function public.choose_piece_setup(uuid,boolean) to authenticated;
grant execute on function public.submit_piece_setup(uuid,text,jsonb) to authenticated;
