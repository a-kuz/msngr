# UserDO: identity, prekeys and the device list leave D1

Step 1 of the per-user-DO rework (`docs/research/2026-08-19-per-user-do.md`):
the identity keys with their signatures, the signed prekeys, the one-time
prekeys and the E2EE device list moved from the shared D1 file into the user's
own Durable Object, addressed by `env.USER_DO.idFromName(userId)`. The prekey
handout — a read that deletes — now runs serialized inside the object, so two
senders never draw the same one-time key.

Run date: 2026-08-21, branch `run-userdo`.

## The change

- `UserSessionDO` is renamed `UserDO` (wrangler DO migration `v3`,
  `renamed_classes`): with the keys in it, the object is the user's, not the
  session's. The decision to join the existing object instead of adding a
  second per-user one is argued in the research doc.
- The object stores `ik:<deviceId>` (identity + signed prekey),
  `otp:<deviceId>:<keyId>` (one-time prekeys, padded so storage order is
  numeric id order — the handout consumes the lowest id first) and
  `devicesVersion`.
- Registration and the provision claim write the keys into the object before
  the D1 rows: a lost username race leaves unreachable storage, while the
  reverse order would burn the username on a failed keys write.
- Link and revoke bump `devicesVersion` and fan the `devices` frame out from
  inside the object; the worker's `broadcastDevices` and the `/devices-changed`
  route are gone. The `sync` frame's `deviceVersions` reconciliation asks each
  named user's object (`/keys-version`) instead of one D1 `IN (...)` query; a
  user no object knows is left out of the answer, same as a user with no row
  was before.
- D1 keeps `users` and `devices`: auth resolves a bearer token by
  `devices.token_hash`, a global lookup no per-user object can answer.
  `identity_keys`, `one_time_prekeys` and `users.devices_version` are no longer
  written or read; the tables are dropped in a later step.
- The API surface is unchanged: every moved endpoint answers the same shape.
- `msngrfixture answer` is new: a headless peer that opens a fixture account,
  waits for an incoming text and answers through the real engine — a
  one-simulator scenario no longer needs a second device to receive a reply.
- The dev perf line for HTTP requests now carries `d1`, the count of D1
  statements the request ran (worker level; the DO counters already existed).

## D1 statements per request, before and after

Measured on the own stand (`PERF_LOG=1`, port 8803) by running
`node test/smoke.mjs` against the code before and after the move; the live
simulator run showed the same after-numbers. One D1 statement per request is
auth (`devices.token_hash`); it is the hot path's last D1 read and moves out
with a later step.

| Request                     | before | after |
|-----------------------------|--------|-------|
| `POST /api/register`        | 6      | 3     |
| `GET /api/users/:id/prekeys`| 4      | 1     |
| `GET /api/devices`          | 3      | 1     |
| `POST /api/identity`        | 2      | 1     |
| `GET /api/prekeys/count`    | 2      | 1     |

The first message to a new peer costs `GET /api/devices` +
`GET /api/users/:id/prekeys`: 7 D1 statements before, 2 after, and the two
left are both auth. Register was measured with the smoke's 2 one-time prekeys;
a real client uploads ~30–100, each of which was one more D1 insert before and
is part of one batched storage write now.

## Verified

- `node test/smoke.mjs` against the own stand: **ALL PASS**, twice (baseline
  before the move, full run after). New checks in the link/revoke section:
  linking answers `versions[user] = 2` and revocation `3` in `/api/devices`,
  and a `sync` frame with `deviceVersions` gets the current version back while
  a never-registered user id is absent from the answer.
- `cd server && npm run typecheck`: clean.
- Live run on one simulator (`userdo`, iPhone 17) against the own stand
  (`wrangler dev --port 8803`): registered a fresh user `userdo_live` through
  the UI (register cost `d1:3`), seeded the alfa/bravo/charlie trio on the
  same stand with `msngrfixture seed --base http://localhost:8803` (three real
  cores, prekey handouts and first messages all through `UserDO`), found
  `Alfa Service` in global search, sent the first message; the headless
  `msngrfixture answer` peer received it, accepted the chat and answered. The
  reply decrypted and readable in the app, the outgoing message shows the read
  tick, presence shows «был(а) только что». Zero unreadable messages.

## Not done

- `HandleDO` and the username claim, subscriptions between objects, delivery,
  the journal: later steps by the research doc's order.
- Auth still reads D1 on every request; the leftover key tables are dropped in
  the step that moves it.
