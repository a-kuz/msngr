# Account backup and restore, live run

2026-08-30, three simulators (`backup-a`, `backup-b`, `backup-c`, iPhone 17,
iOS 26.5), an own stand on `:8809` (`wrangler dev --persist-to .wrangler-backup`),
branch `run-backup`. The account under test, `alfa`, came from `msngrfixture
seed --dir /tmp/backup-fixtures --base http://localhost:8809`: three direct
chats and three groups with history, registered through the real core.

## What was run

1. `alfa`'s state (`msngr.sqlite`, `.masterkey`, `session.json`) copied by hand
   into `backup-a`'s app group container (the same three files
   `scripts/fixture.py install` moves, just pointed at a fixture dir outside
   `.claude/fixtures` so the shared trio was never touched).
2. On `backup-a`: sent a photo to the Bravo Service chat (attached from the
   simulator's photo library via `xcrun simctl addmedia`), then Settings →
   Backup → "Turn on backup". Recovery code shown: `GX77-TGX3-YJEX-EMDH-
   MYPB-N4N3`. "Back up now" produced a 397 KB file, saved through the Files
   share sheet to "On My iPhone" as `msngr-alfa.msngrbackup`.
3. The file copied to a freshly created `backup-c` simulator (no app data,
   registration screen only), placed into the local Files-provider storage
   FileProvider container by hand (the same place `fileExporter` itself
   writes to — confirmed by finding the `group.com.apple.FileProvider.
   LocalStorage` app group by its metadata plist on both devices).
4. "Restore from a backup" from the registration screen → picked the file →
   typed the recovery code → Restore.
5. Sent two new messages from `backup-c` (now `alfa`) to Bravo Service, then
   ran `msngrfixture answer --as bravo --dir /tmp/backup-fixtures` to bring the
   real `bravo` client online against the same stand.

## Result

All 6 chats (Saved Messages, Bravo Service, Charlie Service, Random, Standup,
Design) came back with their full history and unread counts. The photo sent
before the backup rendered in the feed on `backup-c` — media was fetched and
re-embedded at backup time, not merely copied from whatever the cache still
held. Zero unreadable messages, on either device, at any point.

Both messages sent after restore went from "sent" (one grey check) to
"delivered/read" (two orange checks) once `bravo`'s client connected and
decrypted them — proof the restored device's fresh identity-adopt +
`generatePrekeys` + `/api/restore/claim` produced a session `bravo` could
actually open, not just that the UI accepted the recovery code. The account's
`userId` was unchanged across the restore (verified via the claim response),
confirming `/api/restore/claim`'s identity-match check did its job.

Not verified: an interrupted restore (network drop mid-claim, app killed
between claim and `saveSession`); the CloudKit transport (no signed-in Apple
ID on the simulator — the sealed backup format is transport-agnostic, so this
is deferred, not broken); the palette/notification-preference fields of the
payload (`alfa` never changed them from default, so the restore path for
those two fields ran but produced no visible difference to check against).

## A defect found and fixed during the run

`BackupView` recorded `BackupStore.lastBackupAt`/`lastBackupSize` (and updated
the "Last backup" row) as soon as the seal succeeded, before the `fileExporter`
sheet even appeared — a user who cancelled the Files picker would still see a
"successful" backup with no file anywhere. Moved both writes into the
`fileExporter` completion handler's `.success` case.

## A defect in the harness, not the product

`idb ui text`/`idb ui key-sequence` type through the *host* Mac's currently
active keyboard input source, not the guest simulator's — with a Cyrillic
input source active on the host, every typed character came out mapped
through ЙЦУКЕН regardless of the simulator's own `AppleKeyboards` setting.
Switching the host's active input source to ABC (via `TextInputMenuAgent`'s
menu, `System Events` UI scripting) before typing, and restarting
`idb_companion` after the switch, fixed it. `AppleKeyboards` still needs to be
a single-entry array (`en_US@sw=QWERTY;hw=US`) and the simulator rebooted
after writing it — a second enabled keyboard (e.g. a stale `ru_RU` entry from
the simulator's default locale) silently wins even with the host on ABC.
