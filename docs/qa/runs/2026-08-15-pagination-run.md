# Paging up over the local database

Upward pagination used to ask the server for older pages. The ratchet is
forward-only, so those requests bring nothing back for anything this device has
already decrypted: the 2026-08-15 reactions run recorded 10 envelopes fetched
and 0 stored. The feed now walks the local database instead, and the server is
asked only for seq ranges the device has never processed.

Screenshots — `2026-08-15-pagination/`.

## Stand

Own simulator `msngr-pagination` (545FE999), iPhone 17, iOS 26.5, deleted after
the run. Own `wrangler dev` on :8813 with a separate `--persist-to` (D1 schema
applied with `wrangler d1 execute msngr --local --persist-to … --file
schema.sql`; the local wrangler binary must create both the schema and the dev
server, a version mismatch leaves the persist directory unusable). The app was
launched with `SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8813`, build from the
working tree. Users: `pgalpha` on the simulator, `pgbeta` and `pggamma` as
headless peers that seeded the chats. Server request log was read from the
wrangler output.

## Run

| Step | Expectation | Fact |
|------|-------------|------|
| chat of 70 incoming messages, opened | feed at the bottom, message 70 last | as expected (`04-chat-bottom.png`) |
| scrolling up | older messages keep coming, no spinner | as expected (`05-scrolled-mid.png`) |
| scrolling to the very beginning | messages 1…70 all present, nothing missing | as expected (`06-history-start.png`) |
| top of the feed | one «История начинается здесь» item above the first message | as expected (`06-history-start.png`) |
| whole scroll | no request to the server | 0 `/history` requests in the wrangler log |
| tap on a quote of message 1 from the bottom of a freshly opened chat | jump to the original outside the window | window expanded, feed scrolled to message 1 (`07-quote-bottom.png`, `08-quote-jump.png`) |
| «вниз» button from the top | back to the newest message | as expected (`09-back-to-bottom.png`) |
| own message sent while scrolled up | feed jumps to the bottom, message with a tick | as expected (`10-own-message.png`) |

The client database after the run: 70 messages with seq 1…70, `syncedSeq` 70,
`historyGap` empty — a contiguous history has no open ranges, which is why the
server was never asked.

## What the run did not cover

An unreadable seq needs an envelope whose keys are gone; the run had no way to
produce one against a fresh stand. The placeholder path — record in
`historyGap` with a reason and an attempt counter, one neutral item in the feed
once attempts are spent — is covered by `HistoryWindowTests` and
`HistoryFeedTests` only.

## Side observation

Accepting a message request left the feed under a stuck blur: the messages were
readable through it, the state did not settle on its own, and an app restart
cleared it. Reproduced once, on the first accept of the run; the second accept
was not screenshotted before the restart. Not related to pagination.
