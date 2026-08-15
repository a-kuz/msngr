-- Отзыв токена устройства: непустой revoked_at = токен недействителен.
ALTER TABLE devices ADD COLUMN revoked_at INTEGER;
CREATE INDEX IF NOT EXISTS idx_devices_active ON devices(user_id, revoked_at);
