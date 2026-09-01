# Deleting the account — live run

2026-09-01, simulator fable-a (iPhone 17), stand `wrangler dev` on :8809
(`--persist-to .wrangler/state-coord-fail`).

## Scenario

1. Registered a throwaway user `deleteme1` («Delete Me») on a clean install —
   `2026-09-01-delete-account-before.png` shows the chat list after
   registration; D1 held the row
   (`users: 01M1E0BHDN0M3M6BCPJWVMECCT|deleteme1`).
2. Settings → scrolled to the bottom → «Удалить аккаунт». The confirmation
   dialog spells out the consequences and offers a single destructive action —
   `2026-09-01-delete-account-dialog.png`.
3. Confirmed. The app returned to the registration screen
   (`2026-09-01-delete-account-after.png`).

## Verified

- Server log: `POST /api/account/delete 200 OK`.
- D1 after the run: `users` and `devices` rows for the user are gone
  (`SELECT count(*)` → 0 for both).
- The freed username registering again, the deleted token being rejected and
  the deleted user leaving its groups are covered by the delete-account block
  in `server/test/smoke.mjs` (ALL PASS on this stand).

One stumble on the way, environment not product: the stand's local D1 state
predated migration 0015 (`display_name_lc`), so the first register answered
500 until `wrangler d1 migrations apply msngr --local` was run against the
stand's persist directory.
