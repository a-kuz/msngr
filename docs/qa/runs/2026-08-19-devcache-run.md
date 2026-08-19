# Device list cache on the send path

`E2EEManager.deviceMap` asked the server for the recipients' devices on every
outgoing message: ten messages in a row cost ten `GET /api/devices` reads of
rows that had not changed. This run put the list in a cache, gave the server a
way to say it changed, and proved both directions live on two simulators.

Run date: 2026-08-19.

## The change

- The server broadcasts `{t:"devices", userId}` when a device is linked
  (`/api/provision/:id/claim`) or revoked (`revokeDevice`, so logout and
  session revocation both). The frame travels the profile road: out through
  `UserSessionDO /devices-changed` to the user's own sockets and through every
  `ConversationDO` they are in to the peers.
- `E2EEManager` keeps device lists in memory. A send reads from the cache and
  asks the server only for the users it is missing; the `devices` frame drops
  one user's entry, a reconnect drops them all — a frame sent while the socket
  was down is gone. The extension never encrypts, and a fresh process starts
  empty, so nothing crosses processes.
- `APIClient` counts its `/api/devices` hits; the cache tests assert on it.
- `docs/protocol.md` names the frame and the revocation paragraph now says the
  cache is dropped by the broadcast, not re-read per send.

## Red, then green

`DeviceCacheTests.testTenSendsShareOneDevicesRequest` (MsngrKit, against the
own stand): with the cache bypassed, ten sequential sends made **10** requests
— the assert failed with `10 != 1`. With the cache in place the same test is
green: **1** request. `testLinkedDeviceReachesSenderWithoutReconnect` covers
the frame end to end at the core level: a second device linked over the real
provisioning flow reaches the sender with no reconnect, the message lands on
the fresh device, a revocation narrows the list back to one — all on one
socket session.

## Stand

Own `wrangler dev` on :8845 with `--persist-to .claude/stand-devcache`, APNs
host pointed at :9885, the three D1 migrations applied into it. The shared
stand on :8787 was not touched. Two own simulators, iPhone 17, iOS 26.5,
deleted after the run:

- `devcache-a` (18119AE6) as `devcachea` / Ann — the sending side,
- `devcache-b` (2D27567B) as `devcacheb` / Bob — the receiving side.

## The live run

Ann sent ten messages in a row from the app. The stand log for that window
holds exactly one `GET /api/devices` (plus one prekey bundle for the first
session); Bob received all ten, none unreadable.

Then Bob linked a second device without either app restarting. The linked
device was played by an env-gated driver
(`LiveLinkDriverTests`, `MSNGR_LIVE_LINK=1`): it opened the provisioning
session and reported the code through a file — stdout under a pipe is
block-buffered, which had already cost one expired code — the code was typed
into Bob's «Добавить устройство» screen, and the claim broadcast the frame.
Ann's next message, sent from the UI with no restart, reached the fresh device
over a new X3DH session: the driver saw the row and logged
`LIVE-LINK B2 RECEIVED the message`.

The driver then logged out, which is the revocation road. Bob's devices screen
dropped to one device, and Ann's next message re-read the list once and went
out addressed to that one device; Bob received it. A stand restart happened in
between (its temp bundle had been swept while the run was paused), which also
exercised the reconnect path: the cache is dropped, the first send after the
link re-reads once.

## Gate

`make check DEV_UDID=18119AE6…` with `MSNGR_TEST_BASE=http://localhost:8845`,
so the core integration tests run against the stand that already speaks the
`devices` frame; the server smoke raises its own clean stand from this working
tree as always.
