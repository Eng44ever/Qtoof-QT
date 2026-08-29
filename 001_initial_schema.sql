-- Qtoof_QT_online
-- FINAL INITIAL DATABASE SCRIPT
-- All current SQL steps merged into ONE file, in execution order.
-- Negative wallet balances are intentionally allowed.

-- =========================================================
-- MERGED FROM: 001_initial_schema.sql
-- =========================================================
-- Qtoof_QT_online
-- Supabase / PostgreSQL
-- Migration: 001_initial_schema.sql
-- Schema only: no RLS, no financial RPCs, no Edge Functions yet.

create extension if not exists pgcrypto;

-- =========================================================
-- ENUMS
-- =========================================================

do $$ begin
  create type app_mode as enum ('TRIAL','PRODUCTION');
exception when duplicate_object then null; end $$;

do $$ begin
  create type user_status as enum ('ACTIVE','SUSPENDED','DELETED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type currency_code as enum ('Q','QT');
exception when duplicate_object then null; end $$;

do $$ begin
  create type competition_state as enum
    ('CREATED','WAITING','READY','STARTED','QUESTION_ACTIVE',
     'FINISHED','REWARDS','ARCHIVED','CANCELLED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type competition_player_status as enum
    ('INVITED','JOINED','ACTIVE','DISCONNECTED','FINISHED','CANCELLED','REFUNDED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type invitation_status as enum
    ('PENDING','ACCEPTED','DECLINED','EXPIRED','CANCELLED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type question_type as enum ('CHOICE','COMPLETE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type question_status as enum ('ACTIVE','INACTIVE','ARCHIVED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type transaction_status as enum
    ('PENDING','COMPLETED','FAILED','REVERSED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type ledger_entry_type as enum ('CREDIT','DEBIT');
exception when duplicate_object then null; end $$;

do $$ begin
  create type fee_type as enum ('ORGANIZER_FEE','PARTICIPANT_FEE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type reward_status as enum ('PENDING','GRANTED','CANCELLED','REFUNDED');
exception when duplicate_object then null; end $$;

do $$ begin
  create type invitation_type as enum ('GLOBAL','ONE_V_ONE','FRIENDS','OTHER');
exception when duplicate_object then null; end $$;

do $$ begin
  create type star_period_type as enum ('COMPETITION','DAY','WEEK','MONTH');
exception when duplicate_object then null; end $$;

do $$ begin
  create type azkar_record_status as enum ('PENDING','ACCEPTED','REJECTED');
exception when duplicate_object then null; end $$;

-- =========================================================
-- USERS / IDENTITY
-- =========================================================

create table if not exists users (
  id uuid primary key default gen_random_uuid(),
  telegram_id bigint unique,
  username text,
  display_name text,
  country_code varchar(2),
  status user_status not null default 'ACTIVE',
  mode app_mode not null default 'TRIAL',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz
);

create table if not exists user_profiles (
  user_id uuid primary key references users(id) on delete cascade,
  bio text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists user_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  device_id text not null,
  platform text,
  app_version text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique(user_id, device_id)
);

create table if not exists user_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  device_id uuid references user_devices(id) on delete set null,
  platform text,
  app_version text,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  last_activity_at timestamptz not null default now(),
  ip_hash text
);

-- =========================================================
-- WALLETS
-- =========================================================

create table if not exists wallet_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  currency currency_code not null,
  balance bigint not null default 0,
  protected_balance bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, currency),
  -- Negative Q/QT balances are intentional by design.
  check (protected_balance >= 0)
);

create table if not exists wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  transaction_id text not null unique,
  user_id uuid references users(id) on delete set null,
  status transaction_status not null default 'PENDING',
  transaction_type text not null,
  reference_type text,
  reference_id uuid,
  reason text,
  source text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  wallet_transaction_id uuid not null references wallet_transactions(id),
  user_id uuid not null references users(id) on delete restrict,
  currency currency_code not null,
  entry_type ledger_entry_type not null,
  amount bigint not null,
  balance_before bigint not null,
  balance_after bigint not null,
  competition_id uuid,
  reason text,
  source text,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  check (amount > 0)
  -- balance_before / balance_after intentionally allow negative values.
);

-- =========================================================
-- IDEMPOTENCY
-- =========================================================

create table if not exists idempotency_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  request_key text not null,
  operation text not null,
  response jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  unique(user_id, request_key, operation)
);

-- =========================================================
-- CATEGORIES / QUESTIONS
-- =========================================================

create table if not exists question_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  status text not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists questions (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references question_categories(id) on delete set null,
  question_type question_type not null,
  question_text text not null,
  answer_data jsonb not null default '{}'::jsonb,
  explanation text,
  status question_status not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================================================
-- COMPETITIONS
-- =========================================================

create table if not exists competitions (
  id uuid primary key default gen_random_uuid(),
  competition_code text not null unique,
  organizer_id uuid not null references users(id) on delete restrict,
  competition_type text not null,
  mode app_mode not null default 'TRIAL',
  state competition_state not null default 'CREATED',

  question_count integer not null,
  question_seconds integer not null,

  min_players integer not null default 2,
  max_players integer not null default 50,

  organizer_fee_qt bigint not null default 0,
  participant_fee_qt bigint not null default 1,

  invitation_seconds integer not null default 30,
  extension_seconds integer not null default 30,

  created_at timestamptz not null default now(),
  waiting_at timestamptz,
  ready_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  rewards_at timestamptz,
  archived_at timestamptz,
  cancelled_at timestamptz,

  cancelled_by uuid references users(id) on delete set null,
  cancellation_reason text,

  created_mode text,
  metadata jsonb not null default '{}'::jsonb,

  check (min_players >= 2),
  check (max_players >= min_players),
  check (question_count > 0),
  check (question_seconds > 0),
  check (organizer_fee_qt >= 0),
  check (participant_fee_qt >= 0),
  check (invitation_seconds > 0),
  check (extension_seconds > 0)
);

-- Immutable rules snapshot for this competition.
create table if not exists competition_config_snapshots (
  competition_id uuid primary key references competitions(id) on delete cascade,
  config jsonb not null,
  captured_at timestamptz not null default now()
);

create table if not exists competition_categories (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  category_id uuid not null references question_categories(id) on delete restrict,
  category_order integer not null,
  created_at timestamptz not null default now(),
  unique(competition_id, category_id),
  unique(competition_id, category_order)
);

-- =========================================================
-- INVITATIONS / PLAYERS
-- =========================================================

create table if not exists competition_invitations (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  sender_id uuid not null references users(id) on delete restrict,
  receiver_id uuid not null references users(id) on delete restrict,
  invitation_type invitation_type not null,
  status invitation_status not null default 'PENDING',
  sent_at timestamptz not null default now(),
  expires_at timestamptz not null,
  responded_at timestamptz,
  accepted_at timestamptz,
  declined_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists competition_players (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  user_id uuid not null references users(id) on delete restrict,
  status competition_player_status not null default 'INVITED',

  joined_at timestamptz,
  disconnected_at timestamptz,
  reconnected_at timestamptz,
  left_at timestamptz,

  final_score bigint not null default 0,
  final_rank integer,

  correct_answers integer not null default 0,
  wrong_answers integer not null default 0,
  total_answered integer not null default 0,
  total_response_ms bigint not null default 0,
  average_response_ms numeric(14,3),
  fastest_response_ms bigint,
  qualification_percent numeric(7,3),

  entry_fee_qt bigint not null default 0,
  entry_fee_status text,
  reward_qt bigint not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique(competition_id, user_id),
  check (final_score >= 0),
  check (correct_answers >= 0),
  check (wrong_answers >= 0),
  check (total_answered >= 0),
  check (total_response_ms >= 0),
  check (entry_fee_qt >= 0),
  check (reward_qt >= 0)
);

-- =========================================================
-- COMPETITION QUESTIONS / ANSWERS
-- =========================================================

create table if not exists competition_questions (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  question_id uuid not null references questions(id) on delete restrict,
  question_order integer not null,
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  unique(competition_id, question_order)
);

create table if not exists answer_attempts (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  competition_question_id uuid not null references competition_questions(id) on delete cascade,
  user_id uuid not null references users(id) on delete restrict,

  attempt_number integer not null,
  answer_value text not null,

  server_received_at timestamptz not null default now(),
  response_ms bigint not null,

  is_correct boolean not null,

  created_at timestamptz not null default now(),

  unique(competition_question_id, user_id, attempt_number),
  check (attempt_number > 0),
  check (response_ms >= 0)
);

create table if not exists answers (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null unique references answer_attempts(id) on delete restrict,
  competition_id uuid not null references competitions(id) on delete cascade,
  competition_question_id uuid not null references competition_questions(id) on delete cascade,
  user_id uuid not null references users(id) on delete restrict,

  server_received_at timestamptz not null,
  response_ms bigint not null,
  is_correct boolean not null,
  points integer not null default 0,
  rank_for_question integer,

  created_at timestamptz not null default now(),

  check (response_ms >= 0),
  check (points >= 0)
);

create table if not exists competition_score_events (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  competition_question_id uuid references competition_questions(id) on delete set null,
  user_id uuid not null references users(id) on delete restrict,
  points integer not null,
  reason text not null,
  rank_for_question integer,
  created_at timestamptz not null default now(),
  check (points >= 0)
);

-- =========================================================
-- EVENTS / CHAT
-- =========================================================

create table if not exists competition_events (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  user_id uuid references users(id) on delete set null,
  event_type text not null,
  competition_question_id uuid references competition_questions(id) on delete set null,
  sequence_number bigint,
  server_timestamp timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists competition_messages (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  user_id uuid not null references users(id) on delete restrict,
  message text not null,
  server_timestamp timestamptz not null default now(),
  message_type text not null default 'TEXT',
  created_at timestamptz not null default now()
);

create table if not exists system_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete set null,
  event_type text not null,
  server_timestamp timestamptz not null default now(),
  app_version text,
  metadata jsonb not null default '{}'::jsonb
);

-- =========================================================
-- FEES / PRIZE POOL / REWARDS / SUPPORT
-- =========================================================

create table if not exists competition_fees (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  user_id uuid references users(id) on delete set null,
  fee_type fee_type not null,
  amount_qt bigint not null,
  status transaction_status not null default 'PENDING',
  ledger_id uuid references wallet_ledger(id) on delete set null,
  created_at timestamptz not null default now(),
  check (amount_qt >= 0)
);

create table if not exists competition_prize_pools (
  competition_id uuid primary key references competitions(id) on delete cascade,
  participant_qt bigint not null default 0,
  developer_support_qt bigint not null default 0,
  total_pool_qt bigint not null default 0,
  first_award_qt bigint not null default 0,
  second_award_qt bigint not null default 0,
  third_award_qt bigint not null default 0,
  future_rewards_qt bigint not null default 0,
  distributed_qt bigint not null default 0,
  remaining_qt bigint not null default 0,
  updated_at timestamptz not null default now(),
  check (participant_qt >= 0),
  check (developer_support_qt >= 0),
  check (total_pool_qt >= 0),
  check (distributed_qt >= 0),
  check (remaining_qt >= 0)
);

create table if not exists competition_rewards (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  user_id uuid not null references users(id) on delete restrict,
  rank integer,
  qualification_percent numeric(7,3),
  base_percent numeric(7,3),
  multiplier numeric(10,4) not null default 1,
  amount_qt bigint not null,
  status reward_status not null default 'PENDING',
  ledger_id uuid references wallet_ledger(id) on delete set null,
  created_at timestamptz not null default now(),
  granted_at timestamptz,
  check (amount_qt >= 0)
);

create table if not exists developer_support (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  developer_id uuid not null references users(id) on delete restrict,
  amount_qt bigint not null,
  ledger_id uuid references wallet_ledger(id) on delete set null,
  created_at timestamptz not null default now(),
  reason text,
  check (amount_qt > 0)
);

create table if not exists competition_fee_exemptions (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  user_id uuid not null references users(id) on delete restrict,
  fee_type fee_type not null,
  reason text,
  created_by uuid references users(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique(competition_id, user_id, fee_type)
);

-- =========================================================
-- STARS / RANKINGS / ANALYTICS
-- =========================================================

create table if not exists competition_stars (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references competitions(id) on delete cascade,
  user_id uuid not null references users(id) on delete restrict,
  correct_percent numeric(7,3),
  average_correct_response_ms numeric(14,3),
  selection_rule jsonb not null default '{}'::jsonb,
  rank_value numeric(20,6),
  reward_type text,
  reward_amount numeric(20,3),
  created_at timestamptz not null default now(),
  unique(competition_id)
);

create table if not exists period_stars (
  id uuid primary key default gen_random_uuid(),
  period_type star_period_type not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  user_id uuid not null references users(id) on delete restrict,
  metric text not null,
  metric_value numeric(20,6) not null,
  reward_type text,
  reward_amount numeric(20,3),
  created_at timestamptz not null default now(),
  unique(period_type, period_start, period_end)
);

create table if not exists user_stats (
  user_id uuid primary key references users(id) on delete cascade,
  competitions_joined bigint not null default 0,
  competitions_finished bigint not null default 0,
  competitions_won bigint not null default 0,
  questions_answered bigint not null default 0,
  questions_correct bigint not null default 0,
  total_points bigint not null default 0,
  average_response_ms numeric(14,3),
  fastest_response_ms bigint,
  best_rank integer,
  win_streak integer not null default 0,
  best_win_streak integer not null default 0,
  qt_spent bigint not null default 0,
  qt_earned bigint not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists question_stats (
  question_id uuid primary key references questions(id) on delete cascade,
  times_used bigint not null default 0,
  times_answered bigint not null default 0,
  correct_count bigint not null default 0,
  wrong_count bigint not null default 0,
  attempt_count bigint not null default 0,
  average_response_ms numeric(14,3),
  fastest_response_ms bigint,
  updated_at timestamptz not null default now()
);

create table if not exists category_stats (
  category_id uuid primary key references question_categories(id) on delete cascade,
  competitions_count bigint not null default 0,
  questions_count bigint not null default 0,
  answers_count bigint not null default 0,
  correct_answers bigint not null default 0,
  average_score numeric(14,3),
  average_response_ms numeric(14,3),
  updated_at timestamptz not null default now()
);

create table if not exists daily_stats (
  stat_date date primary key,
  active_users bigint not null default 0,
  new_users bigint not null default 0,
  competitions_created bigint not null default 0,
  competitions_started bigint not null default 0,
  competitions_finished bigint not null default 0,
  competitions_cancelled bigint not null default 0,
  answers bigint not null default 0,
  correct_answers bigint not null default 0,
  qt_spent bigint not null default 0,
  qt_earned bigint not null default 0,
  qt_distributed bigint not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists player_rankings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  ranking_type text not null,
  category_id uuid references question_categories(id) on delete set null,
  rating numeric(20,6) not null default 0,
  rank integer,
  wins bigint not null default 0,
  losses bigint not null default 0,
  games bigint not null default 0,
  period_start timestamptz,
  period_end timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists player_streaks (
  user_id uuid not null references users(id) on delete cascade,
  streak_type text not null,
  current_value bigint not null default 0,
  best_value bigint not null default 0,
  started_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key(user_id, streak_type)
);

-- =========================================================
-- AZKAR
-- =========================================================

create table if not exists azkar_reward_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete restrict,
  azkar_type text not null,
  period_key text not null,
  started_at timestamptz,
  completed_at timestamptz,
  duration_seconds integer,
  status azkar_record_status not null default 'PENDING',
  reward_q bigint not null default 0,
  reward_qt bigint not null default 0,
  created_at timestamptz not null default now(),
  synced_at timestamptz,
  unique(user_id, azkar_type, period_key),
  check (duration_seconds is null or duration_seconds >= 0),
  check (reward_q >= 0),
  check (reward_qt >= 0)
);

-- =========================================================
-- DEVELOPER CONFIG / HISTORY / AUDIT
-- =========================================================

create table if not exists system_configs (
  id uuid primary key default gen_random_uuid(),
  config_key text not null unique,
  config_value jsonb not null,
  value_type text not null,
  category text,
  updated_by uuid references users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists config_history (
  id uuid primary key default gen_random_uuid(),
  config_key text not null,
  old_value jsonb,
  new_value jsonb not null,
  changed_by uuid references users(id) on delete set null,
  changed_at timestamptz not null default now(),
  reason text
);

create table if not exists admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid references users(id) on delete set null,
  action text not null,
  target_type text,
  target_id uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

-- =========================================================
-- INDEXES
-- =========================================================

create index if not exists idx_users_country on users(country_code);
create index if not exists idx_users_last_seen on users(last_seen_at);

create index if not exists idx_user_devices_device on user_devices(device_id);
create index if not exists idx_user_sessions_user_started on user_sessions(user_id, started_at desc);

create index if not exists idx_wallet_ledger_user_time
  on wallet_ledger(user_id, created_at desc);
create index if not exists idx_wallet_ledger_competition
  on wallet_ledger(competition_id, created_at desc);
create index if not exists idx_wallet_transactions_user_time
  on wallet_transactions(user_id, created_at desc);

create index if not exists idx_competitions_organizer on competitions(organizer_id);
create index if not exists idx_competitions_state on competitions(state);
create index if not exists idx_competitions_created on competitions(created_at desc);

create index if not exists idx_invitations_receiver_status
  on competition_invitations(receiver_id, status);
create index if not exists idx_invitations_competition
  on competition_invitations(competition_id);

create index if not exists idx_competition_players_user
  on competition_players(user_id);
create index if not exists idx_competition_players_competition
  on competition_players(competition_id);

create index if not exists idx_competition_questions_competition_order
  on competition_questions(competition_id, question_order);

create index if not exists idx_attempts_user_question
  on answer_attempts(user_id, competition_question_id);
create index if not exists idx_attempts_server_time
  on answer_attempts(server_received_at);

create index if not exists idx_answers_competition_user
  on answers(competition_id, user_id);
create index if not exists idx_answers_question_time
  on answers(competition_question_id, server_received_at);

create index if not exists idx_score_events_competition_user
  on competition_score_events(competition_id, user_id);

create index if not exists idx_competition_events_competition_sequence
  on competition_events(competition_id, sequence_number);
create index if not exists idx_competition_events_competition_time
  on competition_events(competition_id, server_timestamp);
create index if not exists idx_system_events_user_time
  on system_events(user_id, server_timestamp);

create index if not exists idx_messages_competition_time
  on competition_messages(competition_id, server_timestamp);

create index if not exists idx_rewards_user
  on competition_rewards(user_id, created_at desc);

create index if not exists idx_rankings_type_rank
  on player_rankings(ranking_type, rank);

create index if not exists idx_config_history_key_time
  on config_history(config_key, changed_at desc);

create index if not exists idx_audit_target
  on admin_audit_log(target_type, target_id, created_at desc);

-- JSONB indexes where flexible event/config lookup may be useful.
create index if not exists idx_competition_events_metadata
  on competition_events using gin(metadata);

create index if not exists idx_system_events_metadata
  on system_events using gin(metadata);

-- =========================================================
-- NOTES
-- =========================================================
-- 1) No RLS is defined in this migration.
-- 2) No wallet-changing operation is exposed here.
-- 3) Financial mutations, invitation acceptance, competition-state
--    transitions, reward distribution, refunds and Q->QT conversion
--    must be implemented as server-side transactional functions.
-- 4) No manual difficulty field is included.
-- 5) No business rule for tie-breaking or exceptional rewards is
--    hard-coded here.

-- =========================================================
-- MERGED FROM: 003_wallet_ledger_competition_fk.sql
-- =========================================================
-- Qtoof_QT_online
-- Supabase / PostgreSQL
-- Migration: 003_wallet_ledger_competition_fk.sql
-- Purpose: link wallet ledger entries to competitions safely.
--
-- This migration adds only the missing foreign-key integrity
-- between wallet_ledger.competition_id and competitions.id.
-- No business rules, balances, fees, rewards, RLS, or RPCs are changed.

BEGIN;

ALTER TABLE wallet_ledger
  ADD CONSTRAINT wallet_ledger_competition_id_fkey
  FOREIGN KEY (competition_id)
  REFERENCES competitions(id)
  ON DELETE SET NULL;

COMMIT;

-- =========================================================
-- MERGED FROM: 004_prevent_active_competition_overlap.sql
-- =========================================================
-- Qtoof_QT_online
-- Supabase / PostgreSQL
-- Migration: 004_prevent_active_competition_overlap.sql
-- Purpose: prevent a player from being joined to more than one
-- active competition at the same time.
--
-- Pending invitations are intentionally NOT included because the
-- approved design allows a user to receive multiple invitations.
-- The server remains responsible for the atomic acceptance operation.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS uq_competition_players_one_active_competition
  ON competition_players(user_id)
  WHERE status IN ('JOINED', 'ACTIVE', 'DISCONNECTED');

COMMIT;

-- =========================================================
-- MERGED FROM: 005_auto_update_timestamps.sql
-- =========================================================
-- Qtoof_QT_online
-- Supabase / PostgreSQL
-- Migration: 005_auto_update_timestamps.sql
-- Purpose: keep updated_at columns synchronized automatically.
--
-- This migration adds only the generic timestamp trigger.
-- No competition rules, wallet rules, rewards, RLS, or RPCs are changed.

BEGIN;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_updated_at ON users;
CREATE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_user_profiles_updated_at ON user_profiles;
CREATE TRIGGER trg_user_profiles_updated_at
BEFORE UPDATE ON user_profiles
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_wallet_accounts_updated_at ON wallet_accounts;
CREATE TRIGGER trg_wallet_accounts_updated_at
BEFORE UPDATE ON wallet_accounts
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_questions_updated_at ON questions;
CREATE TRIGGER trg_questions_updated_at
BEFORE UPDATE ON questions
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_question_categories_updated_at ON question_categories;
CREATE TRIGGER trg_question_categories_updated_at
BEFORE UPDATE ON question_categories
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_competition_players_updated_at ON competition_players;
CREATE TRIGGER trg_competition_players_updated_at
BEFORE UPDATE ON competition_players
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_competition_prize_pools_updated_at ON competition_prize_pools;
CREATE TRIGGER trg_competition_prize_pools_updated_at
BEFORE UPDATE ON competition_prize_pools
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_user_stats_updated_at ON user_stats;
CREATE TRIGGER trg_user_stats_updated_at
BEFORE UPDATE ON user_stats
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_question_stats_updated_at ON question_stats;
CREATE TRIGGER trg_question_stats_updated_at
BEFORE UPDATE ON question_stats
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_category_stats_updated_at ON category_stats;
CREATE TRIGGER trg_category_stats_updated_at
BEFORE UPDATE ON category_stats
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_daily_stats_updated_at ON daily_stats;
CREATE TRIGGER trg_daily_stats_updated_at
BEFORE UPDATE ON daily_stats
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_player_rankings_updated_at ON player_rankings;
CREATE TRIGGER trg_player_rankings_updated_at
BEFORE UPDATE ON player_rankings
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_player_streaks_updated_at ON player_streaks;
CREATE TRIGGER trg_player_streaks_updated_at
BEFORE UPDATE ON player_streaks
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

DROP TRIGGER IF EXISTS trg_system_configs_updated_at ON system_configs;
CREATE TRIGGER trg_system_configs_updated_at
BEFORE UPDATE ON system_configs
FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

COMMIT;

-- =========================================================
-- MERGED FROM: 006_unique_competition_invitation_receiver.sql
-- =========================================================
-- Qtoof_QT_online
-- Supabase / PostgreSQL
-- Migration: 006_unique_competition_invitation_receiver.sql
-- Purpose: prevent duplicate invitations for the same user in the
-- same competition while still allowing invitations from multiple
-- competitions at the same time.
--
-- No business rule, wallet rule, reward rule, RLS, or RPC is changed.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS uq_competition_invitation_receiver
  ON competition_invitations(competition_id, receiver_id);

COMMIT;

-- =========================================================
-- MERGED FROM: 007_wallet_atomic_transaction.sql
-- =========================================================
-- Qtoof_QT_online
-- Supabase / PostgreSQL
-- Migration: 007_wallet_atomic_transaction.sql
-- Purpose: atomic server-side wallet movement with idempotency.
--
-- This migration:
-- 1) locks the wallet row before changing its balance;
-- 2) allows balances to become negative by design;
-- 3) records every movement in wallet_transactions + wallet_ledger;
-- 4) makes transaction_id idempotent;
-- 5) does not change protected_balance;
-- 6) does not expose the function to client roles.

BEGIN;

CREATE OR REPLACE FUNCTION apply_wallet_transaction(
  p_transaction_id text,
  p_user_id uuid,
  p_currency currency_code,
  p_entry_type ledger_entry_type,
  p_amount bigint,
  p_transaction_type text,
  p_reference_type text DEFAULT NULL,
  p_reference_id uuid DEFAULT NULL,
  p_competition_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_source text DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  transaction_uuid uuid,
  ledger_uuid uuid,
  balance_before bigint,
  balance_after bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id uuid;
  v_transaction_uuid uuid;
  v_ledger_uuid uuid;
  v_before bigint;
  v_after bigint;
  v_existing_status transaction_status;
BEGIN
  IF p_transaction_id IS NULL OR btrim(p_transaction_id) = '' THEN
    RAISE EXCEPTION 'transaction_id is required';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id is required';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be greater than zero';
  END IF;

  IF p_transaction_type IS NULL OR btrim(p_transaction_type) = '' THEN
    RAISE EXCEPTION 'transaction_type is required';
  END IF;

  -- Idempotency: an already completed transaction is returned as-is.
  SELECT id, status
    INTO v_transaction_uuid, v_existing_status
  FROM wallet_transactions
  WHERE transaction_id = p_transaction_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing_status = 'COMPLETED' THEN
      SELECT wl.id, wl.balance_before, wl.balance_after
        INTO v_ledger_uuid, v_before, v_after
      FROM wallet_ledger wl
      WHERE wl.wallet_transaction_id = v_transaction_uuid
      ORDER BY wl.created_at
      LIMIT 1;

      RETURN QUERY
      SELECT v_transaction_uuid, v_ledger_uuid, v_before, v_after;
      RETURN;
    END IF;

    RAISE EXCEPTION 'transaction_id already exists with status %',
      v_existing_status;
  END IF;

  -- One wallet row per user/currency.
  SELECT wa.id, wa.balance
    INTO v_wallet_id, v_before
  FROM wallet_accounts wa
  WHERE wa.user_id = p_user_id
    AND wa.currency = p_currency
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'wallet account not found';
  END IF;

  -- Negative balances are intentional.
  IF p_entry_type = 'CREDIT' THEN
    v_after := v_before + p_amount;
  ELSE
    v_after := v_before - p_amount;
  END IF;

  INSERT INTO wallet_transactions (
    transaction_id,
    user_id,
    status,
    transaction_type,
    reference_type,
    reference_id,
    reason,
    source,
    metadata
  )
  VALUES (
    p_transaction_id,
    p_user_id,
    'PENDING',
    p_transaction_type,
    p_reference_type,
    p_reference_id,
    p_reason,
    p_source,
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_transaction_uuid;

  UPDATE wallet_accounts
  SET balance = v_after
  WHERE id = v_wallet_id;

  INSERT INTO wallet_ledger (
    wallet_transaction_id,
    user_id,
    currency,
    entry_type,
    amount,
    balance_before,
    balance_after,
    competition_id,
    reason,
    source,
    metadata
  )
  VALUES (
    v_transaction_uuid,
    p_user_id,
    p_currency,
    p_entry_type,
    p_amount,
    v_before,
    v_after,
    p_competition_id,
    p_reason,
    p_source,
    COALESCE(p_metadata, '{}'::jsonb)
  )
  RETURNING id INTO v_ledger_uuid;

  UPDATE wallet_transactions
  SET status = 'COMPLETED',
      completed_at = now()
  WHERE id = v_transaction_uuid;

  RETURN QUERY
  SELECT v_transaction_uuid, v_ledger_uuid, v_before, v_after;
END;
$$;

-- Client applications must not be able to call the financial primitive directly.
REVOKE ALL ON FUNCTION apply_wallet_transaction(
  text, uuid, currency_code, ledger_entry_type, bigint, text,
  text, uuid, uuid, text, text, jsonb
) FROM PUBLIC, anon, authenticated;

-- The server-side service role may call it.
GRANT EXECUTE ON FUNCTION apply_wallet_transaction(
  text, uuid, currency_code, ledger_entry_type, bigint, text,
  text, uuid, uuid, text, text, jsonb
) TO service_role;

COMMIT;

-- =========================================================
-- MERGED FROM: 008_accept_competition_invitation.sql
-- =========================================================
-- Qtoof_QT_online
-- Supabase / PostgreSQL
-- Migration: 008_accept_competition_invitation.sql
-- Purpose: atomic invitation acceptance + participant fee + player reservation.
--
-- This migration:
-- 1) serializes acceptance per user;
-- 2) validates the invitation and competition state;
-- 3) prevents joining another active competition;
-- 4) enforces the competition player limit atomically;
-- 5) charges the participant fee through the server wallet primitive;
-- 6) respects a participant-fee exemption;
-- 7) creates the player record atomically with the payment;
-- 8) cancels the user's other pending invitations after successful acceptance.

BEGIN;

CREATE OR REPLACE FUNCTION accept_competition_invitation(
  p_invitation_id uuid,
  p_user_id uuid,
  p_transaction_id text DEFAULT NULL
)
RETURNS TABLE (
  competition_id uuid,
  player_id uuid,
  charged_qt bigint,
  new_balance bigint,
  competition_state competition_state
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_invitation competition_invitations%ROWTYPE;
  v_competition competitions%ROWTYPE;
  v_player_id uuid;
  v_fee bigint;
  v_transaction_id text;
  v_balance bigint;
  v_count integer;
  v_wallet_tx uuid;
  v_ledger uuid;
BEGIN
  IF p_invitation_id IS NULL THEN
    RAISE EXCEPTION 'invitation_id is required';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'user_id is required';
  END IF;

  -- Serialize all competition-acceptance attempts by this user.
  PERFORM pg_advisory_xact_lock(
    hashtextextended('competition_accept:' || p_user_id::text, 0)
  );

  -- Lock the invitation first so two requests cannot accept it together.
  SELECT *
    INTO v_invitation
  FROM competition_invitations
  WHERE id = p_invitation_id
    AND receiver_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'invitation not found';
  END IF;

  IF v_invitation.status <> 'PENDING' THEN
    RAISE EXCEPTION 'invitation is not pending';
  END IF;

  IF v_invitation.expires_at <= now() THEN
    UPDATE competition_invitations
    SET status = 'EXPIRED',
        responded_at = now()
    WHERE id = v_invitation.id;

    RAISE EXCEPTION 'invitation expired';
  END IF;

  -- Lock the competition so player-count/state checks are atomic.
  SELECT *
    INTO v_competition
  FROM competitions
  WHERE id = v_invitation.competition_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'competition not found';
  END IF;

  IF v_competition.state <> 'WAITING' THEN
    RAISE EXCEPTION 'competition is not accepting players';
  END IF;

  -- A user may participate in only one active competition at a time.
  IF EXISTS (
    SELECT 1
    FROM competition_players cp
    JOIN competitions c ON c.id = cp.competition_id
    WHERE cp.user_id = p_user_id
      AND cp.status IN ('JOINED','ACTIVE','DISCONNECTED')
      AND c.state IN ('WAITING','READY','STARTED','QUESTION_ACTIVE')
      AND c.id <> v_competition.id
  ) THEN
    RAISE EXCEPTION 'user is already participating in another competition';
  END IF;

  -- Count reserved/active participants. INVITED alone does not consume a seat.
  SELECT count(*)::integer
    INTO v_count
  FROM competition_players
  WHERE competition_id = v_competition.id
    AND status IN ('JOINED','ACTIVE','DISCONNECTED','FINISHED');

  IF v_count >= v_competition.max_players THEN
    RAISE EXCEPTION 'competition is full';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM competition_players
    WHERE competition_id = v_competition.id
      AND user_id = p_user_id
      AND status NOT IN ('CANCELLED','REFUNDED')
  ) THEN
    RAISE EXCEPTION 'user is already in this competition';
  END IF;

  -- Fee is taken from the competition snapshot stored on the competition.
  -- An explicit exemption changes the participant fee to zero.
  IF EXISTS (
    SELECT 1
    FROM competition_fee_exemptions
    WHERE competition_id = v_competition.id
      AND user_id = p_user_id
      AND fee_type = 'PARTICIPANT_FEE'
  ) THEN
    v_fee := 0;
  ELSE
    v_fee := v_competition.participant_fee_qt;
  END IF;

  IF v_fee < 0 THEN
    RAISE EXCEPTION 'invalid participant fee';
  END IF;

  v_transaction_id := COALESCE(
    NULLIF(btrim(p_transaction_id), ''),
    'competition-entry:' || v_competition.id::text || ':' || p_user_id::text
  );

  -- Payment and player reservation are in this same database transaction.
  IF v_fee > 0 THEN
    SELECT transaction_uuid, ledger_uuid, balance_after
      INTO v_wallet_tx, v_ledger, v_balance
    FROM apply_wallet_transaction(
      v_transaction_id,
      p_user_id,
      'QT',
      'DEBIT',
      v_fee,
      'PARTICIPANT_FEE',
      'COMPETITION',
      v_competition.id,
      v_competition.id,
      'Competition entry fee',
      'competition_accept',
      jsonb_build_object(
        'invitation_id', v_invitation.id,
        'competition_code', v_competition.competition_code
      )
    );
  ELSE
    SELECT balance
      INTO v_balance
    FROM wallet_accounts
    WHERE user_id = p_user_id
      AND currency = 'QT';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'QT wallet account not found';
    END IF;
  END IF;

  INSERT INTO competition_players (
    competition_id,
    user_id,
    status,
    joined_at,
    entry_fee_qt,
    entry_fee_status
  )
  VALUES (
    v_competition.id,
    p_user_id,
    'JOINED',
    now(),
    v_fee,
    CASE WHEN v_fee = 0 THEN 'EXEMPT' ELSE 'PAID' END
  )
  RETURNING id INTO v_player_id;

  INSERT INTO competition_fees (
    competition_id,
    user_id,
    fee_type,
    amount_qt,
    status,
    ledger_id
  )
  VALUES (
    v_competition.id,
    p_user_id,
    'PARTICIPANT_FEE',
    v_fee,
    'COMPLETED',
    v_ledger
  );

  UPDATE competition_invitations
  SET status = 'ACCEPTED',
      responded_at = now(),
      accepted_at = now()
  WHERE id = v_invitation.id;

  -- Once the user accepts one competition, close all other pending invites.
  UPDATE competition_invitations
  SET status = 'CANCELLED',
      cancelled_at = now(),
      responded_at = now()
  WHERE receiver_id = p_user_id
    AND status = 'PENDING'
    AND id <> v_invitation.id;

  -- Minimum player count reached: competition is ready.
  SELECT count(*)::integer
    INTO v_count
  FROM competition_players
  WHERE competition_id = v_competition.id
    AND status IN ('JOINED','ACTIVE','DISCONNECTED','FINISHED');

  IF v_count >= v_competition.min_players THEN
    UPDATE competitions
    SET state = 'READY',
        ready_at = COALESCE(ready_at, now()),
        updated_at = now()
    WHERE id = v_competition.id;

    v_competition.state := 'READY';
  END IF;

  RETURN QUERY
  SELECT
    v_competition.id,
    v_player_id,
    v_fee,
    v_balance,
    v_competition.state;
END;
$$;

REVOKE ALL ON FUNCTION accept_competition_invitation(uuid, uuid, text)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION accept_competition_invitation(uuid, uuid, text)
TO service_role;

COMMIT;
