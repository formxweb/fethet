-- v4: paid team creation ($2 by default; setting team_create_cents = 0 makes it free again).
create table if not exists pw.create_orders (
  id           uuid primary key default gen_random_uuid(),
  player_id    uuid not null references pw.players (id) on delete cascade,
  name         text not null,
  color        text not null,
  status       text not null default 'pending',
  problem      text,
  price_cents  int  not null,
  order_id     text unique,
  amount_cents int,
  team_id      uuid references pw.teams (id) on delete set null,
  created_at   timestamptz not null default now(),
  paid_at      timestamptz
);
create index if not exists create_orders_player on pw.create_orders (player_id, created_at desc);
revoke all on pw.create_orders from anon, authenticated;

insert into pw.settings (k, v)
select 'team_create_cents', '200'
where not exists (select 1 from pw.settings where k = 'team_create_cents');

create or replace function public.pw_create_start(p_secret text, p_name text, p_color text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_p pw.players;
  v_name text := pw.clean_name(p_name);
  v_color text := lower(btrim(coalesce(p_color, '')));
  v_price int := coalesce(pw.cfg_int('team_create_cents'), 0);
  v_url text;
  v_id uuid;
  v_qty int;
begin
  select * into v_p from pw.players where secret_hash = pw.secret_hash(p_secret);
  if not found then raise exception 'not_joined'; end if;
  if v_price <= 0 then raise exception 'free_create'; end if;
  perform pw.check_team_name(v_name);
  if v_color !~ '^#[0-9a-f]{6}$' then raise exception 'bad_color'; end if;
  if exists (select 1 from pw.teams where lower(name) = lower(v_name)) then raise exception 'team_name_taken'; end if;
  if v_p.team_id is not null and exists (select 1 from pw.teams where id = v_p.team_id and owner_id = v_p.id) then
    raise exception 'owner_cannot_leave';
  end if;
  select v into v_url from pw.settings where k = 'checkout_url';
  if coalesce(v_url, '') = '' then raise exception 'sales_closed'; end if;
  if (select count(*) from pw.purchases where player_id = v_p.id and created_at > now() - interval '1 hour')
   + (select count(*) from pw.create_orders where player_id = v_p.id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too_many_requests';
  end if;
  v_qty := ceil(v_price::numeric / greatest(1, coalesce(pw.cfg_int('unit_cents'), 100)))::int;
  insert into pw.create_orders (player_id, name, color, price_cents) values (v_p.id, v_name, v_color, v_price) returning id into v_id;
  return json_build_object('id', v_id, 'price_cents', v_price, 'url',
    v_url || case when position('?' in v_url) > 0 then '&' else '?' end
          || 'quantity=' || v_qty || '&checkout[custom][purchase_id]=' || v_id);
end $$;

create or replace function pw.complete_create(p_id uuid, p_order text, p_amount int) returns json
language plpgsql set search_path = '' as $$
declare
  v_co pw.create_orders;
  v_name text;
  v_i int := 1;
  v_old uuid;
  v_tid uuid;
begin
  select * into v_co from pw.create_orders where id = p_id for update;
  if not found then return json_build_object('ok', false, 'error', 'unknown_purchase'); end if;
  if v_co.status <> 'pending' or v_co.order_id is not null then
    return json_build_object('ok', true, 'status', v_co.status);
  end if;
  if p_amount < floor(v_co.price_cents * 0.98) then
    update pw.create_orders set order_id = p_order, amount_cents = p_amount, paid_at = now(), problem = 'underpaid' where id = p_id;
    return json_build_object('ok', false, 'problem', 'underpaid');
  end if;
  v_name := v_co.name;
  loop
    begin
      insert into pw.teams (name, color, owner_id, founder_id) values (v_name, v_co.color, v_co.player_id, v_co.player_id) returning id into v_tid;
      exit;
    exception when unique_violation then
      v_i := v_i + 1;
      v_name := left(v_co.name, 21) || ' ' || v_i;
      if v_i > 99 then v_name := left(v_co.name, 15) || ' ' || substr(md5(random()::text), 1, 6); end if;
    end;
  end loop;
  select team_id into v_old from pw.players where id = v_co.player_id;
  perform pw.vacate_seats(v_co.player_id, v_old);
  update pw.players set team_id = v_tid, team_joined_at = now(), last_team_created_at = now() where id = v_co.player_id;
  insert into pw.events (kind, team_id, player_id, amount_cents) values ('created', v_tid, v_co.player_id, p_amount);
  update pw.create_orders set status = 'paid', order_id = p_order, amount_cents = p_amount, paid_at = now(), team_id = v_tid, name = v_name where id = p_id;
  return json_build_object('ok', true, 'team', v_tid);
end $$;

-- Webhook entry point: team/chair purchases live in pw.purchases, team creations in pw.create_orders.
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
  select coalesce(
    (select json_build_object(
       'status', case when pu.problem is not null then 'problem' else pu.status end,
       'kind', pu.kind, 'team_id', pu.team_id, 'team', t.name,
       'province', pu.province_id, 'pname', pr.name, 'country', pr.country, 'problem', pu.problem)
     from pw.purchases pu
     join pw.teams t on t.id = pu.team_id
     join pw.players pl on pl.id = pu.player_id
     left join pw.provinces pr on pr.id = pu.province_id
     where pu.id = p_purchase and pl.secret_hash = pw.secret_hash(p_secret)),
    (select json_build_object(
       'status', case when co.problem is not null then 'problem' else co.status end,
       'kind', 'create', 'team_id', co.team_id, 'team', co.name,
       'province', null, 'pname', null, 'country', null, 'problem', co.problem)
     from pw.create_orders co
     join pw.players pl on pl.id = co.player_id
     where co.id = p_purchase and pl.secret_hash = pw.secret_hash(p_secret)));
$$;

-- The free path is closed while team creation is paid.
create or replace function public.pw_team_create(p_secret text, p_name text, p_color text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  v_p pw.players;
  v_name text := pw.clean_name(p_name);
  v_color text := lower(btrim(coalesce(p_color, '')));
  v_t pw.teams;
begin
  if coalesce(pw.cfg_int('team_create_cents'), 0) > 0 then raise exception 'payment_required'; end if;
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

create or replace function public.pw_meta() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'pc', coalesce((select json_object_agg(iso2, province_count) from pw.countries where province_count > 0), '{}'::json),
    'price_cents', pw.cfg_int('team_price_cents'),
    'create_price', coalesce(pw.cfg_int('team_create_cents'), 0),
    'seat_base', pw.cfg_int('seat_base_cents'),
    'seat_step', pw.cfg_int('seat_step_cents'),
    'checkout', (select v <> '' from pw.settings where k = 'checkout_url')
  );
$$;
