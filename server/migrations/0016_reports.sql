-- User reports of a chat or a message. `attached` is a JSON array of the
-- excerpts the reporter chose to attach, decrypted on their device.
CREATE TABLE reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  reporter_id TEXT NOT NULL,
  chat_id TEXT,
  target_user_id TEXT,
  reason TEXT NOT NULL,
  comment TEXT,
  attached TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_reports_reporter ON reports (reporter_id, created_at);
