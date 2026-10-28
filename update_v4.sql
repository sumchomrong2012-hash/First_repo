-- =====================================================================================
--  Khmer Chess — who moves first after a handicap, cancel when both players are offline,
--  messages to friends.
--  Run ONCE in Supabase -> SQL Editor -> Run. Run it AFTER update_more.sql. Safe to run again.
-- =====================================================================================

-- ---------- 1) "online presence" of the two players inside a room (updated by the apps every ~20 s)
alter table public.rooms add column if not exists host_seen  timestamptz not null default now();
alter table public.rooms add column if not exists guest_seen timestamptz;

-- Closes rooms nobody is in any more:
--   * waiting room:                     host away for 15 minutes
--   * both players still choosing pieces: both away for 3 minutes
--   * game running:                     both players away for 15 minutes
create or replace function public.cleanup_rooms()
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  update public.rooms set status = 'cancelled', finished_at = now(), setup_pending = false
   where (status = 'waiting' and host_seen < now() - interval '15 minutes')
      or (status = 'playing' and setup_pending
          and host_seen < now() - interval '3 minutes' and coalesce(guest_seen, created_at) < now() - interval '3 minutes')
      or (status = 'playing' and not setup_pending
          and host_seen < now() - interval '15 minutes' and coalesce(guest_seen, created_at) < now() - interval '15 minutes');
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.heartbeat(p_room uuid)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_room public.rooms;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  perform public.cleanup_rooms();
  select * into v_room from public.rooms where id = p_room;
  if not found then raise exception 'room_not_found'; end if;
  perform public.room_color_of(v_room, v_uid);
  if v_room.host_id = v_uid then update public.rooms set host_seen = now() where id = p_room;
  else update public.rooms set guest_seen = now() where id = p_room; end if;
  return v_room.status;
end $$;

-- ---------- 2) who moves first after the pieces were adjusted:
--      the player who has MORE pieces (the one who received the handicap) moves first.
--      Same number of pieces on both sides: the room's normal first move stays.
create or replace function public.submit_setup(p_room uuid, p_pieces jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid(); v_room public.rooms; v_color text; v_el jsonb; v_sq int; v_t text;
  v_seen int[] := '{}'; c_k int := 0; c_q int := 0; c_r int := 0; c_b int := 0; c_n int := 0;
  v_nw int; v_nb int; v_first text;
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
      elsif v_t in ('p', 'u') then null;
      else raise exception 'bad_setup'; end if;
    end loop;
    if c_k <> 1 or c_q > 1 or c_r > 2 or c_b > 2 or c_n > 2 then raise exception 'bad_setup'; end if;
  end if;

  insert into public.room_setups (room_id, color, pieces)
  values (p_room, v_color, case when p_pieces is null or jsonb_typeof(p_pieces) = 'null' then '"std"'::jsonb else p_pieces end);

  if (select count(*) from public.room_setups where room_id = p_room) >= 2 then
    select coalesce(max(case when color = 'w' then case when jsonb_typeof(pieces) = 'array' then jsonb_array_length(pieces) else 16 end end), 16),
           coalesce(max(case when color = 'b' then case when jsonb_typeof(pieces) = 'array' then jsonb_array_length(pieces) else 16 end end), 16)
      into v_nw, v_nb from public.room_setups where room_id = p_room;
    v_first := v_room.first_turn;
    if v_nw > v_nb then v_first := 'w'; elsif v_nb > v_nw then v_first := 'b'; end if;
    update public.rooms set setup_pending = false, started_at = now(), last_move_at = null,
                            first_turn = v_first, turn = v_first, ply = 0
     where id = p_room returning * into v_room;
  else
    update public.rooms set setup_pending = true where id = p_room returning * into v_room;
  end if;
  return public.room_json(v_room);
end $$;

-- ---------- 3) messages to friends ("leave a message")
create table if not exists public.direct_messages (
  id         bigint generated always as identity primary key,
  from_user  uuid not null references public.profiles (id) on delete cascade,
  to_user    uuid not null references public.profiles (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists direct_messages_to_idx   on public.direct_messages (to_user, created_at desc);
create index if not exists direct_messages_pair_idx on public.direct_messages (from_user, to_user, created_at desc);
alter table public.direct_messages enable row level security;
drop policy if exists direct_messages_select on public.direct_messages;
create policy direct_messages_select on public.direct_messages for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid());
revoke all on public.direct_messages from anon, authenticated;
grant select on public.direct_messages to authenticated;
do $$ begin alter publication supabase_realtime add table public.direct_messages; exception when duplicate_object then null; end $$;

create or replace function public.send_dm(p_to uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_id bigint; v_body text := btrim(coalesce(p_body, ''));
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if char_length(v_body) < 1 or char_length(v_body) > 300 then raise exception 'bad_message'; end if;
  if not exists (select 1 from public.friendships where status = 'accepted'
                  and ((requester = v_uid and addressee = p_to) or (requester = p_to and addressee = v_uid))) then
    raise exception 'not_friends';
  end if;
  if (select count(*) from public.direct_messages where from_user = v_uid and created_at > now() - interval '1 minute') >= 12 then
    raise exception 'too_many_messages';
  end if;
  insert into public.direct_messages (from_user, to_user, body) values (v_uid, p_to, v_body) returning id into v_id;
  return v_id;
end $$;

-- the conversation with one friend (oldest first) — also marks their messages to me as read
create or replace function public.dm_thread(p_other uuid, p_limit int default 40)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  update public.direct_messages set read_at = now() where to_user = v_uid and from_user = p_other and read_at is null;
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'from_user', m.from_user, 'body', m.body, 'created_at', m.created_at) order by m.id)
                     from (select * from public.direct_messages
                            where (from_user = v_uid and to_user = p_other) or (from_user = p_other and to_user = v_uid)
                            order by id desc limit least(greatest(coalesce(p_limit, 40), 1), 100)) m), '[]'::jsonb);
end $$;

-- unread messages for me, one line per friend
create or replace function public.my_unread_dms()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('from_id', x.from_user, 'from_name', p.display_name, 'count', x.n, 'last_body', x.last_body, 'last_at', x.last_at)
                            order by x.last_at desc), '[]'::jsonb)
    from (select from_user, count(*) as n, max(created_at) as last_at,
                 (array_agg(body order by id desc))[1] as last_body
            from public.direct_messages where to_user = auth.uid() and read_at is null group by from_user) x
    join public.profiles p on p.id = x.from_user;
$$;

-- ---------- 4) permissions
revoke execute on function public.cleanup_rooms(), public.heartbeat(uuid), public.send_dm(uuid, text),
                           public.dm_thread(uuid, int), public.my_unread_dms() from public, anon;
grant  execute on function public.cleanup_rooms(), public.heartbeat(uuid), public.send_dm(uuid, text),
                           public.dm_thread(uuid, int), public.my_unread_dms() to authenticated;
notify pgrst, 'reload schema';
