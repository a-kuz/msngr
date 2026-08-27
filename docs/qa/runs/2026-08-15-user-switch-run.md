# Storage owner change: a new registration inherits nothing (#64)

Verification of the fix proposed in
`docs/qa/runs/2026-08-15-reactions-diagnosis-run.md`. The local database lives in the
app group container and outlives the account, so once `session.json` disappeared
the newly registered user opened the previous personality's chats, and its
reaction landed on top of foreign user ids — that is where reaction counters
above the number of participants came from.

## Change under test

A `kv` marker `ownUserId` binds the storage to one account (`StorageOwnership`).
Registration wipes the container **before** it opens the database and generates
the identity keys (`StorageOwnership.openOwned`); the marker is written once the
server has answered. `AppState.bootstrap` compares the marker with the session:
a foreign or missing marker sends the app back to registration on clean storage.
A database from a build without the marker counts as foreign.

## Stand

Own simulators `msngr-sw-A` (34245E1D) and `msngr-sw-B` (D8388E7C), iPhone 17,
iOS 26.5, deleted after the run. Own `wrangler dev` on :8811 with a separate
`--persist-to` (schema applied with `wrangler d1 execute msngr --local
--persist-to … --file schema.sql`). The app was launched with
`SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8811`, built from commit `cc5966a`
into a separate `derivedDataPath`. Users: `swalpha`
(01M023JZWTJFVP3MS2ZCYRR10W), `swbeta` (01M023PDS5JJYMKGNB9CS9SA41), `swgamma`
(01M0241EQW6BQZJ8W3TYVQGKC4), `swdelta` (01M024GV0CQ8K5HKM1ANWD78FC). Database
state was read from a copy of `msngr.sqlite` taken from the group container.

## 1. Lost session, then a new registration

   two messages, 👍 from beta and ❤️ from alpha. In the database:
   `{"👍":["…PDS5…"]}` and `{"❤️":["…JZWT…"]}`, marker `ownUserId` = alpha.
2. The app is terminated, `session.json` is removed from the group container,
   screen, `msngr.sqlite` still in place.
   right after registration: 0 messages, 0 chats, 0 members, 0 `user` rows,
   marker = gamma. The old conversation and its reactions are gone from the
   screen and from the file.
4. Gamma writes to beta in the new dialog, beta reacts 👍, gamma adds its own by
   In the database `{"👍":["…PDS5…","…EQW6…"]}` — exactly two user ids, both
   present in `member`.

## 2. Plain restart of an existing account

chat list and the dialog with alpha are intact, both reactions (👍 and ❤️)
survived. Same on A under gamma after a restart: the dialog with beta and its
`👍 2` are still there.

## 3. Logout and signing in again

container keeps only `avatars` and `Library`, while `msngr.sqlite`, `.masterkey`
and `session.json` are removed.

Signing in as the same user is not implemented in the app — registration is the
only entry point (see ROADMAP, "Sign-in and devices"): registering
`swbeta` again answers "Юзернейм занят". Registering `swdelta` on the same
device works, the chat list is empty and the marker is delta

## Not covered

- A locked screen: reading the marker fails together with opening the database
  before the first unlock, and the "keep the data, fail on open" behaviour is
  covered by a unit test only.
