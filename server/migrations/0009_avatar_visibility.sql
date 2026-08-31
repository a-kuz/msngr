-- Who sees the profile photo and bio. The name is never hidden: without it the
-- peer is indistinguishable in the chat list.
ALTER TABLE privacy_settings ADD COLUMN avatar_visibility TEXT NOT NULL DEFAULT 'everyone'
  CHECK (avatar_visibility IN ('everyone', 'contacts', 'nobody'));
