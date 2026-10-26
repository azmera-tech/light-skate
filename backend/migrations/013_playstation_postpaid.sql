-- 013: PlayStation post-paid workflow. Sessions start unpaid and bill as games/time are added; payment is taken at
-- checkout. Non-cash payments carry private evidence and stay PENDING (= pending verification) until an authorised
-- user verifies them; a rejected payment keeps its evidence and reason but never counts as received.

-- Games are added one at a time, so a per-game session can legitimately start with zero billable quantity.
ALTER TABLE ps_session_items DROP CONSTRAINT ps_session_items_quantity_check;
ALTER TABLE ps_session_items ADD CONSTRAINT ps_session_items_quantity_check CHECK (quantity >= 0 AND quantity <= 500);

ALTER TABLE ps_payments DROP CONSTRAINT ps_payments_status_check;
ALTER TABLE ps_payments ADD CONSTRAINT ps_payments_status_check
  CHECK (status IN ('PENDING','PAID','REJECTED','CANCELLED','FAILED','PARTIALLY_REFUNDED','REFUNDED'));

ALTER TABLE ps_payments
  ADD COLUMN verification_required boolean NOT NULL DEFAULT false,
  ADD COLUMN tendered_minor        bigint CHECK (tendered_minor IS NULL OR tendered_minor >= amount_minor),
  ADD COLUMN proof_key             text UNIQUE,
  ADD COLUMN proof_mime            text,
  ADD COLUMN proof_size            integer,
  ADD COLUMN proof_sha256          text,
  ADD COLUMN proof_uploaded_at     timestamptz,
  ADD COLUMN rejected_by           uuid REFERENCES users(id),
  ADD COLUMN rejected_at           timestamptz,
  ADD COLUMN reject_reason         text,
  ADD CONSTRAINT ps_payments_rejected_has_reason CHECK (status <> 'REJECTED' OR (reject_reason IS NOT NULL AND rejected_at IS NOT NULL));

-- The same screenshot can never back two live payments, and one bank/Telebirr transaction id can only be used once.
CREATE UNIQUE INDEX ps_payments_proof_once ON ps_payments (venue_id, proof_sha256)
  WHERE proof_sha256 IS NOT NULL AND status IN ('PENDING','PAID','PARTIALLY_REFUNDED','REFUNDED');
CREATE UNIQUE INDEX ps_payments_txn_once ON ps_payments (venue_id, method, upper(reference))
  WHERE reference IS NOT NULL AND method IN ('BANK_TRANSFER','TELEBIRR') AND status IN ('PENDING','PAID','PARTIALLY_REFUNDED','REFUNDED');
CREATE INDEX ps_payments_review_idx ON ps_payments (venue_id, status, created_at DESC);
