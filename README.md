<p align="center">
  <img src="docs/media/icon.png" width="96" alt="Msngr">
</p>

<h1 align="center">Msngr</h1>

<p align="center">End-to-end encrypted messenger. Swift clients for iOS and macOS, Cloudflare Workers backend.</p>

<table align="center"><tr>
<td><img src="docs/media/demo-1.gif" width="320" alt="A message arrives, a row swipe, a reaction, the context menu"></td>
<td><img src="docs/media/demo-2.gif" width="320" alt="A photo and a video sent as an album, a message request accepted"></td>
</tr></table>

<p align="center">
  <a href="https://github.com/a-kuz/msngr/raw/main/docs/media/demo.mp4">Full video, 60 fps</a>
</p>

## Features

- Direct and group chats, roles, invite links, message requests
- Text, photos, video, files, voice, albums, replies, forwards, reactions, edits, pins, disappearing messages
- Folders, pinned chats, archive, mute, drafts, search
- X3DH + Double Ratchet, sender keys for groups, encrypted media, safety numbers, PIN with Face ID
- Push notifications decrypted on the device by the extension

No calls.

## Screens

<table align="center"><tr>
<td><img src="docs/media/screens/list.png" width="200" alt="Chat list"></td>
<td><img src="docs/media/screens/chat.png" width="200" alt="Chat"></td>
<td><img src="docs/media/screens/reactions.png" width="200" alt="Reactions"></td>
</tr><tr>
<td><img src="docs/media/screens/profile.png" width="200" alt="Profile"></td>
<td><img src="docs/media/screens/settings.png" width="200" alt="Settings"></td>
<td><img src="docs/media/screens/folder.png" width="200" alt="New folder"></td>
</tr></table>

## Stack

```
server/                  Cloudflare Worker: hono, WebSocket, Durable Objects, D1, R2, APNs
ios/MsngrKit/            Swift package: MsngrCrypto (X3DH, Double Ratchet, sender keys), MsngrCore (GRDB, sync, E2EE)
ios/Msngr/               iOS app: SwiftUI, UICollectionView feed
ios/MsngrMac/            macOS client on the same core
ios/NotificationService/ push decryption and preview
```

## Run

```bash
cd server && npm install && npx wrangler d1 execute msngr --local --file=schema.sql && npx wrangler dev --port 8787
cd ios && xcodegen && xcodebuild -project Msngr.xcodeproj -scheme Msngr -destination 'id=<simulator UDID>' build
```

Tests: `cd ios/MsngrKit && swift test`, `cd server && node test/smoke.mjs`, `make check`.

## Docs

[Architecture](ARCHITECTURE.md) · [Protocol](docs/protocol.md) · [Crypto flows](docs/crypto-flows.md) · [UI spec](docs/ui-spec.md) · [Process](docs/PROCESS.md)

Demo footage: [Mixkit](https://mixkit.co/license/), photos: [Picsum](https://picsum.photos/).
