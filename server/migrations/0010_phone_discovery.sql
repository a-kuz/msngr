-- Who may find this user by their phone hash: everyone, only people whose
-- number this user holds in their own contacts, or nobody. The username
-- search is not gated: a handle exists to be found by.
ALTER TABLE privacy_settings ADD COLUMN phone_discovery TEXT NOT NULL DEFAULT 'everyone'
  CHECK (phone_discovery IN ('everyone', 'contacts', 'nobody'));
