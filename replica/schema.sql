-- First migration for the one-on-one booking loop.
-- Postgres 15+ (Supabase). Access: row level security for hosts.
-- Guests never get table grants. They go through book_slot / reschedule_slot / cancel_slot.

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- Supabase already has these. Local Postgres does not.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end
$$;

create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Host profile. id matches auth.users.
create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  handle text not null unique,
  time_zone text not null default 'UTC',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint handle_format check (handle ~ '^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$')
);

create trigger profiles_updated
  before update on profiles
  for each row execute function set_updated_at();

-- Official calendar OAuth (Google or Microsoft), with the user's own keys.
-- Tokens are ciphertext. Never store the provider access token in plaintext.
create table calendar_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  provider text not null check (provider in ('google', 'microsoft')),
  provider_account_id text not null,
  token_ciphertext bytea not null,
  refresh_expires_at timestamptz,
  status text not null default 'active'
    check (status in ('active', 'error', 'revoked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, provider, provider_account_id)
);

create index calendar_connections_user_idx on calendar_connections (user_id);

create trigger calendar_connections_updated
  before update on calendar_connections
  for each row execute function set_updated_at();

create table external_calendars (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references calendar_connections (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  provider_calendar_id text not null,
  summary text not null default '',
  check_conflicts boolean not null default false,
  write_events boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (connection_id, provider_calendar_id)
);

create index external_calendars_user_idx on external_calendars (user_id);

create trigger external_calendars_updated
  before update on external_calendars
  for each row execute function set_updated_at();

-- One schedule has one time zone. Weekly rules and date overrides hang off it.
create table schedules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  name text not null default 'Working hours',
  time_zone text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index schedules_user_idx on schedules (user_id);

create trigger schedules_updated
  before update on schedules
  for each row execute function set_updated_at();

-- Minutes from local midnight in schedules.time_zone. 0 = Sunday.
create table schedule_rules (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references schedules (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  start_minute smallint not null check (start_minute between 0 and 1439),
  end_minute smallint not null check (end_minute between 1 and 1440),
  created_at timestamptz not null default now(),
  constraint rule_has_length check (end_minute > start_minute)
);

create index schedule_rules_schedule_idx on schedule_rules (schedule_id, weekday);

create table schedule_overrides (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references schedules (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  on_date date not null,
  unavailable boolean not null default false,
  start_minute smallint check (start_minute between 0 and 1439),
  end_minute smallint check (end_minute between 1 and 1440),
  created_at timestamptz not null default now(),
  constraint override_shape check (
    (unavailable and start_minute is null and end_minute is null)
    or (
      not unavailable
      and start_minute is not null
      and end_minute is not null
      and end_minute > start_minute
    )
  )
);

create index schedule_overrides_schedule_idx on schedule_overrides (schedule_id, on_date);

create table event_types (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles (id) on delete cascade,
  schedule_id uuid not null references schedules (id) on delete restrict,
  kind text not null default 'one_on_one' check (kind in ('one_on_one')),
  name text not null,
  slug text not null,
  color text not null default '#111111',
  duration_min smallint not null check (duration_min > 0 and duration_min <= 720),
  location_kind text not null default 'video'
    check (location_kind in ('video', 'phone', 'in_person', 'other')),
  location_detail text not null default '',
  description text not null default '',
  active boolean not null default true,
  buffer_before_min smallint not null default 0 check (buffer_before_min >= 0),
  buffer_after_min smallint not null default 0 check (buffer_after_min >= 0),
  max_per_day smallint check (max_per_day is null or max_per_day > 0),
  max_per_week smallint check (max_per_week is null or max_per_week > 0),
  max_per_month smallint check (max_per_month is null or max_per_month > 0),
  min_notice_min integer not null default 0 check (min_notice_min >= 0),
  booking_window_days smallint not null default 60 check (booking_window_days between 1 and 365),
  start_increment_min smallint not null default 30 check (start_increment_min > 0),
  time_zone_locked boolean not null default false,
  locked_time_zone text,
  cancellation_policy text not null default '',
  price_cents integer check (price_cents is null or price_cents >= 0),
  currency char(3) not null default 'usd',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, slug),
  constraint locked_zone_present check (not time_zone_locked or locked_time_zone is not null),
  constraint slug_format check (slug ~ '^[a-z0-9](?:[a-z0-9-]{0,60}[a-z0-9])?$')
);

create index event_types_user_idx on event_types (user_id);
create index event_types_schedule_idx on event_types (schedule_id);

create trigger event_types_updated
  before update on event_types
  for each row execute function set_updated_at();

create table booking_questions (
  id uuid primary key default gen_random_uuid(),
  event_type_id uuid not null references event_types (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  label text not null,
  kind text not null check (kind in ('text', 'phone', 'select')),
  required boolean not null default false,
  position smallint not null default 0,
  options jsonb not null default '[]',
  created_at timestamptz not null default now()
);

create index booking_questions_event_idx on booking_questions (event_type_id, position);

create table bookings (
  id uuid primary key default gen_random_uuid(),
  event_type_id uuid not null references event_types (id) on delete restrict,
  host_id uuid not null references profiles (id) on delete cascade,
  start_at timestamptz not null,
  end_at timestamptz not null,
  -- Busy interval snapped at insert time, including that event type's buffers.
  blocked_start timestamptz not null,
  blocked_end timestamptz not null,
  guest_name text not null,
  guest_email text not null,
  guest_time_zone text not null,
  status text not null default 'pending'
    check (status in ('pending', 'confirmed', 'cancelled', 'rescheduled', 'expired')),
  answers jsonb not null default '{}',
  cancel_reason text,
  reschedule_of uuid references bookings (id) on delete set null,
  manage_token_hash text not null,
  hold_expires_at timestamptz,
  idempotency_key text not null,
  price_cents integer check (price_cents is null or price_cents >= 0),
  currency char(3) not null default 'usd',
  stripe_checkout_session_id text,
  stripe_payment_intent_id text,
  paid_at timestamptz,
  calendar_event_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint booking_has_length check (end_at > start_at),
  constraint buffer_wraps_meeting check (
    blocked_start <= start_at and blocked_end >= end_at
  ),
  unique (host_id, idempotency_key)
);

create index bookings_host_start_idx on bookings (host_id, start_at);
create index bookings_event_start_idx on bookings (event_type_id, start_at);
create index bookings_guest_email_idx on bookings (guest_email);
create index bookings_manage_token_idx on bookings (manage_token_hash);
create index bookings_pending_expiry_idx on bookings (hold_expires_at)
  where status = 'pending';

-- Overlap is a database problem. Pending holds count until they expire.
alter table bookings
  add constraint bookings_no_overlap
  exclude using gist (
    host_id with =,
    tstzrange(blocked_start, blocked_end, '[)') with &&
  )
  where (status in ('pending', 'confirmed'));

create trigger bookings_updated
  before update on bookings
  for each row execute function set_updated_at();

create table notifications (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings (id) on delete cascade,
  host_id uuid not null references profiles (id) on delete cascade,
  kind text not null check (kind in ('confirmation', 'reschedule', 'cancel', 'reminder', 'host_notice')),
  channel text not null check (channel in ('email', 'sms')),
  send_at timestamptz not null,
  sent_at timestamptz,
  status text not null default 'queued'
    check (status in ('queued', 'sent', 'failed', 'skipped')),
  provider_message_id text,
  created_at timestamptz not null default now(),
  unique (booking_id, kind, channel, send_at)
);

create index notifications_due_idx on notifications (send_at)
  where status = 'queued';

create table single_use_links (
  id uuid primary key default gen_random_uuid(),
  event_type_id uuid not null references event_types (id) on delete cascade,
  user_id uuid not null references profiles (id) on delete cascade,
  token_hash text not null unique,
  used_booking_id uuid references bookings (id) on delete set null,
  expires_at timestamptz,
  created_at timestamptz not null default now()
);

create index single_use_links_event_idx on single_use_links (event_type_id);

-- Stripe and calendar push notifications. event_id is the provider's id.
create table webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('stripe', 'google', 'microsoft')),
  event_id text not null,
  received_at timestamptz not null default now(),
  unique (provider, event_id)
);

-- Guest writes. security definer, so the function owner bypasses RLS.
-- The app still checks external calendar busy times before calling this,
-- inside the same request. The exclusion constraint closes the race against
-- another guest. A calendar event created in that gap is reconciled by the
-- calendar push job.

create or replace function book_slot(
  p_event_type_id uuid,
  p_start_at timestamptz,
  p_guest_name text,
  p_guest_email text,
  p_guest_time_zone text,
  p_answers jsonb,
  p_idempotency_key text,
  p_manage_token_hash text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  et event_types%rowtype;
  new_id uuid;
begin
  select * into et from event_types where id = p_event_type_id and active;
  if not found then
    raise exception 'event type is not bookable';
  end if;

  insert into bookings (
    event_type_id, host_id, start_at, end_at,
    blocked_start, blocked_end,
    guest_name, guest_email, guest_time_zone,
    status, answers, manage_token_hash, hold_expires_at, idempotency_key,
    price_cents, currency
  ) values (
    et.id,
    et.user_id,
    p_start_at,
    p_start_at + make_interval(mins => et.duration_min),
    p_start_at - make_interval(mins => et.buffer_before_min),
    p_start_at + make_interval(mins => et.duration_min + et.buffer_after_min),
    p_guest_name,
    lower(p_guest_email),
    p_guest_time_zone,
    case when et.price_cents is null then 'confirmed' else 'pending' end,
    coalesce(p_answers, '{}'),
    p_manage_token_hash,
    case when et.price_cents is null then null else now() + interval '30 minutes' end,
    p_idempotency_key,
    et.price_cents,
    et.currency
  )
  returning id into new_id;

  return new_id;
end;
$$;

create or replace function reschedule_slot(
  p_booking_id uuid,
  p_manage_token_hash text,
  p_new_start timestamptz,
  p_new_token_hash text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  old bookings%rowtype;
  et event_types%rowtype;
  new_id uuid;
begin
  select * into old from bookings where id = p_booking_id for update;
  if not found or old.manage_token_hash <> p_manage_token_hash or old.status <> 'confirmed' then
    raise exception 'booking cannot be rescheduled';
  end if;

  select * into et from event_types where id = old.event_type_id and active;
  if not found then
    raise exception 'event type is not bookable';
  end if;

  update bookings set status = 'rescheduled' where id = old.id;

  insert into bookings (
    event_type_id, host_id, start_at, end_at,
    blocked_start, blocked_end,
    guest_name, guest_email, guest_time_zone,
    status, answers, reschedule_of, manage_token_hash, idempotency_key,
    price_cents, currency
  ) values (
    et.id,
    et.user_id,
    p_new_start,
    p_new_start + make_interval(mins => et.duration_min),
    p_new_start - make_interval(mins => et.buffer_before_min),
    p_new_start + make_interval(mins => et.duration_min + et.buffer_after_min),
    old.guest_name,
    old.guest_email,
    old.guest_time_zone,
    'confirmed',
    old.answers,
    old.id,
    p_new_token_hash,
    p_idempotency_key,
    et.price_cents,
    et.currency
  )
  returning id into new_id;

  return new_id;
end;
$$;

create or replace function cancel_slot(
  p_booking_id uuid,
  p_manage_token_hash text,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  update bookings
    set status = 'cancelled', cancel_reason = nullif(p_reason, '')
    where id = p_booking_id
      and manage_token_hash = p_manage_token_hash
      and status = 'confirmed';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'booking cannot be cancelled';
  end if;
end;
$$;

-- Not granted to anon or authenticated. The Next.js server calls these
-- with the service role after it has checked hours, limits, and calendar busy
-- times (and the manage token, for guest changes). A browser cannot skip that.
revoke all on function book_slot(uuid, timestamptz, text, text, text, jsonb, text, text) from public;
revoke all on function reschedule_slot(uuid, text, timestamptz, text, text) from public;
revoke all on function cancel_slot(uuid, text, text) from public;

alter table profiles enable row level security;
alter table calendar_connections enable row level security;
alter table external_calendars enable row level security;
alter table schedules enable row level security;
alter table schedule_rules enable row level security;
alter table schedule_overrides enable row level security;
alter table event_types enable row level security;
alter table booking_questions enable row level security;
alter table bookings enable row level security;
alter table notifications enable row level security;
alter table single_use_links enable row level security;
alter table webhook_events enable row level security;

-- Hosts read and write their own rows. Anon has no policies, so no table access.
-- Public booking pages call the security definer functions above.

create policy profiles_own on profiles
  for all to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

create policy calendar_connections_own on calendar_connections
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy external_calendars_own on external_calendars
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy schedules_own on schedules
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy schedule_rules_own on schedule_rules
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy schedule_overrides_own on schedule_overrides
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy event_types_own on event_types
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Active event types are readable by anyone so the booking page can render.
-- They contain no guest data.
create policy event_types_public_read on event_types
  for select to anon, authenticated
  using (active = true);

create policy booking_questions_own on booking_questions
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy booking_questions_public_read on booking_questions
  for select to anon, authenticated
  using (
    exists (
      select 1 from event_types et
      where et.id = event_type_id and et.active
    )
  );

create policy bookings_host on bookings
  for select to authenticated
  using (host_id = auth.uid());

create policy notifications_host on notifications
  for select to authenticated
  using (host_id = auth.uid());

create policy single_use_links_own on single_use_links
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- webhook_events: no policies. Only the service role inserts them.
