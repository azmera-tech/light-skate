-- 011: tiered loyalty cards & rewards. Tier/position rules live in src/modules/loyalty-config.ts (single source of truth);
-- the database enforces the invariants that must hold no matter what code runs: one account per customer, one active
-- card per account, one stamp per skating session, one stamp + one live reward per card position, and one redeemed
-- reward per skating session.

CREATE TABLE loyalty_accounts (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id                uuid NOT NULL REFERENCES venues(id),
  customer_id             uuid NOT NULL UNIQUE REFERENCES customers(id),
  current_tier            text NOT NULL DEFAULT 'STANDARD' CHECK (current_tier IN ('STANDARD','GOLDEN','DIAMOND','LIGHT')),
  current_card_id         uuid,
  total_stamps            integer NOT NULL DEFAULT 0 CHECK (total_stamps >= 0),
  is_max_tier_completed   boolean NOT NULL DEFAULT false,
  max_tier_completed_at   timestamptz,
  public_token            text UNIQUE,          -- unguessable link for the customer's read-only card view; NULL = disabled
  joined_at               timestamptz NOT NULL DEFAULT now(),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  CHECK (is_max_tier_completed = false OR current_tier = 'LIGHT')
);
CREATE INDEX loyalty_accounts_venue_idx ON loyalty_accounts (venue_id, current_tier);

CREATE TABLE loyalty_cards (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  account_id      uuid NOT NULL REFERENCES loyalty_accounts(id),
  tier            text NOT NULL CHECK (tier IN ('STANDARD','GOLDEN','DIAMOND','LIGHT')),
  card_number     integer NOT NULL CHECK (card_number >= 1),   -- 1-based within the tier
  stamps_earned   integer NOT NULL DEFAULT 0 CHECK (stamps_earned BETWEEN 0 AND 10),
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','COMPLETED')),
  started_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz,
  UNIQUE (account_id, tier, card_number),
  CHECK ((status = 'COMPLETED') = (stamps_earned = 10)),
  CHECK (tier <> 'LIGHT' OR card_number = 1)               -- the Light card exists at most once per customer
);
CREATE UNIQUE INDEX loyalty_cards_one_active ON loyalty_cards (account_id) WHERE status = 'ACTIVE';
ALTER TABLE loyalty_accounts ADD CONSTRAINT loyalty_accounts_card_fk FOREIGN KEY (current_card_id) REFERENCES loyalty_cards(id);

CREATE TABLE loyalty_stamps (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  account_id      uuid NOT NULL REFERENCES loyalty_accounts(id),
  card_id         uuid NOT NULL REFERENCES loyalty_cards(id),
  stamp_position  integer NOT NULL CHECK (stamp_position BETWEEN 1 AND 10),
  session_id      uuid NOT NULL UNIQUE REFERENCES sessions(id),  -- a skating session can stamp once, ever (even if later voided)
  award_method    text NOT NULL CHECK (award_method IN ('AUTO_SESSION_END','STAFF_VERIFIED')),
  awarded_by      uuid REFERENCES users(id),
  awarded_at      timestamptz NOT NULL DEFAULT now(),
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','VOIDED')),
  voided_at       timestamptz,
  voided_by       uuid REFERENCES users(id),
  void_reason     text
);
CREATE UNIQUE INDEX loyalty_stamps_one_per_position ON loyalty_stamps (card_id, stamp_position) WHERE status = 'ACTIVE';
CREATE INDEX loyalty_stamps_account_idx ON loyalty_stamps (account_id, awarded_at DESC);

CREATE TABLE loyalty_rewards (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id              uuid NOT NULL REFERENCES venues(id),
  account_id            uuid NOT NULL REFERENCES loyalty_accounts(id),
  card_id               uuid NOT NULL REFERENCES loyalty_cards(id),
  stamp_id              uuid NOT NULL REFERENCES loyalty_stamps(id),
  tier                  text NOT NULL CHECK (tier IN ('STANDARD','GOLDEN','DIAMOND','LIGHT')),
  stamp_position        integer NOT NULL CHECK (stamp_position BETWEEN 1 AND 10),
  reward_type           text NOT NULL CHECK (reward_type IN ('discount_50_percent','free_session','free_burger')),
  code                  text NOT NULL UNIQUE,      -- random, shown to the customer; staff look rewards up by it
  status                text NOT NULL DEFAULT 'AVAILABLE' CHECK (status IN ('AVAILABLE','REDEEMED','VOIDED')),
  earned_at             timestamptz NOT NULL DEFAULT now(),
  redeemed_at           timestamptz,
  redeemed_by           uuid REFERENCES users(id),
  redeemed_session_id   uuid REFERENCES sessions(id),
  redemption_reference  text,
  redemption_note       text,
  voided_at             timestamptz,
  voided_by             uuid REFERENCES users(id),
  void_reason           text,
  CHECK (status <> 'REDEEMED' OR redeemed_at IS NOT NULL)
);
CREATE UNIQUE INDEX loyalty_rewards_one_per_position ON loyalty_rewards (card_id, stamp_position) WHERE status <> 'VOIDED';
-- No stacking: a skating session can be paid by at most one reward.
CREATE UNIQUE INDEX loyalty_rewards_one_per_session ON loyalty_rewards (redeemed_session_id) WHERE status = 'REDEEMED' AND redeemed_session_id IS NOT NULL;
CREATE INDEX loyalty_rewards_account_idx ON loyalty_rewards (account_id, status, earned_at DESC);

-- Loyalty history (stamps, card completions, tier changes, rewards, redemptions, corrections). Append-only.
CREATE TABLE loyalty_events (
  id              bigserial PRIMARY KEY,
  venue_id        uuid NOT NULL REFERENCES venues(id),
  account_id      uuid NOT NULL REFERENCES loyalty_accounts(id),
  actor_user_id   uuid REFERENCES users(id),
  action          text NOT NULL,
  entity_type     text NOT NULL,
  entity_id       uuid,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_id      text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX loyalty_events_account_idx ON loyalty_events (account_id, id DESC);
CREATE TRIGGER loyalty_events_immutable BEFORE UPDATE OR DELETE ON loyalty_events FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

ALTER TABLE "public"."loyalty_accounts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."loyalty_cards" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."loyalty_stamps" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."loyalty_rewards" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."loyalty_events" ENABLE ROW LEVEL SECURITY;
