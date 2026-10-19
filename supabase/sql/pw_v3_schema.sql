-- v3: province seats ($1 il başkanlığı per team), rally votes, XP. Additive only.
alter table pw.votes add column if not exists w int not null default 1;
alter table pw.players add column if not exists xp_bank int not null default 0;
alter table pw.players add column if not exists last_rally_at timestamptz;
alter table pw.purchases add column if not exists kind text not null default 'team';
alter table pw.purchases add column if not exists province_id text references pw.provinces (id);
alter table pw.purchases add column if not exists price_cents int;
alter table pw.purchases add column if not exists problem text;
alter table pw.events add column if not exists province_id text references pw.provinces (id);
alter table pw.events add column if not exists amount_cents int;

-- One chair per (province, team). holder_id null = vacant (next buyer pays the base price again).
create table if not exists pw.seats (
  province_id text not null references pw.provinces (id),
  team_id     uuid not null references pw.teams (id) on delete cascade,
  holder_id   uuid references pw.players (id) on delete set null,
  price_cents int  not null check (price_cents > 0),
  takeovers   int  not null default 1,
  held_since  timestamptz not null default now(),
  primary key (province_id, team_id)
);
create index if not exists seats_holder on pw.seats (holder_id);
create index if not exists seats_price on pw.seats (price_cents desc);
create index if not exists events_kind_created on pw.events (kind, created_at desc);
revoke all on pw.seats from anon, authenticated;

insert into pw.settings (k, v)
select x.k, x.v from (values
  ('unit_cents', '100'),        -- price of the single $1 Lemon Squeezy product; quantity = price / unit
  ('seat_base_cents', '100'),   -- empty chair
  ('seat_step_cents', '100'),   -- takeover = current price + step (0 = always flat base price)
  ('seat_xp_per_hour', '20'),
  ('rally_points', '10'),
  ('contact', '')
) as x(k, v)
where not exists (select 1 from pw.settings s where s.k = x.k);

create or replace function pw.cfg_int(p_k text) returns int
language sql stable set search_path = '' as $$
  select v::int from pw.settings where k = p_k;
$$;

create or replace function pw.seat_hours_xp(p_since timestamptz) returns int
language sql stable set search_path = '' as $$
  select (floor(extract(epoch from (now() - p_since)) / 3600))::int * coalesce(pw.cfg_int('seat_xp_per_hour'), 20);
$$;

create or replace function pw.player_xp(p_id uuid) returns int
language sql stable set search_path = '' as $$
  select (coalesce((select sum(v.w) from pw.votes v where v.player_id = p_id), 0)
        + coalesce((select p.xp_bank from pw.players p where p.id = p_id), 0)
        + coalesce((select sum(pw.seat_hours_xp(s.held_since)) from pw.seats s where s.holder_id = p_id), 0))::int;
$$;

create or replace function pw.seat_price(p_province text, p_team uuid) returns int
language sql stable set search_path = '' as $$
  select coalesce(
    (select least(s.price_cents + coalesce(pw.cfg_int('seat_step_cents'), 100), 1000000)
       from pw.seats s where s.province_id = p_province and s.team_id = p_team and s.holder_id is not null),
    coalesce(pw.cfg_int('seat_base_cents'), 100));
$$;

-- A player who leaves a team gives up its chairs; hours already served stay as XP.
create or replace function pw.vacate_seats(p_player uuid, p_team uuid) returns void
language plpgsql set search_path = '' as $$
declare v_xp int;
begin
  if p_team is null then return; end if;
  select coalesce(sum(pw.seat_hours_xp(held_since)), 0) into v_xp
    from pw.seats where holder_id = p_player and team_id = p_team;
  update pw.seats set holder_id = null, held_since = now() where holder_id = p_player and team_id = p_team;
  if v_xp > 0 then update pw.players set xp_bank = xp_bank + v_xp where id = p_player; end if;
end $$;
