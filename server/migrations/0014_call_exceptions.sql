-- 'call' joins the settings a named exception can override. SQLite cannot
-- widen a CHECK in place, so the table is rebuilt around the longer list.
CREATE TABLE privacy_exceptions_new (
  user_id TEXT NOT NULL,
  setting TEXT NOT NULL CHECK (setting IN ('last_seen', 'avatar', 'phone_discovery', 'group_invites', 'call')),
  peer_id TEXT NOT NULL,
  allow INTEGER NOT NULL CHECK (allow IN (0, 1)),
  PRIMARY KEY (user_id, setting, peer_id)
);
INSERT INTO privacy_exceptions_new SELECT * FROM privacy_exceptions;
DROP TABLE privacy_exceptions;
ALTER TABLE privacy_exceptions_new RENAME TO privacy_exceptions;
