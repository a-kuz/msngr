# Storage moves into the app group container: a live upgrade

Date: night of 2026-08-14 into 2026-08-15. Agent stand: simulators `appgroup-a2`
(29841E7E, user `agsender2`) and `appgroup-b2` (FA80F7EF, user `bobby22`), own
`wrangler dev` on :8793 with a separate `--persist-to`. Simulators deleted after
the run.

## What was checked

The installed build without the entitlement keeps the database and `.masterkey`
in Application Support. A build with the entitlement resolves paths from the
group container. An upgrade over an already installed build must not look like a
clean install: the account, the history and the ratchet sessions have to survive
the move.

## Before the migration

Build from commit 11aaba7, no entitlement yet. Two users, a chat with three
messages in both directions, decryption and read ticks working.

```
Application Support: .masterkey  media-outgoing/  msngr.sqlite  msngr.sqlite-shm  msngr.sqlite-wal  session.json
$ xcrun simctl get_app_container 29841E7E… ai.enface.Msngr groups
(empty)
md5 .masterkey = 2360c33147fa0bf683c97daa44775061
userId = 01M0116XAC707HC9N6CJSPNEZS
```

## The upgrade

`xcrun simctl install` on top, without deleting the app. installd creates the
group container at install time:

```
group.ai.enface.msngr  …/data/Containers/Shared/AppGroup/1792FEB3-…
```

After the first launch of the new build:

```
group:               .masterkey  avatars/  media-outgoing/  msngr.sqlite  msngr.sqlite-shm  msngr.sqlite-wal
Application Support: session.json
md5 .masterkey = 2360c33147fa0bf683c97daa44775061   (the same file)
select count(*) from message = 3                    (the whole history)
```

## After the migration

Same account (`agsender2`, userId unchanged), history in place. New messages
were exchanged both ways: `Posle migracii A` goes out and decrypts at bobby22,
the reply arrives and decrypts at agsender2. Ratchet state and identity survived
the move: a changed master key would have broken decryption, and a changed
identity would have shown the peer a key change warning.

A second launch migrates nothing again. The database stays the same one (5
messages) and the chat list is unchanged.

## Tests

- `swift test` in MsngrKit: 53 tests, 8 of them on the storage move.
- MsngrTests on the agent's simulator: 48 tests.
- Building Msngr for the simulator: BUILD SUCCEEDED.
- `scripts/collect-crashes.sh --since 60`: no crashes.

## What stayed unchecked

The file protection class (`completeUntilFirstUserAuthentication`) cannot be
checked on a simulator: Data Protection is not implemented there, so neither the
fact that the attribute is applied nor access to the database with the screen
locked can be reproduced. To be checked on a device.
