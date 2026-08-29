-- Server-enforced privacy: who sees last seen, and whether read receipts and
-- typing leave the device. A user with no row here gets the defaults every
-- account starts with: last seen visible, receipts and typing on.
CREATE TABLE IF NOT EXISTS privacy_settings (
  user_id        TEXT PRIMARY KEY REFERENCES users(id),
  last_seen      TEXT NOT NULL DEFAULT 'everyone' CHECK (last_seen IN ('everyone', 'contacts', 'nobody')),
  read_receipts  INTEGER NOT NULL DEFAULT 1,
  typing         INTEGER NOT NULL DEFAULT 1,
  updated_at     INTEGER NOT NULL
);
