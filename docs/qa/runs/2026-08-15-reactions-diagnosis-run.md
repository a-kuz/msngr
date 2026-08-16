# Three reactions in a two-person dialog: the diagnosis

The symptom the owner reported: under a single message in a dialog with two
participants, `👍2` and `❤️` at the same time, counters adding up to 3 where
there are two people.

Two hypotheses were checked: a new registration inheriting someone else's
database (A), and miscounting when a reaction is changed (B).

A is the one that holds. B was not confirmed in any of the scenarios run.

## Stand

Own simulators `msngr-rx-A` (9732467E) and `msngr-rx-B` (BAD3A81A), iPhone 17,
iOS 26.5, deleted after the run. Own `wrangler dev` on :8809 with a separate
`--persist-to` (the D1 schema was applied with `wrangler d1 execute msngr
--local --persist-to ... --file schema.sql`; without it registration answers
500). The app was launched with `SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8809`,
built from HEAD `ca9eacd` into its own `derivedDataPath`. Users: `rxalpha`
(01M01ZJN8AHPB3G803ES90BGG8), `rxbeta` (01M01ZKE9PX7M5E1XA450PA4GE), later
`rxgamma` (01M02089DHDA71ET11V2W8DFR9). The chat was created with
`POST /api/chats` under A's token. State was read straight out of the group
container's `msngr.sqlite` (from a copy, so as not to disturb the WAL).

## B: counting when a reaction changes, does not reproduce

Clean database, dialog `hello`, a snapshot after every step (the sum is the
number of userIds across all arrays in `message.reactions`):

| Step | Expectation | Fact on A | Fact on B |
|-----|----------|-----------|-----------|
| B reacts 👍 | 👍1 | 👍1 | 👍1 |
| A reacts 👍 | 👍2 | 👍2 | 👍2 |
| A switches to ❤️ | 👍1 ❤️1 | 👍1 ❤️1 | 👍1 ❤️1 |
| A taps 👍 then 🔥 in quick succession | 👍1 🔥1 | 👍1 🔥1 | 👍1 🔥1 |
| B removes its own by tapping the capsule again | 🔥1 | 🔥1 | 🔥1 |
| B taps the other user's 🔥 capsule | 🔥2 | 🔥2 | 🔥2 |
| A and B change at the same moment (😂 and 😮) | 😂1 😮1 | 😂1 😮1 | 😂1 😮1 |
| both apps restarted | unchanged | 😂1 😮1 | 😂1 😮1 |
| `syncedSeq` reset on B, server replays the whole history over WS | unchanged | 😂1 😮1 | 😂1 😮1 |

The "no more than one reaction per user" invariant holds because the field has a
single writer, `SyncEngine.applyReaction`
(`ios/MsngrKit/Sources/MsngrCore/SyncEngine.swift:1119`): it first strips the
userId out of every emoji, then adds it to the new one. Every path goes through
it: local sending (`enqueue`, SyncEngine.swift:722), a live frame
(`applyContent`, :529), historic application (`storeHistoric`, :585) and
deferred application (`applyBuffered`, :1174). The unit tests for those branches
(`HistoricReplayTests`, `ServiceFrameTests`) pass: `swift test --filter
"HistoricReplayTests|ServiceFrameTests"`, 6 of 6.

Upward pagination (`storeHistoric`) could not be checked live, for an unrelated
reason: after a message was deleted from the local database the client asked
`/history`, received 10 envelopes and stored none of them, because the ratchet
keys for already decrypted messages are spent. That is a separate observation
with no bearing on the counters, but it means the `storeHistoric` branch in
practice only works for messages the client has not decrypted yet.

## A: inheriting someone else's database, reproduces exactly

1. On A, with a live `rxalpha` session, `session.json` was deleted from the
   group container (imitating the earlier behaviour where the session was not
   persisted) and the app was restarted, landing on the registration screen with
   `msngr.sqlite` still in place.
2. A new user `rxgamma` registers. Immediately afterwards the chat list opens
   with the old dialog: the whole conversation and the previous personality's
   reactions are still there. In the database, `member` holds alpha and beta and
   `user` holds alpha and beta; gamma appears nowhere.
3. Gamma reacts 😂 to an inherited message, giving
   `{"😮":["…beta"],"😂":["…alpha","…gamma"]}`, sum 3. On screen that is `😂 2`
   and `😮` under one message in what looks like a conversation between two
   people, which is exactly the owner's symptom.

Gamma's reaction never reached the server: gamma is not a member of the chat, so
the `outbox` row stayed `inflight` and the peer's counter did not move. The
extra count exists only on this device.

### Where it is in the code

- `ios/Msngr/Onboarding/RegisterView.swift:82`: registration opens the existing
  container database (`AppState.storage` → `AppDatabase.open`) and takes the
  identity from it; nothing is wiped.
- `ios/Msngr/App/AppState.swift:62` `saveSession`: writes the new session and
  brings the core up on top of the old data. A wipe happens only in
  `resetToRegistration()` (`AppState.swift:87`, called from `logout()` and
  `finishRevokedSession()`), so only a deliberate logout and a device revocation
  are covered.
- `ios/Msngr/App/AppState.swift:44` `loadSession`: if the file is missing or
  unreadable the app silently goes to registration and the database stays.
- Storage is not bound to an account in any way: there is no owner marker (in
  `kv`, for instance) and `AppDatabase.open` does not check one.
- What that does to the counter: `SyncEngine.applyReaction` tells people apart
  strictly by userId, and the arrays keep userIds of previous personalities that
  are no longer in `member`. The capsule's counter is the length of the array
  (`BubbleLayout.swift:185`), so the sum legitimately exceeds the number of
  participants.

A deliberate logout really is clean: after «Выйти» the group container keeps
only `avatars` and `Library`, while `msngr.sqlite`, `session.json` and the
master key are removed.

## Proposed fix (not applied)

Bind local storage to an account and wipe it when the owner changes:

1. Write an `ownUserId` marker into `kv` at bootstrap.
2. In `RegisterView.register()`, before `AppDatabase.open` and before key
   generation, compare the marker: if the database file exists and the marker is
   not empty, call `AppContainer.wipe(AppState.storage)`. A new account never
   inherits data legitimately, so the condition can be reduced to "registration
   is running and the container already has data".
3. Handle an unreadable `session.json` in `loadSession` the same way: the same
   wipe rather than a silent fall back to registration on top of someone else's
   data.

Order matters: the identity is created in that same database inside
`register()`, so wiping after `store.identity()` would destroy the keys that
were just generated.

Verify the fix with this same run: delete `session.json`, restart, register a
new user, and the chat list should be empty.
