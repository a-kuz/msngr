-- Version of a user's device set: bumped in the same batch as every device
-- link and revocation. Clients compare it to keep their device caches across
-- reconnects instead of re-reading /api/devices.
ALTER TABLE users ADD COLUMN devices_version INTEGER NOT NULL DEFAULT 1;
