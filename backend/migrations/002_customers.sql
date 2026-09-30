-- 002_customers: customers, photos, emergency contacts, waivers
CREATE TABLE customers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  customer_no     integer NOT NULL,   -- human-friendly id shown to staff (LS-C000123)
  full_name       text NOT NULL,
  phone_e164      text,              -- canonical form, see src/shared/phone.ts
  phone_raw       text,              -- what staff typed (display / diagnostics)
  email           text,
  date_of_birth   date,
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','BLOCKED','ARCHIVED','ERASED')),
  notes           text,
  registered_at   timestamptz NOT NULL DEFAULT now(),
  created_by      uuid REFERENCES users(id),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  erased_at       timestamptz
);
-- Deliberately NOT unique: a parent may register several children on one phone.
-- Duplicate detection is a staff-confirmed workflow (see customers service).
CREATE UNIQUE INDEX customers_no_uq ON customers (venue_id, customer_no);
CREATE INDEX customers_phone_idx ON customers (venue_id, phone_e164);
CREATE INDEX customers_name_trgm ON customers USING gin (full_name gin_trgm_ops);
CREATE INDEX customers_registered_idx ON customers (venue_id, registered_at DESC);

CREATE TABLE emergency_contacts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id   uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  name          text NOT NULL,
  phone         text NOT NULL,
  relationship  text,
  is_guardian   boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX emergency_contacts_customer_idx ON emergency_contacts (customer_id);

-- Photo metadata only. Bytes live in protected object storage (storage_key).
CREATE TABLE customer_photos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id        uuid NOT NULL REFERENCES venues(id),
  customer_id     uuid NOT NULL REFERENCES customers(id),
  visit_id        uuid,              -- FK added in 003 (visits defined later)
  purpose         text NOT NULL CHECK (purpose IN ('PROFILE','VISIT')),
  storage_key     text NOT NULL UNIQUE,
  mime_type       text NOT NULL,
  size_bytes      integer NOT NULL,
  width           integer NOT NULL,
  height          integer NOT NULL,
  sha256          text NOT NULL,
  status          text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','EXPIRED','DELETED')),
  captured_at     timestamptz NOT NULL DEFAULT now(),
  captured_by     uuid REFERENCES users(id),
  device_id       uuid REFERENCES devices(id),
  retention_until timestamptz,       -- NULL = retained while the customer profile is active
  deleted_at      timestamptz
);
CREATE INDEX customer_photos_customer_idx ON customer_photos (customer_id, status, captured_at DESC);
CREATE INDEX customer_photos_retention_idx ON customer_photos (retention_until) WHERE status = 'ACTIVE' AND retention_until IS NOT NULL;

CREATE TABLE waivers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id    uuid NOT NULL REFERENCES venues(id),
  code        text NOT NULL,
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (venue_id, code)
);

-- Versions are immutable once published; a change creates a new version.
CREATE TABLE waiver_versions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  waiver_id     uuid NOT NULL REFERENCES waivers(id),
  venue_id      uuid NOT NULL REFERENCES venues(id),
  version       integer NOT NULL,
  language      text NOT NULL DEFAULT 'en',
  title         text NOT NULL,
  body          text NOT NULL,
  is_current    boolean NOT NULL DEFAULT false,
  published_at  timestamptz NOT NULL DEFAULT now(),
  published_by  uuid REFERENCES users(id),
  UNIQUE (waiver_id, version)
);
CREATE UNIQUE INDEX waiver_versions_one_current ON waiver_versions (waiver_id) WHERE is_current;

CREATE TABLE waiver_acceptances (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id           uuid NOT NULL REFERENCES venues(id),
  customer_id        uuid NOT NULL REFERENCES customers(id),
  waiver_version_id  uuid NOT NULL REFERENCES waiver_versions(id),
  visit_id           uuid,
  accepted_at        timestamptz NOT NULL DEFAULT now(),
  accepted_by_staff  uuid REFERENCES users(id),
  device_id          uuid REFERENCES devices(id),
  signature_data     text,           -- small SVG/PNG data URL captured on the tablet
  for_minor          boolean NOT NULL DEFAULT false,
  guardian_name      text,
  guardian_phone     text,
  status             text NOT NULL DEFAULT 'ACCEPTED' CHECK (status IN ('ACCEPTED','REVOKED'))
);
CREATE INDEX waiver_acceptances_customer_idx ON waiver_acceptances (customer_id, waiver_version_id);
