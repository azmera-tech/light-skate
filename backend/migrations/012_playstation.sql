-- 012: PlayStation gaming module. Consoles, admin-configured packages, gaming sessions with priced line items,
-- their own payments/refunds (gaming sessions have no skating visit), and an append-only event history.

CREATE TABLE ps_consoles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id      uuid NOT NULL REFERENCES venues(id),
  code          text NOT NULL,                 -- e.g. PS-01; unique per venue
  name          text NOT NULL,
  model         text,
  location      text,
  -- Operational status set by an admin. "In use"/"available" are derived from live sessions, never stored.
  status        text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','MAINTENANCE','INACTIVE')),
  notes         text,
  archived_at   timestamptz,                    -- soft delete: history is kept
  created_by    uuid REFERENCES users(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (venue_id, code)
);

CREATE TABLE ps_packages (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id          uuid NOT NULL REFERENCES venues(id),
  name              text NOT NULL,
  description       text,
  pricing_type      text NOT NULL CHECK (pricing_type IN ('DURATION','PER_GAME')),
  duration_minutes  integer CHECK (duration_minutes > 0),
  games_per_unit    integer CHECK (games_per_unit > 0),   -- how many games one unit of this package buys
  game_label        text,                                 -- what "a game" means here, e.g. "FIFA match"
  price_minor       bigint NOT NULL CHECK (price_minor > 0),
  currency          text NOT NULL DEFAULT 'ETB',
  active            boolean NOT NULL DEFAULT true,
  sort_order        integer NOT NULL DEFAULT 0,
  archived_at       timestamptz,
  created_by        uuid REFERENCES users(id),
  updated_by        uuid REFERENCES users(id),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK ((pricing_type = 'DURATION' AND duration_minutes IS NOT NULL AND games_per_unit IS NULL)
      OR (pricing_type = 'PER_GAME' AND games_per_unit IS NOT NULL AND duration_minutes IS NULL)),
  CHECK (archived_at IS NULL OR active = false)
);
CREATE INDEX ps_packages_venue_idx ON ps_packages (venue_id, active, sort_order);

CREATE TABLE ps_sessions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id              uuid NOT NULL REFERENCES venues(id),
  session_number        text NOT NULL,
  console_id            uuid NOT NULL REFERENCES ps_consoles(id),
  customer_id           uuid REFERENCES customers(id),
  walk_in_name          text,
  walk_in_phone         text,
  pricing_type          text NOT NULL CHECK (pricing_type IN ('DURATION','PER_GAME')),
  status                text NOT NULL CHECK (status IN ('PENDING_PAYMENT','READY','ACTIVE','PAUSED','COMPLETED','CANCELLED')),
  payment_status        text NOT NULL DEFAULT 'UNPAID' CHECK (payment_status IN ('UNPAID','PENDING','PARTIALLY_PAID','PAID','PARTIALLY_REFUNDED','REFUNDED')),
  total_minor           bigint NOT NULL DEFAULT 0 CHECK (total_minor >= 0),   -- sum of line items (prices as agreed at purchase)
  currency              text NOT NULL DEFAULT 'ETB',
  purchased_seconds     integer NOT NULL DEFAULT 0 CHECK (purchased_seconds >= 0),
  games_purchased       integer NOT NULL DEFAULT 0 CHECK (games_purchased >= 0),
  games_completed       integer NOT NULL DEFAULT 0 CHECK (games_completed >= 0),
  started_at            timestamptz,
  expected_end_at       timestamptz,       -- timed sessions only; moves out by pause time and extensions
  ended_at              timestamptz,
  paused_at             timestamptz,
  total_paused_seconds  integer NOT NULL DEFAULT 0,
  operator_id           uuid REFERENCES users(id),   -- employee who opened the session
  started_by            uuid REFERENCES users(id),
  ended_by              uuid REFERENCES users(id),
  notes                 text,
  end_reason            text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  version               integer NOT NULL DEFAULT 1,
  UNIQUE (venue_id, session_number),
  CHECK (games_completed <= games_purchased),
  CHECK (customer_id IS NOT NULL OR walk_in_name IS NOT NULL)
);
-- A console can never be held by two open gaming sessions, whatever the application does.
CREATE UNIQUE INDEX ps_sessions_one_per_console ON ps_sessions (console_id) WHERE status IN ('PENDING_PAYMENT','READY','ACTIVE','PAUSED');
CREATE INDEX ps_sessions_venue_time_idx ON ps_sessions (venue_id, created_at DESC);
CREATE INDEX ps_sessions_live_idx ON ps_sessions (venue_id, status, expected_end_at);

-- What was sold: the initial package and every extension, each with the price agreed at that moment.
CREATE TABLE ps_session_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id          uuid NOT NULL REFERENCES venues(id),
  ps_session_id     uuid NOT NULL REFERENCES ps_sessions(id),
  kind              text NOT NULL CHECK (kind IN ('INITIAL','EXTENSION')),
  package_id        uuid NOT NULL REFERENCES ps_packages(id),
  package_name      text NOT NULL,
  pricing_type      text NOT NULL CHECK (pricing_type IN ('DURATION','PER_GAME')),
  unit_price_minor  bigint NOT NULL CHECK (unit_price_minor > 0),
  quantity          integer NOT NULL CHECK (quantity BETWEEN 1 AND 50),
  added_seconds     integer NOT NULL DEFAULT 0 CHECK (added_seconds >= 0),
  added_games       integer NOT NULL DEFAULT 0 CHECK (added_games >= 0),
  total_minor       bigint NOT NULL CHECK (total_minor = unit_price_minor * quantity),
  added_by          uuid REFERENCES users(id),
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ps_session_items_session_idx ON ps_session_items (ps_session_id);
CREATE INDEX ps_session_items_package_idx ON ps_session_items (package_id);

CREATE TABLE ps_payments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id          uuid NOT NULL REFERENCES venues(id),
  ps_session_id     uuid NOT NULL REFERENCES ps_sessions(id),
  item_id           uuid REFERENCES ps_session_items(id),
  amount_minor      bigint NOT NULL CHECK (amount_minor > 0),
  currency          text NOT NULL DEFAULT 'ETB',
  method            text NOT NULL,
  reference         text,
  status            text NOT NULL CHECK (status IN ('PENDING','PAID','CANCELLED','FAILED','PARTIALLY_REFUNDED','REFUNDED')),
  refunded_minor    bigint NOT NULL DEFAULT 0 CHECK (refunded_minor >= 0),
  recorded_by       uuid REFERENCES users(id),
  confirmed_by      uuid REFERENCES users(id),
  paid_at           timestamptz,       -- when the money was actually received/confirmed (revenue date)
  note              text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CHECK (refunded_minor <= amount_minor),
  CHECK (status NOT IN ('PAID','PARTIALLY_REFUNDED','REFUNDED') OR paid_at IS NOT NULL)
);
CREATE INDEX ps_payments_session_idx ON ps_payments (ps_session_id);
CREATE INDEX ps_payments_paid_idx ON ps_payments (venue_id, paid_at);

CREATE TABLE ps_refunds (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  payment_id      uuid NOT NULL REFERENCES ps_payments(id),
  amount_minor    bigint NOT NULL CHECK (amount_minor > 0),
  reason          text NOT NULL,
  refunded_by     uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ps_refunds_payment_idx ON ps_refunds (payment_id);
CREATE INDEX ps_refunds_venue_time_idx ON ps_refunds (venue_id, created_at);

CREATE TABLE ps_session_events (
  id              bigserial PRIMARY KEY,
  venue_id        uuid NOT NULL REFERENCES venues(id),
  ps_session_id   uuid NOT NULL REFERENCES ps_sessions(id),
  event_type      text NOT NULL,
  actor_user_id   uuid REFERENCES users(id),
  occurred_at     timestamptz NOT NULL,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_id      text
);
CREATE INDEX ps_session_events_session_idx ON ps_session_events (ps_session_id, id);
CREATE INDEX ps_session_events_actor_idx ON ps_session_events (venue_id, actor_user_id, occurred_at DESC);
-- Timer notices fire once per scheduled end time.
CREATE UNIQUE INDEX ps_session_events_timer_once ON ps_session_events (ps_session_id, event_type, (metadata->>'for_end_at'))
  WHERE event_type IN ('TIME_WARNING','TIME_UP');
CREATE TRIGGER ps_session_events_immutable BEFORE UPDATE OR DELETE ON ps_session_events FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER ps_refunds_immutable BEFORE UPDATE OR DELETE ON ps_refunds FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

ALTER TABLE "public"."ps_consoles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."ps_packages" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."ps_sessions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."ps_session_items" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."ps_payments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."ps_refunds" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."ps_session_events" ENABLE ROW LEVEL SECURITY;
