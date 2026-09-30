-- 004_payments: payments, ledger transactions, events, refunds
CREATE TABLE payments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id           uuid NOT NULL REFERENCES venues(id),
  visit_id           uuid NOT NULL REFERENCES visits(id),
  session_id         uuid REFERENCES sessions(id),
  customer_id        uuid NOT NULL REFERENCES customers(id),
  amount_minor       bigint NOT NULL CHECK (amount_minor >= 0),   -- exact minor units (1 ETB = 100 santim)
  currency           text NOT NULL,
  method             text NOT NULL,
  provider           text NOT NULL DEFAULT 'manual',
  provider_reference text,
  status             text NOT NULL CHECK (status IN (
    'PENDING','AUTHORIZED','PAID','FAILED','CANCELLED','REFUNDED','PARTIALLY_REFUNDED')),
  refunded_minor     bigint NOT NULL DEFAULT 0 CHECK (refunded_minor >= 0),
  purpose            text NOT NULL DEFAULT 'SESSION' CHECK (purpose IN ('SESSION','EXTENSION','OTHER')),
  note               text,
  created_by         uuid REFERENCES users(id),
  device_id          uuid REFERENCES devices(id),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CHECK (refunded_minor <= amount_minor)
);
CREATE INDEX payments_venue_time_idx ON payments (venue_id, created_at);
CREATE INDEX payments_session_idx ON payments (session_id);
CREATE INDEX payments_visit_idx ON payments (visit_id);

-- Append-only money ledger: one CHARGE per settled payment, one REFUND per refund.
CREATE TABLE payment_transactions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  payment_id      uuid NOT NULL REFERENCES payments(id),
  type            text NOT NULL CHECK (type IN ('CHARGE','REFUND')),
  amount_minor    bigint NOT NULL CHECK (amount_minor > 0),
  currency        text NOT NULL,
  method          text NOT NULL,
  provider_reference text,
  created_by      uuid REFERENCES users(id),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX payment_transactions_venue_time_idx ON payment_transactions (venue_id, created_at);
CREATE INDEX payment_transactions_payment_idx ON payment_transactions (payment_id);

CREATE TABLE payment_events (
  id            bigserial PRIMARY KEY,
  venue_id      uuid NOT NULL REFERENCES venues(id),
  payment_id    uuid NOT NULL REFERENCES payments(id),
  event_type    text NOT NULL,
  from_status   text,
  to_status     text,
  actor_user_id uuid REFERENCES users(id),
  device_id     uuid REFERENCES devices(id),
  occurred_at   timestamptz NOT NULL,
  metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_id    text
);
CREATE INDEX payment_events_payment_idx ON payment_events (payment_id, id);

CREATE TABLE refunds (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id         uuid NOT NULL REFERENCES venues(id),
  payment_id       uuid NOT NULL REFERENCES payments(id),
  transaction_id   uuid REFERENCES payment_transactions(id),
  amount_minor     bigint NOT NULL CHECK (amount_minor > 0),
  reason           text NOT NULL,
  status           text NOT NULL DEFAULT 'COMPLETED' CHECK (status IN ('PENDING','COMPLETED','REJECTED')),
  requested_by     uuid REFERENCES users(id),
  approved_by      uuid REFERENCES users(id),
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refunds_payment_idx ON refunds (payment_id);
ALTER TABLE session_extensions ADD CONSTRAINT session_extensions_payment_fk FOREIGN KEY (payment_id) REFERENCES payments(id);
