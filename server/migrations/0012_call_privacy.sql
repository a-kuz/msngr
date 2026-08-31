-- Who may ring this user: everyone, only people whose number this user holds
-- in their own contacts, or nobody. The signaling is E2EE, so the server
-- cannot gate the call itself; the tier is read by the callee's device, which
-- answers a shut-out offer busy, and by the user card, which tells a viewer
-- whether the dial button is worth showing.
ALTER TABLE privacy_settings ADD COLUMN call_privacy TEXT NOT NULL DEFAULT 'everyone'
  CHECK (call_privacy IN ('everyone', 'contacts', 'nobody'));
