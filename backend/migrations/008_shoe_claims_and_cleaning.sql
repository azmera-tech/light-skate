-- 008: personal shoe check-in claims + rental equipment cleaning workflow

CREATE TABLE shoe_claims (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id      uuid NOT NULL REFERENCES venues(id),
  claim_number  text NOT NULL,                 -- LS-4827, short + easy to say/search
  customer_id   uuid NOT NULL REFERENCES customers(id),
  visit_id      uuid NOT NULL REFERENCES visits(id),
  session_id    uuid REFERENCES sessions(id),  -- may not exist yet at shoe check-in time
  photo_key     text NOT NULL,
  photo_mime    text NOT NULL,
  status        text NOT NULL DEFAULT 'STORED' CHECK (status IN (
    'STORED','RETURN_PENDING','RETURNED','MISSING','DISPUTED')),
  created_by    uuid REFERENCES users(id),
  returned_by   uuid REFERENCES users(id),
  returned_at   timestamptz,
  device_id     uuid REFERENCES devices(id),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
-- Only one shared shelf: an active (not yet returned) claim number must be unique per venue.
CREATE UNIQUE INDEX shoe_claims_active_number ON shoe_claims (venue_id, claim_number) WHERE status <> 'RETURNED';
CREATE INDEX shoe_claims_venue_idx ON shoe_claims (venue_id, status, created_at DESC);
CREATE INDEX shoe_claims_visit_idx ON shoe_claims (visit_id);
CREATE INDEX shoe_claims_session_idx ON shoe_claims (session_id);

-- A staff "report mismatch / missing shoes" flow raises an ordinary incident, linked back to the claim.
ALTER TABLE incidents ADD COLUMN shoe_claim_id uuid REFERENCES shoe_claims(id);

-- Rental skate cleaning: reuses the existing equipment lifecycle + maintenance_records history
-- rather than standing up a parallel inventory/cleaning system.
ALTER TABLE equipment ADD COLUMN last_cleaned_at timestamptz;
ALTER TABLE equipment ADD COLUMN last_cleaned_by uuid REFERENCES users(id);
ALTER TABLE equipment ADD COLUMN cleaning_due_at timestamptz;

ALTER TABLE equipment DROP CONSTRAINT equipment_status_check;
ALTER TABLE equipment ADD CONSTRAINT equipment_status_check CHECK (status IN (
  'AVAILABLE','RESERVED','ISSUED','IN_USE','RETURNED','DAMAGED','MAINTENANCE','OUT_OF_SERVICE',
  'NEEDS_CLEANING','CLEANING'));

-- maintenance_records already holds everything a cleaning record needs (reported/started/completed,
-- photo, notes) — add a discriminator instead of duplicating the table, plus the checklist answers.
ALTER TABLE maintenance_records ADD COLUMN kind text NOT NULL DEFAULT 'DAMAGE' CHECK (kind IN ('DAMAGE','CLEANING'));
ALTER TABLE maintenance_records ADD COLUMN checklist jsonb;
