-- Signing in from an encrypted backup, with no other device to approve it.
--
-- The new device proves it holds the account's identity private key by
-- signing the nonce this session hands out; the server only ever sees the
-- signature, never the key. `restore/claim.ts`-equivalent verifies it against
-- the identity key already on file for the account.
CREATE TABLE IF NOT EXISTS restore_sessions (
  id                 TEXT PRIMARY KEY,
  user_id            TEXT NOT NULL,
  identity_key       TEXT NOT NULL,       -- expected X25519 pub, from keys-devices
  identity_sign_key  TEXT NOT NULL,       -- expected Ed25519 pub, from keys-devices
  nonce              TEXT NOT NULL,       -- b64url random bytes signed by the claim
  created_at         INTEGER NOT NULL,
  expires_at         INTEGER NOT NULL,
  claimed_at         INTEGER
);
CREATE INDEX IF NOT EXISTS idx_restore_expiry ON restore_sessions(expires_at);
