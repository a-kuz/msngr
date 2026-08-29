# Privacy settings: last seen, read receipts, typing

2026-08-30, one simulator (`privacy`, iPhone 17, iOS 26.5), an own stand on
`:8815` (`wrangler dev --persist-to server/.wrangler-privacy`), branch
`run-privacy`. Migration `0008_privacy_settings.sql` applied to that stand
before the run.

## What was built

- `server/migrations/0008_privacy_settings.sql`: `privacy_settings(user_id,
  last_seen, read_receipts, typing)`, a row per user, defaults applied for
  anyone with no row.
- `GET /api/privacy` / `POST /api/privacy` (`server/src/index.ts`): read and
  write the caller's own settings; `POST` accepts a partial body, each field
  left out keeps its current value.
- Enforcement, not just an interface hint:
  - `presenceVisible` (`server/src/index.ts`) and `ConversationDO`'s
    `/presence` handler drop the presence frame at the source when the owner's
    `lastSeen` is `nobody`, and also skip a member who hid their own — hiding
    it blinds you to everyone else's too, the same reciprocity as Telegram.
  - `ConversationDO`'s `/recv` and `/read` handlers still record the reader's
    own mark (needed for their own unread state) but only fan the `receipt`
    frame out when the reader's `readReceipts` is on, and skip any recipient
    who turned theirs off.
  - `ConversationDO`'s `/typing` handler drops the frame at the source when
    the typist's `typing` is off, and skips a recipient with theirs off.
- iOS: `PrivacyView.swift` (three rows — last seen picker, read receipts
  toggle, typing toggle), reached from Settings → Security → Privacy
  (`SettingsView.swift`). `APIClient.privacy()` / `setPrivacy(...)`.
- English base strings + Russian translations added to
  `ios/Msngr/Localizable.xcstrings` (manual entries, matching the pattern of
  the existing catalog).
- `server/test/smoke.mjs`, section 21: 19 checks covering enforcement of all
  three settings and their reciprocity, following the shape of the existing
  block-section checks.

## What was run

- `npm run typecheck` (server): clean.
- `node test/smoke.mjs` against the own stand: **310/310 pass** (`ALL PASS`),
  including the new section. One unrelated flake was hit and diagnosed along
  the way: a `HeadersTimeoutError` from host load on an earlier attempt (fixed
  by re-running once the concurrent xcodebuild finished) and a pre-existing gap
  in my own stand setup — `CMID_MIN_AGE`/`CMID_SWEEP_EVERY` need to be `0` for
  the idempotency-sweep test, same as the shared dev stand; neither is caused
  by this change.
- `swift test` in `MsngrKit`: 446 tests, 0 failures.
- `xcodebuild test -only-testing:MsngrTests` (own simulator, `MSNGR_APP_ID=
  msngr.msngr`): 258 tests, 0 failures.
- Live run: registered a fresh user against the own stand
  (`MSNGR_SERVER=http://localhost:8815`), opened Settings → Privacy. Verified
  by tapping through the UI (idb) and reading the server's D1 row after each
  change:
  - toggled "Read receipts" off → `POST /api/privacy` → `read_receipts = 0` in
    `privacy_settings`, toggled back on;
  - picked "Nobody" for "Last seen" → `last_seen = 'nobody'`, restored to
    "Everyone".
  - The Russian localization renders correctly (screen title, all three rows,
    footers) since the simulator runs in Russian.

## Not done

- The "contacts" tier of last seen is stored and selectable in the UI but not
  enforced as distinct from "everyone": this codebase has no contacts-list
  primitive (no mutual-contacts table) to check membership against, only
  one-shot phone-hash discovery. Enforcing it needs that primitive built
  first.
- Per-person exceptions ("everyone except these people") for any setting.
- Avatar/bio/name visibility, who can find me by number, who can add me to a
  group, who can call me, a default disappearing timer, and report-a-chat —
  explicitly out of scope per the task (next slice).
- No client-side "decide not to send" logic was added for read receipts or
  typing: unlike the message-request case, that pattern doesn't apply here.
  The client already sends `read`/`recv`/`typing` frames unconditionally
  today for a blocked peer (`SyncEngine.swift` has no `isBlocked` check before
  sending them), and the block feature's whole restriction lives in
  `ConversationDO`. Privacy follows the same shape: adding a client-side skip
  would only add a second enforcement path to keep in sync with the server's,
  and — for read receipts specifically — would also have broken the reader's
  own mark being recorded, which the server needs for unread bookkeeping
  independent of whether the peer is told about it.
