-- v3 API: weighted votes (rally), chairs, XP, profiles.

create or replace function pw.me_json(p pw.players) returns json
language sql stable set search_path = '' as $$
  select json_build_object(
    'nickname', p.nickname,
    'team', (select json_build_object('id', t.id, 'name', t.name, 'color', t.color, 'owner', t.owner_id = p.id)
             from pw.teams t where t.id = p.team_id),
    'owns', coalesce((select json_agg(t.id) from pw.teams t where t.owner_id = p.id), '[]'::json),
    'can_vote', (p.last_vote_at is null or date_trunc('hour', p.last_vote_at) < date_trunc('hour', now())),
    'next_vote_at', date_trunc('hour', now()) + interval '1 hour',
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

create or replace function public.pw_rally(p_secret text, p_target text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_p pw.players;
  v_ip text;
begin
  select * into v_p from pw.players where secret_hash = pw.secret_hash(p_secret) for update;
  if not found then raise exception 'not_joined'; end if;
  if v_p.team_id is null then raise exception 'no_team'; end if;
  if not exists (select 1 from pw.provinces where id = p_target) then raise exception 'bad_target'; end if;
  if v_p.last_rally_at is not null and v_p.last_rally_at > now() - interval '24 hours' then
    raise exception 'rally_cooldown';
  end if;
  v_ip := pw.ip_hash();
  if (select count(*) from pw.votes where ip_hash = v_ip and w > 1 and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'ip_limit';
  end if;
  insert into pw.votes (player_id, team_id, target, ip_hash, w)
  values (v_p.id, v_p.team_id, p_target, v_ip, greatest(1, coalesce(pw.cfg_int('rally_points'), 10)));
  update pw.players set last_rally_at = now() where id = v_p.id returning * into v_p;
  return pw.me_json(v_p);
end $$;

create or replace function public.pw_state() returns json
language sql stable security definer set search_path = '' as $$
with cfg as (
  select now() - make_interval(hours => pw.cfg_int('window_hours')) as since
),
w as (select v.* from pw.votes v, cfg where v.created_at > cfg.since),
tt as (
  select target, team_id, sum(w)::int as pts, min(created_at) as first_at from w group by target, team_id
),
ranked as (
  select tt.*, row_number() over (partition by target order by pts desc, first_at asc) as rn,
         (sum(pts) over (partition by target))::int as total
  from tt
),
lead as (select * from ranked where rn = 1),
topv as (
  select distinct on (w.target) w.target, pl.nickname, sum(w.w)::int as pts
  from w
  join lead r on r.target = w.target and r.team_id = w.team_id
  join pw.players pl on pl.id = w.player_id
  group by w.target, w.player_id, pl.nickname
  order by w.target, sum(w.w) desc, min(w.created_at)
),
chair as (
  select s.province_id, s.team_id, pl.nickname, s.price_cents
  from pw.seats s join pw.players pl on pl.id = s.holder_id
),
held as (select team_id, count(*)::int as n from lead group by team_id),
tpts as (select team_id, sum(w)::int as n from w group by team_id),
v24 as (select team_id, sum(w)::int as n from pw.votes where created_at > now() - interval '24 hours' group by team_id),
seatc as (select team_id, count(*)::int as n from pw.seats where holder_id is not null group by team_id),
mem as (select team_id, count(*)::int as n from pw.players where team_id is not null group by team_id),
feed as (
  (select 'v'::text as k, pl.nickname as n, v.team_id as t, v.target as i, pr.name as pn, pr.country as c, v.w as a, v.created_at as at
   from pw.votes v join pw.players pl on pl.id = v.player_id join pw.provinces pr on pr.id = v.target
   order by v.created_at desc limit 30)
  union all
  (select e.kind, pl.nickname, e.team_id, e.province_id, pr.name, pr.country, e.amount_cents, e.created_at
   from pw.events e left join pw.players pl on pl.id = e.player_id left join pw.provinces pr on pr.id = e.province_id
   order by e.created_at desc limit 15)
),
top as (
  select pl.id as pid, pl.nickname as n, pl.team_id as t, sum(w.w)::int as p
  from w join pw.players pl on pl.id = w.player_id
  group by pl.id, pl.nickname, pl.team_id
  order by 4 desc, min(w.created_at) limit 25
),
chairs as (
  select e.player_id, pl.nickname as n, e.team_id as t, e.province_id as i, pr.name as pn, pr.country as c,
         e.amount_cents as a, e.created_at as at
  from pw.events e join pw.players pl on pl.id = e.player_id join pw.provinces pr on pr.id = e.province_id
  where e.kind = 'seat'
  order by e.created_at desc limit 20
),
tsel as (
  select t.id from pw.teams t
  left join held h on h.team_id = t.id left join mem m on m.team_id = t.id
  order by coalesce(h.n, 0) desc, coalesce(m.n, 0) desc, t.created_at
  limit 300
),
tall as (
  select id from tsel
  union select team_id from ranked where rn <= 2
  union select t from feed where t is not null
  union select t from top where t is not null
  union select t from chairs where t is not null
)
select json_build_object(
  'now', now(),
  'window_hours', pw.cfg_int('window_hours'),
  'price_cents', pw.cfg_int('team_price_cents'),
  'unit_cents', pw.cfg_int('unit_cents'),
  'seat_base', pw.cfg_int('seat_base_cents'),
  'seat_step', pw.cfg_int('seat_step_cents'),
  'seat_xp', pw.cfg_int('seat_xp_per_hour'),
  'rally', pw.cfg_int('rally_points'),
  'checkout', (select v <> '' from pw.settings where k = 'checkout_url'),
  'contact', (select v from pw.settings where k = 'contact'),
  'map', coalesce((
    select json_agg(json_build_object(
      'i', r1.target, 'c', pr.country, 'nm', pr.name, 't', r1.team_id, 'p', r1.pts, 'n', r1.total,
      's', r2.team_id, 'sp', r2.pts,
      'g', coalesce(ch.nickname, g.nickname), 'gc', ch.nickname is not null, 'gp', g.pts, 'gs', ch.price_cents))
    from lead r1
    join pw.provinces pr on pr.id = r1.target
    left join ranked r2 on r2.target = r1.target and r2.rn = 2
    left join topv g on g.target = r1.target
    left join chair ch on ch.province_id = r1.target and ch.team_id = r1.team_id), '[]'::json),
  'teams', coalesce((
    select json_agg(json_build_object('id', t.id, 'name', t.name, 'color', t.color, 'owner', o.nickname,
                                      'members', coalesce(m.n, 0), 'held', coalesce(h.n, 0), 'sales', t.sales,
                                      'pts', coalesce(p.n, 0), 'v24', coalesce(d.n, 0), 'seats', coalesce(sc.n, 0)))
    from pw.teams t
    join tall a on a.id = t.id
    left join pw.players o on o.id = t.owner_id
    left join mem m on m.team_id = t.id
    left join held h on h.team_id = t.id
    left join tpts p on p.team_id = t.id
    left join v24 d on d.team_id = t.id
    left join seatc sc on sc.team_id = t.id), '[]'::json),
  'feed', coalesce((select json_agg(f order by f.at desc) from feed f), '[]'::json),
  'top', coalesce((select json_agg(json_build_object('n', x.n, 't', x.t, 'p', x.p, 'x', pw.player_xp(x.pid))) from top x), '[]'::json),
  'chairs', coalesce((select json_agg(json_build_object('n', c.n, 't', c.t, 'i', c.i, 'pn', c.pn, 'c', c.c, 'a', c.a, 'at', c.at)) from chairs c), '[]'::json),
  'players', (select count(*) from pw.players),
  'teams_total', (select count(*) from pw.teams),
  'votes24', (select coalesce(sum(w), 0) from pw.votes where created_at > now() - interval '24 hours'),
  'votes_hour', (select count(*) from pw.votes where created_at >= date_trunc('hour', now())),
  'seats_total', (select count(*) from pw.seats where holder_id is not null),
  'provinces_total', (select count(*) from pw.provinces)
);
$$;

create or replace function public.pw_province(p_id text) returns json
language sql stable security definer set search_path = '' as $$
with cfg as (
  select now() - make_interval(hours => pw.cfg_int('window_hours')) as since
),
w as (select v.* from pw.votes v, cfg where v.created_at > cfg.since and v.target = p_id),
tt as (select team_id, sum(w)::int as p, count(distinct player_id)::int as v, min(created_at) as f from w group by team_id)
select json_build_object(
  'id', p.id, 'name', p.name, 'country', p.country,
  'teams', coalesce((
    select json_agg(x) from (
      select tt.team_id as t, t.name, t.color, tt.p, tt.v
      from tt join pw.teams t on t.id = tt.team_id
      order by tt.p desc, tt.f limit 12) x), '[]'::json),
  'voters', coalesce((
    select json_agg(x) from (
      select pl.nickname as n, w.team_id as t, t.name as tn, t.color as tc, sum(w.w)::int as p
      from w join pw.players pl on pl.id = w.player_id join pw.teams t on t.id = w.team_id
      group by pl.id, pl.nickname, w.team_id, t.name, t.color
      order by 5 desc, min(w.created_at) limit 10) x), '[]'::json),
  'seats', coalesce((
    select json_agg(x) from (
      select s.team_id as t, t.name, t.color, pl.nickname as n, s.price_cents as price, s.takeovers as k, s.held_since as since
      from pw.seats s join pw.teams t on t.id = s.team_id join pw.players pl on pl.id = s.holder_id
      where s.province_id = p.id
      order by s.price_cents desc limit 30) x), '[]'::json),
  'recent', coalesce((
    select json_agg(x) from (
      select pl.nickname as n, v.team_id as t, v.w as a, v.created_at as at
      from pw.votes v join pw.players pl on pl.id = v.player_id
      where v.target = p.id
      order by v.created_at desc limit 8) x), '[]'::json),
  'base', pw.cfg_int('seat_base_cents'),
  'step', pw.cfg_int('seat_step_cents')
)
from pw.provinces p where p.id = p_id;
$$;

create or replace function public.pw_team(p_team uuid) returns json
language sql stable security definer set search_path = '' as $$
with cfg as (
  select now() - make_interval(hours => pw.cfg_int('window_hours')) as since
)
select json_build_object(
  'id', t.id, 'name', t.name, 'color', t.color, 'owner', o.nickname, 'founder', f.nickname,
  'sales', t.sales, 'created_at', t.created_at,
  'members', (select count(*) from pw.players where team_id = t.id),
  'pts', (select coalesce(sum(v.w), 0) from pw.votes v where v.team_id = t.id and v.created_at > (select since from cfg)),
  'v24', (select coalesce(sum(v.w), 0) from pw.votes v where v.team_id = t.id and v.created_at > now() - interval '24 hours'),
  'top', coalesce((
    select json_agg(x) from (
      select pl.nickname as n, coalesce(sum(v.w), 0)::int as p
      from pw.players pl
      left join pw.votes v on v.player_id = pl.id and v.team_id = t.id and v.created_at > (select since from cfg)
      where pl.team_id = t.id
      group by pl.id, pl.nickname
      order by 2 desc, pl.created_at limit 12) x), '[]'::json),
  'seats', coalesce((
    select json_agg(x) from (
      select s.province_id as i, pr.name as pn, pr.country as c, pl.nickname as n, s.price_cents as price
      from pw.seats s join pw.players pl on pl.id = s.holder_id join pw.provinces pr on pr.id = s.province_id
      where s.team_id = t.id
      order by s.price_cents desc, s.held_since limit 20) x), '[]'::json),
  'price_cents', pw.cfg_int('team_price_cents'),
  'checkout', (select v <> '' from pw.settings where k = 'checkout_url')
)
from pw.teams t
left join pw.players o on o.id = t.owner_id
left join pw.players f on f.id = t.founder_id
where t.id = p_team;
$$;

create or replace function public.pw_chairs() returns json
language sql stable security definer set search_path = '' as $$
select json_build_object(
  'list', coalesce((
    select json_agg(x) from (
      select s.province_id as i, pr.name as pn, pr.country as c, s.team_id as t, pl.nickname as n,
             s.price_cents as price, s.takeovers as k, s.held_since as since
      from pw.seats s join pw.players pl on pl.id = s.holder_id join pw.provinces pr on pr.id = s.province_id
      order by s.price_cents desc, s.held_since limit 100) x), '[]'::json),
  'holders', coalesce((
    select json_agg(x) from (
      select pl.nickname as n, pl.team_id as t, count(*)::int as c, sum(s.price_cents)::int as s
      from pw.seats s join pw.players pl on pl.id = s.holder_id
      group by pl.id, pl.nickname, pl.team_id
      order by 3 desc, 4 desc limit 25) x), '[]'::json),
  'total', (select count(*) from pw.seats where holder_id is not null)
);
$$;

create or replace function public.pw_profile(p_nick text) returns json
language sql stable security definer set search_path = '' as $$
select json_build_object(
  'nickname', p.nickname, 'joined', p.created_at,
  'team', (select json_build_object('id', t.id, 'name', t.name, 'color', t.color) from pw.teams t where t.id = p.team_id),
  'xp', pw.player_xp(p.id),
  'votes', (select count(*) from pw.votes v where v.player_id = p.id and v.w = 1),
  'rallies', (select count(*) from pw.votes v where v.player_id = p.id and v.w > 1),
  'points', (select coalesce(sum(v.w), 0) from pw.votes v where v.player_id = p.id),
  'countries', (select count(distinct pr.country) from pw.votes v join pw.provinces pr on pr.id = v.target where v.player_id = p.id),
  'seats', coalesce((
    select json_agg(x) from (
      select s.province_id as i, pr.name as pn, pr.country as c, s.team_id as t, s.price_cents as price, s.held_since as since
      from pw.seats s join pw.provinces pr on pr.id = s.province_id
      where s.holder_id = p.id order by s.price_cents desc limit 50) x), '[]'::json),
  'owns', coalesce((select json_agg(x) from (select t.id, t.name, t.color from pw.teams t where t.owner_id = p.id) x), '[]'::json),
  'fav', coalesce((
    select json_agg(x) from (
      select v.target as i, pr.name as pn, pr.country as c, sum(v.w)::int as p
      from pw.votes v join pw.provinces pr on pr.id = v.target
      where v.player_id = p.id
      group by v.target, pr.name, pr.country order by 4 desc limit 5) x), '[]'::json)
)
from pw.players p where lower(p.nickname) = lower(btrim(coalesce(p_nick, '')));
$$;

create or replace function public.pw_meta() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'pc', coalesce((select json_object_agg(iso2, province_count) from pw.countries where province_count > 0), '{}'::json),
    'price_cents', pw.cfg_int('team_price_cents'),
    'seat_base', pw.cfg_int('seat_base_cents'),
    'seat_step', pw.cfg_int('seat_step_cents'),
    'checkout', (select v <> '' from pw.settings where k = 'checkout_url')
  );
$$;

create or replace function public.pw_purchase_start(p_secret text, p_team uuid) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_p pw.players;
  v_t pw.teams;
  v_url text;
  v_id uuid;
  v_price int := pw.cfg_int('team_price_cents');
  v_qty int;
begin
  select * into v_p from pw.players where secret_hash = pw.secret_hash(p_secret);
  if not found then raise exception 'not_joined'; end if;
  select * into v_t from pw.teams where id = p_team;
  if not found then raise exception 'bad_team'; end if;
  if v_t.owner_id = v_p.id then raise exception 'already_owner'; end if;
  select v into v_url from pw.settings where k = 'checkout_url';
  if coalesce(v_url, '') = '' then raise exception 'sales_closed'; end if;
  if (select count(*) from pw.purchases where player_id = v_p.id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too_many_requests';
  end if;
  v_qty := ceil(v_price::numeric / greatest(1, coalesce(pw.cfg_int('unit_cents'), 100)))::int;
  insert into pw.purchases (player_id, team_id, kind, price_cents) values (v_p.id, p_team, 'team', v_price) returning id into v_id;
  return json_build_object('id', v_id, 'price_cents', v_price, 'url',
    v_url || case when position('?' in v_url) > 0 then '&' else '?' end
          || 'quantity=' || v_qty || '&checkout[custom][purchase_id]=' || v_id);
end $$;

create or replace function public.pw_seat_start(p_secret text, p_province text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_p pw.players;
  v_url text;
  v_id uuid;
  v_price int;
  v_qty int;
begin
  select * into v_p from pw.players where secret_hash = pw.secret_hash(p_secret);
  if not found then raise exception 'not_joined'; end if;
  if v_p.team_id is null then raise exception 'no_team'; end if;
  if not exists (select 1 from pw.provinces where id = p_province) then raise exception 'bad_target'; end if;
  select v into v_url from pw.settings where k = 'checkout_url';
  if coalesce(v_url, '') = '' then raise exception 'sales_closed'; end if;
  if exists (select 1 from pw.seats where province_id = p_province and team_id = v_p.team_id and holder_id = v_p.id) then
    raise exception 'already_chair';
  end if;
  if (select count(*) from pw.purchases where player_id = v_p.id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too_many_requests';
  end if;
  v_price := pw.seat_price(p_province, v_p.team_id);
  v_qty := ceil(v_price::numeric / greatest(1, coalesce(pw.cfg_int('unit_cents'), 100)))::int;
  insert into pw.purchases (player_id, team_id, kind, province_id, price_cents)
  values (v_p.id, v_p.team_id, 'seat', p_province, v_price) returning id into v_id;
  return json_build_object('id', v_id, 'price_cents', v_price, 'url',
    v_url || case when position('?' in v_url) > 0 then '&' else '?' end
          || 'quantity=' || v_qty || '&checkout[custom][purchase_id]=' || v_id);
end $$;

-- Called only by the Lemon Squeezy webhook (service role). p_amount = cents actually paid before tax.
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
  if exists (select 1 from pw.purchases where order_id = p_order) then
    return json_build_object('ok', true, 'duplicate', true);
  end if;
  select * into v_pu from pw.purchases where id = p_purchase for update;
  if not found then return json_build_object('ok', false, 'error', 'unknown_purchase'); end if;
  if v_pu.status <> 'pending' or v_pu.order_id is not null then
    return json_build_object('ok', true, 'status', v_pu.status);
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

create or replace function public.pw_purchase_status(p_secret text, p_purchase uuid) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'status', case when pu.problem is not null then 'problem' else pu.status end,
    'kind', pu.kind, 'team_id', pu.team_id, 'team', t.name,
    'province', pu.province_id, 'pname', pr.name, 'country', pr.country, 'problem', pu.problem)
  from pw.purchases pu
  join pw.teams t on t.id = pu.team_id
  join pw.players pl on pl.id = pu.player_id
  left join pw.provinces pr on pr.id = pu.province_id
  where pu.id = p_purchase and pl.secret_hash = pw.secret_hash(p_secret);
$$;

create or replace function public.pw_team_join(p_secret text, p_team uuid) returns json
language plpgsql security definer set search_path = '' as $$
declare v_p pw.players;
begin
  select * into v_p from pw.players where secret_hash = pw.secret_hash(p_secret) for update;
  if not found then raise exception 'not_joined'; end if;
  if not exists (select 1 from pw.teams where id = p_team) then raise exception 'bad_team'; end if;
  if v_p.team_id = p_team then return pw.me_json(v_p); end if;
  if v_p.team_id is not null then
    if exists (select 1 from pw.teams where id = v_p.team_id and owner_id = v_p.id) then raise exception 'owner_cannot_leave'; end if;
    if v_p.team_joined_at > now() - interval '24 hours' then raise exception 'switch_cooldown'; end if;
    perform pw.vacate_seats(v_p.id, v_p.team_id);
  end if;
  update pw.players set team_id = p_team, team_joined_at = now() where id = v_p.id returning * into v_p;
  return pw.me_json(v_p);
end $$;

create or replace function public.pw_team_create(p_secret text, p_name text, p_color text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_p pw.players;
  v_name text := pw.clean_name(p_name);
  v_color text := lower(btrim(coalesce(p_color, '')));
  v_t pw.teams;
begin
  select * into v_p from pw.players where secret_hash = pw.secret_hash(p_secret) for update;
  if not found then raise exception 'not_joined'; end if;
  perform pw.check_team_name(v_name);
  if v_color !~ '^#[0-9a-f]{6}$' then raise exception 'bad_color'; end if;
  if v_p.last_team_created_at > now() - interval '24 hours' then raise exception 'team_create_cooldown'; end if;
  if v_p.team_id is not null then
    if exists (select 1 from pw.teams where id = v_p.team_id and owner_id = v_p.id) then raise exception 'owner_cannot_leave'; end if;
    if v_p.team_joined_at > now() - interval '24 hours' then raise exception 'switch_cooldown'; end if;
  end if;
  begin
    insert into pw.teams (name, color, owner_id, founder_id) values (v_name, v_color, v_p.id, v_p.id) returning * into v_t;
  exception when unique_violation then
    raise exception 'team_name_taken';
  end;
  perform pw.vacate_seats(v_p.id, v_p.team_id);
  update pw.players set team_id = v_t.id, team_joined_at = now(), last_team_created_at = now()
   where id = v_p.id returning * into v_p;
  insert into pw.events (kind, team_id, player_id) values ('created', v_t.id, v_p.id);
  return pw.me_json(v_p);
end $$;
