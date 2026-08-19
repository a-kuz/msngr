-- The X25519 identity key, signed by the Ed25519 one. A client trusts a peer by
-- the signing key and encrypts to the DH key, so the pair travels bound: without
-- the signature the two are unrelated values and whoever serves them can put a
-- key of its own beside a real identity.
--
-- Rows written before this column exists carry an empty signature, which no
-- client accepts: those devices register again.
ALTER TABLE identity_keys ADD COLUMN identity_key_sig TEXT NOT NULL DEFAULT '';
