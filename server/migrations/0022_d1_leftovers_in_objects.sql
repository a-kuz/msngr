-- The last of D1 follows its owner into a Durable Object. The profile, the
-- device list with its bearer tokens, the push tokens, the blocks, the privacy
-- tiers with their named exceptions and the filed reports live in the user's
-- own object (UserDO); the phone-hash index joins the people index in
-- DirectoryDO; provisioning and restore sessions and invite codes are objects
-- addressed by the code itself (LookupDO). Media blobs are in R2 and the row
-- beside them was read by nobody.
--
-- Nothing in the server reads or writes this database after this migration.
DROP TABLE IF EXISTS privacy_exceptions;
DROP TABLE IF EXISTS privacy_settings;
DROP TABLE IF EXISTS reports;
DROP TABLE IF EXISTS restore_sessions;
DROP TABLE IF EXISTS provision_sessions;
DROP TABLE IF EXISTS one_time_prekeys;
DROP TABLE IF EXISTS identity_keys;
DROP TABLE IF EXISTS blocks;
DROP TABLE IF EXISTS invites;
DROP TABLE IF EXISTS media;
DROP TABLE IF EXISTS devices;
DROP TABLE IF EXISTS users;
