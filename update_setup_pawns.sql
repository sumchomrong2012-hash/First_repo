-- =====================================================================================
--  Khmer Chess — update: extra pawns / promoted pawns allowed in the piece setup
--  Run ONCE in Supabase -> SQL Editor -> Run (only if you already ran update_setup.sql before).
--  Safe to run again.
-- =====================================================================================

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
    if c_k <> 1 or c_q > 1 or c_r > 2 or c_b > 2 or c_n > 2 then raise exception 'bad_setup'; end if;   -- pawns / promoted pawns: any number, the 16-piece total is the limit
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

revoke execute on function public.submit_setup(uuid, jsonb) from public, anon;
grant  execute on function public.submit_setup(uuid, jsonb) to authenticated;
