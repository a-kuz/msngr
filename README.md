# Msngr

An end-to-end encrypted messenger: iOS and macOS clients over a Cloudflare
Workers backend. There is no production; this is a development stand.

## What is here

- **server/** — the Cloudflare Worker: an HTTP API (hono) and WebSocket, two
  Durable Objects (`UserDO` for a user's device sockets, chat list,
  presence and pushes; `ConversationDO` for the chat journal, membership, `seq`
  and fan-out), D1 (users, devices, prekeys, blocks, invites), R2 (media), APNs.
- **ios/MsngrKit/** — the portable core, a Swift package:
  - `MsngrCrypto` — X3DH, Double Ratchet, sender keys, media encryption, safety
    numbers;
  - `MsngrCore` — the GRDB store, the WS client, SyncEngine, the E2EE pipeline,
    media, BlurHash, album mosaics, the image pipeline.
- **ios/Msngr/** — the iOS app: SwiftUI, with the message feed on a
  UICollectionView.
- **ios/MsngrMac/** — a macOS client over the same core, handy as a second
  participant.
- **ios/NotificationService/** — the NSE, which builds a push preview from the
  shared database.

What it does: one-to-one and group chats (with roles and invite links), text,
photos, video, files, voice messages, albums, replies, forwards, reactions,
editing, deleting for yourself and for everyone, typing, online and last seen,
delivery and read ticks, message requests, pinned chats and messages, archive,
mute, drafts, search over the chat list, blocking, contact discovery by number
hashes, TOFU and safety numbers, a PIN with Face ID, and an offline send queue.
There are no calls.

## Running it

### Backend

```bash
cd server
npm install
npx wrangler d1 execute msngr --local --file=schema.sql   # once
npx wrangler dev --port 8787
```

The server smoke needs a running `wrangler dev` and covers the API, WS, the
Durable Objects and pushes:

```bash
cd server && node test/smoke.mjs
```

It raises its own push sink on :9871, so the dev APNs mock has to be stopped
first.

### iOS

```bash
cd ios
brew install xcodegen                  # if you do not have it
xcodegen generate                      # .xcodeproj is not in git, it comes from here
xcodebuild -project Msngr.xcodeproj -scheme Msngr \
  -destination 'id=<simulator UDID>' build
```

The server defaults to `http://localhost:8787` and is overridden by the scheme's
`MSNGR_SERVER` environment variable. The simulator reaches the host's localhost
directly.

### Core tests

```bash
cd ios/MsngrKit && swift test          # crypto, sync, offline, migrations, BlurHash, mosaic
```

The app tests (bubble layout, the feed, the unread banner, notification
decisions, registration validation) and the UI smoke go through xcodebuild:

```bash
cd ios
xcodebuild -project Msngr.xcodeproj -scheme Msngr -destination 'id=<UDID>' \
  test -only-testing:MsngrTests
```

The full quality gate is `make check` at the root; see `docs/PROCESS.md`.

### macOS

```bash
cd ios
xcodebuild -project Msngr.xcodeproj -scheme MsngrMac -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Msngr-*/Build/Products/Debug/MsngrMac.app
```

### Pushes on the dev stand

No Apple account is needed: `APNS_HOST` in `server/.dev.vars` sends pushes to a
mock, which delivers them into the simulator through `simctl`.

```bash
cd server && node tools/apns-mock.mjs --log        # listens on :9871
```

On a simulator the UDID (`SIMULATOR_UDID`) stands in for the APNs token. The
channel has a limit: `simctl push` does not start the Notification Service
Extension, as `docs/research/nse-simulator-experiment.md` shows.

## Deploying the backend

```bash
npx wrangler d1 create msngr           # database_id → wrangler.jsonc
npx wrangler r2 bucket create msngr-media
npx wrangler d1 execute msngr --remote --file=server/schema.sql
npx wrangler secret put APNS_KEY_P8    # contents of the .p8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_TOPIC     # the app's bundle id
npx wrangler deploy
```

## Documentation

- `CLAUDE.md` — the rules for agents working in this repository.
- `ARCHITECTURE.md` — components and principles.
- `docs/protocol.md` — the HTTP and WS protocol, the E2E envelope, pushes.
- `docs/crypto-flows.md` — first contact, TOFU, groups, contact discovery.
- `docs/ui-spec.md` — how the client behaves: the feed, the bubble, animations,
  palettes.
- `docs/PROCESS.md` — the quality gate, the state matrix, the stands.
- `docs/audits/`, `docs/qa/`, `docs/research/` — audits, runs, research.
