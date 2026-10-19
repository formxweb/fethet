-- v5: vote booster. $1 → for 24 hours the vote cooldown is 10 minutes instead of one clock hour.
alter table pw.players add column if not exists boost_until timestamptz;

insert into pw.settings (k, v)
select x.k, x.v from (values ('boost_cents', '100'), ('boost_hours', '24'), ('boost_minutes', '10')) as x(k, v)
where not exists (select 1 from pw.settings s where s.k = x.k);

create or replace function pw.boost_on(p pw.players) returns boolean
language sql stable set search_path = '' as $$
  select p.boost_until is not null and p.boost_until > now();
$$;

create or replace function pw.me_json(p pw.players) returns json
language sql stable set search_path = '' as $$
  select json_build_object(
    'nickname', p.nickname,
    'team', (select json_build_object('id', t.id, 'name', t.name, 'color', t.color, 'owner', t.owner_id = p.id)
             from pw.teams t where t.id = p.team_id),
    'owns', coalesce((select json_agg(t.id) from pw.teams t where t.owner_id = p.id), '[]'::json),
    'can_vote', case when pw.boost_on(p)
                  then (p.last_vote_at is null or p.last_vote_at <= now() - make_interval(mins => coalesce(pw.cfg_int('boost_minutes'), 10)))
                  else (p.last_vote_at is null or date_trunc('hour', p.last_vote_at) < date_trunc('hour', now())) end,
    'next_vote_at', case when pw.boost_on(p) and p.last_vote_at is not null
                  then p.last_vote_at + make_interval(mins => coalesce(pw.cfg_int('boost_minutes'), 10))
                  else date_trunc('hour', now()) + interval '1 hour' end,
    'boost_until', case when pw.boost_on(p) then p.boost_until end,
    'can_rally', (p.last_rally_at is null or p.last_rally_at <= now() - interval '24 hours'),
    'rally_at', p.last_rally_at + interval '24 hours',
    'switch_at', p.team_joined_at + interval '24 hours',
    'votes', (select count(*) from pw.votes v where v.player_id = p.id),
    'xp', pw.player_xp(p.id),
    'seats', (select count(*) from pw.seats s where s.holder_id = p.id),
    'joined', p.created_at,
    'now', now()
  );
$$;

create or replace function public.pw_vote(p_secret text, p_target text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_p pw.players;
  v_ip text;
begin
  select * into v_p from pw.players where secret_hash = pw.secret_hash(p_secret) for update;
  if not found then raise exception 'not_joined'; end if;
  if v_p.team_id is null then raise exception 'no_team'; end if;
  if not exists (select 1 from pw.provinces where id = p_target) then raise exception 'bad_target'; end if;
  if v_p.last_vote_at is not null then
    if pw.boost_on(v_p) then
      if v_p.last_vote_at > now() - make_interval(mins => coalesce(pw.cfg_int('boost_minutes'), 10)) then raise exception 'cooldown'; end if;
    elsif date_trunc('hour', v_p.last_vote_at) >= date_trunc('hour', now()) then
      raise exception 'cooldown';
    end if;
  end if;
  v_ip := pw.ip_hash();
  if (select count(*) from pw.votes where ip_hash = v_ip and created_at >= date_trunc('hour', now())) >= 60 then
    raise exception 'ip_limit';
  end if;
  insert into pw.votes (player_id, team_id, target, ip_hash) values (v_p.id, v_p.team_id, p_target, v_ip);
  update pw.players set last_vote_at = now() where id = v_p.id returning * into v_p;
  return pw.me_json(v_p);
end $$;

create or replace function public.pw_boost_start(p_secret text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_p pw.players;
  v_url text;
  v_id uuid;
  v_price int := coalesce(pw.cfg_int('boost_cents'), 100);
  v_qty int;
begin
  select * into v_p from pw.players where secret_hash = pw.secret_hash(p_secret);
  if not found then raise exception 'not_joined'; end if;
  if v_p.team_id is null then raise exception 'no_team'; end if;
  select v into v_url from pw.settings where k = 'checkout_url';
  if coalesce(v_url, '') = '' then raise exception 'sales_closed'; end if;
  if (select count(*) from pw.purchases where player_id = v_p.id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too_many_requests';
  end if;
  v_qty := ceil(v_price::numeric / greatest(1, coalesce(pw.cfg_int('unit_cents'), 100)))::int;
  insert into pw.purchases (player_id, team_id, kind, price_cents) values (v_p.id, v_p.team_id, 'boost', v_price) returning id into v_id;
  return json_build_object('id', v_id, 'price_cents', v_price, 'url',
    v_url || case when position('?' in v_url) > 0 then '&' else '?' end
          || 'quantity=' || v_qty || '&checkout[custom][purchase_id]=' || v_id);
end $$;

create or replace function public.pw_admin_complete_purchase(p_purchase uuid, p_order text, p_amount integer) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_pu pw.purchases;
  v_s pw.seats;
  v_found boolean;
  v_req int;
  v_problem text;
  v_old_team uuid;
begin
  if exists (select 1 from pw.purchases where order_id = p_order) or exists (select 1 from pw.create_orders where order_id = p_order) then
    return json_build_object('ok', true, 'duplicate', true);
  end if;
  select * into v_pu from pw.purchases where id = p_purchase for update;
  if not found then return pw.complete_create(p_purchase, p_order, p_amount); end if;
  if v_pu.status <> 'pending' or v_pu.order_id is not null then
    return json_build_object('ok', true, 'status', v_pu.status);
  end if;

  if v_pu.kind = 'boost' then
    if p_amount < floor(coalesce(v_pu.price_cents, pw.cfg_int('boost_cents'), 100) * 0.98) then
      update pw.purchases set order_id = p_order, amount_cents = p_amount, paid_at = now(), problem = 'underpaid' where id = p_purchase;
      return json_build_object('ok', false, 'problem', 'underpaid');
    end if;
    update pw.players
       set boost_until = greatest(coalesce(boost_until, now()), now()) + make_interval(hours => coalesce(pw.cfg_int('boost_hours'), 24))
     where id = v_pu.player_id;
    update pw.purchases set status = 'paid', order_id = p_order, amount_cents = p_amount, paid_at = now() where id = p_purchase;
    insert into pw.events (kind, team_id, player_id, amount_cents) values ('boost', v_pu.team_id, v_pu.player_id, p_amount);
    return json_build_object('ok', true);
  end if;

  if v_pu.kind = 'seat' then
    select * into v_s from pw.seats where province_id = v_pu.province_id and team_id = v_pu.team_id for update;
    v_found := found;
    v_req := pw.seat_price(v_pu.province_id, v_pu.team_id);
    if p_amount < floor(v_req * 0.98) then v_problem := 'seat_changed';
    elsif not exists (select 1 from pw.players where id = v_pu.player_id and team_id = v_pu.team_id) then v_problem := 'left_team';
    elsif v_found and v_s.holder_id = v_pu.player_id then v_problem := 'already_chair';
    end if;
    if v_problem is not null then
      update pw.purchases set order_id = p_order, amount_cents = p_amount, paid_at = now(), problem = v_problem where id = p_purchase;
      return json_build_object('ok', false, 'problem', v_problem, 'required', v_req);
    end if;
    if v_found then
      if v_s.holder_id is not null then
        update pw.players set xp_bank = xp_bank + pw.seat_hours_xp(v_s.held_since) where id = v_s.holder_id;
      end if;
      update pw.seats set holder_id = v_pu.player_id, price_cents = v_req, takeovers = takeovers + 1, held_since = now()
       where province_id = v_pu.province_id and team_id = v_pu.team_id;
    else
      insert into pw.seats (province_id, team_id, holder_id, price_cents) values (v_pu.province_id, v_pu.team_id, v_pu.player_id, v_req);
    end if;
    update pw.purchases set status = 'paid', order_id = p_order, amount_cents = p_amount, paid_at = now() where id = p_purchase;
    insert into pw.events (kind, team_id, player_id, province_id, amount_cents)
    values ('seat', v_pu.team_id, v_pu.player_id, v_pu.province_id, v_req);
    return json_build_object('ok', true);
  end if;

  if p_amount < floor(pw.cfg_int('team_price_cents') * 0.98) then
    update pw.purchases set order_id = p_order, amount_cents = p_amount, paid_at = now(), problem = 'underpaid' where id = p_purchase;
    return json_build_object('ok', false, 'problem', 'underpaid');
  end if;
  select team_id into v_old_team from pw.players where id = v_pu.player_id;
  if v_old_team is distinct from v_pu.team_id then perform pw.vacate_seats(v_pu.player_id, v_old_team); end if;
  update pw.purchases set status = 'paid', order_id = p_order, amount_cents = p_amount, paid_at = now() where id = p_purchase;
  update pw.teams set owner_id = v_pu.player_id, sales = sales + 1 where id = v_pu.team_id;
  update pw.players set team_id = v_pu.team_id, team_joined_at = now() where id = v_pu.player_id;
  insert into pw.events (kind, team_id, player_id, amount_cents) values ('sold', v_pu.team_id, v_pu.player_id, p_amount);
  return json_build_object('ok', true);
end $$;
revoke all on function public.pw_admin_complete_purchase(uuid, text, integer) from public, anon, authenticated;

create or replace function public.pw_meta() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'pc', coalesce((select json_object_agg(iso2, province_count) from pw.countries where province_count > 0), '{}'::json),
    'price_cents', pw.cfg_int('team_price_cents'),
    'create_price', coalesce(pw.cfg_int('team_create_cents'), 0),
    'seat_base', pw.cfg_int('seat_base_cents'),
    'seat_step', pw.cfg_int('seat_step_cents'),
    'boost_price', coalesce(pw.cfg_int('boost_cents'), 100),
    'boost_hours', coalesce(pw.cfg_int('boost_hours'), 24),
    'boost_minutes', coalesce(pw.cfg_int('boost_minutes'), 10),
    'checkout', (select v <> '' from pw.settings where k = 'checkout_url')
  );
$$;
