-- Named-people overrides for the privacy tiers: an allow row shows the
-- setting to that person whatever the tier says, a deny row hides it the
-- same way. One row per (owner, setting, peer).
CREATE TABLE privacy_exceptions (
  user_id TEXT NOT NULL,
  setting TEXT NOT NULL CHECK (setting IN ('last_seen', 'avatar', 'phone_discovery', 'group_invites')),
  peer_id TEXT NOT NULL,
  allow INTEGER NOT NULL CHECK (allow IN (0, 1)),
  PRIMARY KEY (user_id, setting, peer_id)
);
