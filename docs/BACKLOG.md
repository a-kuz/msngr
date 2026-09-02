# Backlog

The one queue. A session with nothing assigned takes the topmost line whose
`who` is empty, writes its name there, and closes the line with the commit and
the evidence when it lands in main. Nothing else in the repository holds
open work: `ROADMAP.md` holds product status, `docs/audits/` holds the
reasoning behind a line, `docs/qa/runs/` holds the evidence.

A line is one behaviour, closed by a live run and a report. Order within a
section is the order to take. `src` names where the line came from:
`ev` — `docs/audits/2026-09-03-event-driven-and-limits.md`,
`do` — `docs/audits/2026-09-03-durable-objects-docs-check.md`,
`qa` — the defect log that lived in `docs/qa/defects.md` until 2026-09-03
(its history is in git), `q` — the former `.claude/queue.md`.

Product decisions only the owner makes are in the last section; a session
does not take those on its own.

## 1. Broken today for a reachable input

| id | line | src | who | closed |
|---|---|---|---|---|
| B3 | Push drain deletes the job after APNs answered; a second alarm shows the banner twice | do D3 | | |
| B4 | Marks migration flag is set before the migration runs; a mark read meanwhile is 0 — move it into the constructor under `blockConcurrencyWhile` | do D4 | | |
| B5 | `this.blockers` caches another object's block list in a field until eviction | do D5, ev T20 | | |
| B6 | APNs JWT remint: the gate is open across the mint, two forced remints both mint | do D6 | | |
| B7 | `StoriesDO /wipe` is `DELETE FROM`, not `deleteAll()`; the `link:` pointer objects are never wiped | do D7 | | |
| B8 | Socket close handler closes with no code and counts the closing socket as live; offline waits for the alarm | do D8 | | |
| B9 | A socket connecting mid-fan-out gets a message twice, live and in the catch-up | qa | | |
| B10 | A lost `devices` bump keeps peers encrypting to a revoked device, with only a log line | ev D5 | | |
| B11 | A member added to a chat can be missing from their chat list for good while the chat shows on screen (`notifyUserDOsChatList` is fire-and-forget) | ev D6 | | |
| B12 | Pin/mute/archive/sound, privacy, block and a direct chat's deletion do not reach the user's other devices | ev D7 | | |
| B13 | A roster frame over the socket message cap is dropped inside an empty `catch` | ev D8 | | |
| B14 | Device-link countdown runs a third fast and expires the code early | ev D9 | | |
| B15 | The chat gallery does not observe; an attachment arriving while it is open never appears | ev D10 | | |
| B16 | A severed pairwise session never heals: both sides ask, neither answer arrives | qa | | |
| B17 | The in-app banner does not react to a tap | qa | | |
| B18 | iPad with a hardware keyboard: a tap around the settings sheet crashes the app | qa | | |
| B19 | The extension's coalescing window delays every banner when pushes arrive one at a time | qa | | |
| B20 | A row moving up the chat list flies through the rows above it; a held swipe on a row stutters; interaction smoothness below Telegram | qa | | |
| B21 | A call card's title once drew over its icon after an edit | qa | | |

## 2. Writes that are lost, reads that fan out, polls (the event-driven rule)

| id | line | src | who | closed |
|---|---|---|---|---|
| B22 | One durable queue shape for every cross-object side effect now done as `Promise.allSettled` or unawaited: chat-list notify, group-add push, profile-changed, devices bump, peer-card and peer-gone, block-changed, chat-accepted, leaveRooms, indexUser, the second phoneIndexPut | ev T1 | | |
| B23 | Durable jobs for account delete and username change, with compensation | ev T2 | | |
| B24 | Frames to the user's own devices for flags, notify-sounds, privacy, exceptions, block, direct delete; a frame to contacts on phone change | ev T3 | | |
| B25 | Mute expiry and story expiry on alarms with the frame that says so; expired stories, views and likes deleted in the author's object | ev T4 | | |
| B26 | Rights as copies in the reader's object: avatar and last-seen visibility, phone discovery, calls, receipts, typing, blocks, fanned out by queue on change; `privacyAllows`, `mayView`, `peerPhoneHash`, `blockedPair` against a peer's object leave the read paths; the owner's object keeps the second check at the write | ev T20 | | |
| B27 | Profiles and avatars the same way: `/peer-card` durable, `cardsFor` gone, every frame introducing a user carries the card | ev T21 | | |
| B28 | `GET /api/chats` from per-chat state kept in the `UserDO`, paged | ev T5 | | |
| B29 | The badge as an increment on the `msg` frame summed in the `UserDO`; `totalUnread` off the push path | ev T6 | | |
| B30 | Per-member receipts/typing flags copied into the chat; `membersWithFlagOff` reads locally | ev T7 | | |
| B31 | Discovery tier stored in the phone index; `discover` answers filtered and capped | ev T8 | | |
| B32 | Provisioning approval as a held request or a socket, not a poll; `LinkDeviceView` follows | ev T9, T18 | | |
| B33 | Core: the 30-second maintenance loop replaced by deadlines and events (mutes on an alarm, the unreadable queue replayed on the unblocking arrival, `republishPrekeysIfDue` only from `recordUnreadable`, `announce` awaiting the ack) | ev T14 | | |
| B34 | Core: presence and cards in the sync answer; `refreshPresence`, `refreshPeerCanCall`, the per-user `GET /users/{id}` fan and snapshot-after-write gone | ev T15 | | |
| B35 | Core: socket watchdog armed to the next threshold, not 1 Hz; `CryptoGate` waits instead of spinning | ev T16 | | |
| B36 | App: account state (sessions, blocked, sounds, privacy, exceptions, bots, chat flags) in local tables fed by the snapshot and frames; no `load()` after an action, no pull-to-refresh | ev T17 | | |
| B37 | App: `ChatInfoView` from one prepared read; the busy-waits replaced by awaited streams | ev T18 | | |
| B38 | Smoke and MsngrTests for each of the above: a frame asserted per write, a 129-member roster, a 129-seq delete, a 32-peer unrelate, a 1000-recipient fan-out on one budget | ev T19 | | |

## 3. Cloudflare: limits and the docs' way

| id | line | src | who | closed |
|---|---|---|---|---|
| B39 | Chunk every remaining `put`/`delete`, cap `seqs`, `memberIds`/`add`, discover matches, story recipients; `limit` on every `list`; budgets for `visibleSubscribers`, `cards()`, `/search` (with a cursor), `sync`'s per-chat `/state`, `/account-wipe`, `/dev/relink` | ev T10 | partly landed as c0c614b | |
| B40 | The roster out of the `chat` frame: a paged roster endpoint, the frame carries a delta; a cap on channel size until then | ev T11 | | |
| B41 | Ping as `setWebSocketAutoResponse("ping","pong")`, freshness from `getWebSocketAutoResponseTimestamp`, `lastPing` out of the attachment; the client sends the literal `ping` | do C8 | | |
| B43 | The wanted next alarm written to storage before a drain in `UserDO` and `StoriesDO`; `alarmInfo.retryCount` read | do C7 | | |
| B44 | `this.meta` re-read inside the gate window before `journal()` writes; `this.userId` field gone | do | | |
| B45 | The `ALTER TABLE` in `try/catch` out of `StoriesDO` and the lazy marks conversion out of `ConversationDO` (a schema change wipes the stand, B59); an index on `deliveries(next_at)` | do C3, B59 | | |
| B46 | A length cap before `JSON.parse` on socket frames; `send` failures logged and the socket closed; `GET` checked on the upgrade; frames batched per catch-up portion | do C9 | | |
| B47 | `DirectoryDO` shard count in config with a resharding plan, an FTS index; location hints for `UserDO` at registration | ev T13, do C11 | | |
| B48 | `docs/protocol.md`: hibernation, auto-response, the presence trade-off; the docs check repeated after B41 and B42 | do C12 | | |

## 4. Whole features not started (ROADMAP ⬜), in the owner's order

| id | line | src | who | closed |
|---|---|---|---|---|
| B49 | Subscriptions between objects: a snapshot on subscribe (name, avatar, presence, keys, privacy) and deltas after it, unsubscribe on a removed contact or deleted chat — largely B26/B27 | q 5 | | |
| B50 | Feed extras still open: pasting an image, mentions and autocomplete | q 8 | | |
| B51 | Calls: 1:1 audio on CF Calls, encryption over insertable streams, video, group, CallKit — check ROADMAP for what already landed | q | | |
| B52 | The macOS client: media, voice, notifications, context menu parity | q | | |
| B53 | Reaction animations (the owner: not for a general-purpose agent) | STATE | | |
| B54 | `docs/protocol.md` and `docs/crypto-flows.md` translated to English | STATE | | |
| B55 | Splitting into private repositories and rewriting history in English; `.git` is ~460 MB against 368 KB of docs | STATE | | |

## 5. Decisions only the owner makes

| id | line | src | decided |
|---|---|---|---|
| B56 | Push delivery as a Go service on `sideshow/apns2`: HTTP/2 pools, one JWT per process, APNs backoff, 410 reported back; the `UserDO` queue stays the source, the relay acks on intake | do C13 | yes, 2026-09-03 — becomes a line in section 2 when a session takes it |
| B57 | Stories: whether a new direct chat after publishing hands the new peer the live stories (today the recipients are fixed at publishing, as Instagram does) | ev T22 | open |
| B58 | `compatibility_date` forward to ≥ 2026-04-07 (auto reply to close, `deleteAll` deletes the alarm) — other consequences unread | do | open |
| B59 | Schema changes on the shared stand: either the stand may be wiped on a schema change, or numbered migrations | do | yes, 2026-09-03 — wiped; the rule is in `CLAUDE.md` («The stand»), B45 follows it |
