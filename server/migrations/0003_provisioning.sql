-- Authorising a new device from one the user already holds.
--
-- The new device opens a session and shows its code; the old device looks the
-- code up, seals the account bundle to the ephemeral key the session carries
-- and uploads it. The server never sees inside `envelope`.
CREATE TABLE IF NOT EXISTS provision_sessions (
  id            TEXT PRIMARY KEY,
  code          TEXT NOT NULL UNIQUE,
  token_hash    TEXT NOT NULL,       -- SHA-256 of the new device's provisionToken
  ephemeral_key TEXT NOT NULL,       -- b64url X25519 pub of the new device
  device_name   TEXT,
  platform      TEXT,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL,
  approved_by   TEXT,                -- userId whose device approved the session
  approved_at   INTEGER,
  envelope      TEXT,
  claimed_at    INTEGER
);
CREATE INDEX IF NOT EXISTS idx_provision_expiry ON provision_sessions(expires_at);
