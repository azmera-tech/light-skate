-- 001_core: venues, RBAC, users, devices, settings
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE venues (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name         text NOT NULL,
  slug         text NOT NULL UNIQUE,
  timezone     text NOT NULL DEFAULT 'Africa/Addis_Ababa',
  currency     text NOT NULL DEFAULT 'ETB',
  status       text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED')),
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE permissions (
  code         text PRIMARY KEY,
  description  text NOT NULL
);

CREATE TABLE roles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id     uuid NOT NULL REFERENCES venues(id),
  code         text NOT NULL,
  name         text NOT NULL,
  is_system    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (venue_id, code)
);

CREATE TABLE role_permissions (
  role_id          uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_code  text NOT NULL REFERENCES permissions(code),
  PRIMARY KEY (role_id, permission_code)
);

CREATE TABLE users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id           uuid NOT NULL REFERENCES venues(id),
  email              text NOT NULL,
  password_hash      text NOT NULL,
  full_name          text NOT NULL,
  role_id            uuid NOT NULL REFERENCES roles(id),
  status             text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
  failed_login_count integer NOT NULL DEFAULT 0,
  locked_until       timestamptz,
  last_login_at      timestamptz,
  must_change_password boolean NOT NULL DEFAULT false,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email_uq ON users (lower(email));
CREATE INDEX users_venue_idx ON users (venue_id);

CREATE TABLE staff_profiles (
  user_id       uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  display_name  text NOT NULL,
  phone         text,
  employee_no   text
);

CREATE TABLE devices (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id       uuid NOT NULL REFERENCES venues(id),
  name           text NOT NULL,
  device_type    text NOT NULL DEFAULT 'FRONT_DESK'
                 CHECK (device_type IN ('FRONT_DESK','RENTAL_DESK','MANAGER','KIOSK','OTHER')),
  status         text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DISABLED')),
  last_seen_at   timestamptz,
  registered_at  timestamptz NOT NULL DEFAULT now(),
  registered_by  uuid REFERENCES users(id),
  UNIQUE (venue_id, name)
);

CREATE TABLE auth_sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  venue_id     uuid NOT NULL REFERENCES venues(id),
  device_id    uuid REFERENCES devices(id),
  token_hash   text NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  ip           text,
  user_agent   text
);
CREATE INDEX auth_sessions_user_idx ON auth_sessions (user_id);

-- Per-venue business policy lives here (see src/settings.ts for the typed schema + defaults).
CREATE TABLE system_settings (
  venue_id    uuid NOT NULL REFERENCES venues(id),
  key         text NOT NULL,
  value       jsonb NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid REFERENCES users(id),
  PRIMARY KEY (venue_id, key)
);
