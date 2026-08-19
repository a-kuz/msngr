-- A username a rename frees stays out of circulation for a while: otherwise
-- whoever is watching a handle inherits the searches for it the instant its
-- owner steps away from it. `released_by` lets the same owner take it back
-- immediately; anyone else waits out the quarantine.
CREATE TABLE IF NOT EXISTS released_usernames (
  username    TEXT PRIMARY KEY COLLATE NOCASE,
  released_by TEXT NOT NULL,
  released_at INTEGER NOT NULL
);
