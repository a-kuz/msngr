-- Who may put this user straight into a group: everyone, only people whose
-- number this user holds in their own contacts, or nobody. Whoever the tier
-- turns away can still send an invite link.
ALTER TABLE privacy_settings ADD COLUMN group_invites TEXT NOT NULL DEFAULT 'everyone'
  CHECK (group_invites IN ('everyone', 'contacts', 'nobody'));
