-- Device token revocation: a non-empty revoked_at means the token is invalid.
ALTER TABLE devices ADD COLUMN revoked_at INTEGER;
CREATE INDEX IF NOT EXISTS idx_devices_active ON devices(user_id, revoked_at);
