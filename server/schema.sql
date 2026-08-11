CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE COLLATE NOCASE,
  display_name TEXT NOT NULL,
  bio TEXT,
  avatar_id TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT,
  token_hash TEXT NOT NULL,
  apns_token TEXT,
  apns_env TEXT,
  created_at INTEGER NOT NULL,
  last_seen INTEGER
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id);
CREATE INDEX IF NOT EXISTS idx_devices_token ON devices(token_hash);

CREATE TABLE IF NOT EXISTS identity_keys (
  device_id TEXT PRIMARY KEY REFERENCES devices(id),
  user_id TEXT NOT NULL,
  identity_key TEXT NOT NULL,          -- b64url Curve25519 pub (X25519)
  identity_sign_key TEXT NOT NULL,     -- b64url Ed25519 pub
  signed_prekey_id INTEGER NOT NULL,
  signed_prekey TEXT NOT NULL,
  signed_prekey_sig TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ik_user ON identity_keys(user_id);

CREATE TABLE IF NOT EXISTS one_time_prekeys (
  device_id TEXT NOT NULL,
  key_id INTEGER NOT NULL,
  key TEXT NOT NULL,
  PRIMARY KEY (device_id, key_id)
);

CREATE TABLE IF NOT EXISTS blocks (
  user_id TEXT NOT NULL,
  blocked_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, blocked_id)
);

CREATE TABLE IF NOT EXISTS invites (
  code TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS media (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL,
  size INTEGER,
  created_at INTEGER NOT NULL
);
