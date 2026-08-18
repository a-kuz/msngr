# Msngr — feature map

Updated: 2026-08-17. The state of the `main` branch.

Statuses: ✅ — in the code and confirmed by a live run, a screenshot or the
server smoke test; 🟡 — partly done, or the code is there but it has not been
seen live (what is missing is in brackets); ⬜ — planned. The evidence lives in
`docs/qa/runs/`, `docs/qa/design-review/`,
`docs/qa/runs/2026-08-13-anim-review-run.md`, `docs/qa/palettes/`,
`docs/qa/push-client/` and in `server/test/smoke.mjs`.

Interface text is quoted in Russian because that is what ships.

**This file is updated as each feature closes** — in the same commit as the code.
A ✅ goes in only together with a link to the evidence.

## Onboarding and account

- Registration
  - ✅ username + display name, keys created on the device (design-review 01-onboarding)
  - ✅ name and username validation with a hint, per field (palettes/register-name-hint,
    AccountValidator units, qa/runs/2026-08-17-profile)
  - ✅ a taken username gives a clear error (smoke `username uniqueness`)
  - ✅ the disabled button reads in both appearances, 5.3:1 and 5.1:1, and does not clip
    at the largest type size (qa/runs/2026-08-17-profile)
  - ✅ the name is required everywhere, one character minimum (qa/runs/2026-08-17-profile)
- Profile
  - ✅ name, bio, avatar in settings (design-review 08-settings)
  - ✅ the avatar in chats and in the list, live to the peer and kept across a restart
    (qa/runs/2026-08-17-profile)
  - ✅ the username can be changed; the old one is released in the same statement
    (smoke `username changed`, `the old handle is free`, qa/runs/2026-08-17-profile)
  - ⬜ a card change on a device of the same account (one device per account was run)
- Sign-in and devices
  - ✅ logout: the device token is invalidated, local data is wiped
    (smoke `logout invalidates token`, qa/runs/2026-08-15-sessions)
  - ✅ a list of active devices and revoking another one; a revoked device loses its socket
    (smoke `sessions lists current device`, `revoked socket closed`)
  - ✅ the session survives a restart on a clean install (qa/runs/2026-08-15-session)
  - ✅ storage is bound to the account: a new registration wipes the container before opening the database, someone else's database is not inherited (qa/runs/2026-08-15-user-switch, StorageOwnershipTests units)
  - ✅ signing in on a new device by a code from a device already in the account
    (qa/runs/2026-08-16-second-device-run.md; smoke 21b, ProvisioningTests and
    DeviceLinkTests units)
  - ✅ multi-device: two devices of one account receive new messages, the identity
    belongs to the account, the safety number does not change
    (qa/runs/2026-08-16-second-device-run.md)
  - ⬜ moving the history to a new device (today it starts at the chat's current end)
  - ⬜ a QR code instead of typing the code (the simulator has no camera)
  - ⬜ recovering an account when no device is left
  - ✅ server: a list of active devices, logout and revoking a specific device
    (smoke `sessions lists current device`, `logout ok`, `revoked token rejected on api`,
    `revoked token rejected on ws upgrade`, `revoke device by id`)
  - ✅ revocation takes the device's keys away: a peer stops addressing envelopes
    to it and stops spending prekeys on it (smoke `a revoked device leaves the peer's device list`,
    `a revoked device hands out no more prekey bundles`)
  - ✅ client: the screen of your own devices, adding one and signing out
    (qa/runs/2026-08-15-sessions, qa/runs/2026-08-16-second-device-run.md)
- Phone and contacts
  - 🟡 the number's hash to the server, discovery over the address book (not verified live)
  - 🟡 contact access on an explicit tap, the address book name taking precedence (not verified live)
  - ⬜ inviting people who are not registered

## The chat list

- The chat row
  - ✅ avatar, name, preview, time, unread badge (design-review 02b)
  - ✅ ticks on the last outgoing message (media-run, case 32)
  - ✅ media-type previews as an icon and a caption (design-review)
  - ✅ «печатает…» in place of the preview: it goes out when the peer stops
    typing, and a message that arrives takes it down with it (qa/runs/2026-08-16-chatlist)
  - ✅ «Черновик: …» in the row, appearing and going with the field, typing
    outranking it (qa/runs/2026-08-16-chatlist; the draft itself — offline-run 5)
  - ✅ the mute icon and the pin in place of the badge, unread pushing the pin out
    (qa/runs/2026-08-16-chatlist)
- Organising the list
  - ✅ sorting: pinned on top, then by activity (qa/runs/2026-08-16-chatlist, on a
    list with two pinned chats, a request, the archive and unread)
  - ✅ swipes: archive, mute, pin, delete (qa/runs/2026-08-16-chatlist)
  - ✅ the archive section and the archive screen (qa/runs/2026-08-16-chatlist)
  - ✅ the requests section with «Принять» / «Заблокировать» swipes (qa/runs/2026-08-16-chatlist)
  - ⬜ folders and tabs
  - ⬜ animated reordering on a new message
- Search and empty states
  - ✅ local search over the chat title and the username (design-review 02c)
  - ✅ an empty list with a «Начать переписку» button (palettes/chatlist-empty)
  - ⬜ everything searched from one field: chats instantly, messages after in the
    background, people from the server; going from a result straight to the
    message in the feed. The specification is
    `docs/audits/2026-08-16-search.md`. The FTS table is in the schema and is
    filled, but nothing queries it yet

## Chat and feed

- The feed
  - ✅ an inverted list, opening at the newest messages (design-review 03-chat-full)
  - ✅ date separators «Сегодня» / «Вчера» / the date (unread-run)
  - ✅ grouping into runs: a 2/8 pt gap, a tail only on the last one (bubble-grouping, before/after screenshots)
  - 🟡 the author's name on the first message of a run in a group (not verified live)
  - ✅ pagination upwards over the local database in windows of 60; the server is
    asked only about seq gaps that are still open (pagination-run: 70 messages,
    scrolled to the very start, not a single `/history` request; HistoryWindowTests units)
  - ✅ «История начинается здесь» right at the top once the window has reached the
    oldest message on the device (pagination-run, step 4)
  - ✅ an unreadable seq: the reason and the attempt counter are written into
    `historyGap`, and the «Сообщение ещё не загружено» placeholder is shown only
    once the repair attempts are spent (qa/runs/2026-08-16-repair;
    HistoryWindowTests and MessageRepairTests units)
  - ✅ the reading position holds against incoming messages: the list is inverted,
    an insert goes into the bottom item and shifts the content above it, so an
    update remembers the topmost visible item and puts it back (the 20k run: 316
    messages arrived in 4 seconds, neither the feed nor the banner moved)
  - 🟡 keeping the position between openings of a chat: the feed lands on the
    unread banner or at the bottom, an arbitrary position is not restored
  - ✅ the scroll-down button with a badge: it appears only once the newest
    message has left the screen; the same signal drives the read receipt
    (viewing-bottom-run, cases 1–4; ViewingBottomTests units)
  - ⬜ sticky date separators
  - ⬜ sender avatars in the feed
- The unread banner
  - ✅ appearing on entry with unread messages, scrolling to the banner (unread-run, rule 1)
  - ✅ the counter growing on an incoming message, the anchor staying put (rule 2)
  - ✅ clearing on your own send and your own reaction (rule 3)
  - ✅ clearing when going to the background and a new banner on return (rules 4–5)
  - ✅ the «непрочитанное/непрочитанных сообщение/сообщения/сообщений» declension (units + a run)
  - 🟡 the banner's disappearance animation (not captured frame by frame)
- The header and the bars
  - ✅ a pinned message as a bar on top (design-review 03b)
  - ✅ an empty chat: «Напишите первое сообщение» and the encryption note (palettes/chat-empty-hint)
  - 🟡 the subtitle: «подключение…», «печатает…», «в сети», «был(а)…» (not verified live)
  - 🟡 tapping the pinned message scrolls to it (not verified live)
- Input
  - ✅ a growing field, the attachment menu «Фото или видео» / «Файл» (design-review 04, 05a)
  - ✅ a draft survives leaving the chat and a kill (offline-run 5)
  - 🟡 the reply strip and the edit mode above the field (not verified live)
  - ⬜ pasting an image from the clipboard
  - ⬜ mentions and autocomplete

## Message kinds

- Text
  - ✅ sending and receiving (every run)
  - ✅ long text and emoji (design-review)
  - ✅ mini-markdown: bold, italic, strikethrough, mono, code blocks, autolinks
    (qa/runs/2026-08-15-markdown, MarkdownTests units)
  - ✅ tapping a link opens the built-in browser, copying keeps the markup
    (qa/runs/2026-08-15-markdown)
  - ✅ selecting and copying part of the text from the menu (qa/runs/2026-08-15-multiselect, 07–08)
- Photo
  - ✅ sending, downscale to 1280 + JPEG 0.8, a preview in the feed (media-run, case 21)
  - ✅ a blurhash placeholder until the download finishes: a cold cache on the
    receiver shows blurred tiles and the sharp ones arrive 0.4 s later than in
    the same run with a warm cache (media-close-out; BlurHashTests units)
  - ✅ a caption on a photo (media-close-out, on the sender and the recipient)
- Album
  - ✅ a mosaic of 2–10 photos: 2 per row, 1+2, 2+3, 2+2+3+3 (media-close-out; AlbumMosaicTests units)
  - ✅ a shared status overlay on an album: one capsule on the bottom right tile,
    with ticks for the sender and without them for the recipient (media-close-out)
- Video
  - ✅ sending: export to 1280×720 mp4 faststart, a preview frame, the duration (media-run, case 26)
  - ✅ playing a received video and your own: the player position runs
    0.33 → 0.87 and the duration is 0:02 instead of the previous `--:--` (media-close-out)
  - ⬜ streaming over range requests instead of a full download. It runs into the
    format: the blob is sealed in a single ChaChaPoly box and integrity is
    checked by SHA-256 over the whole ciphertext, so a range cannot be decrypted
    and cannot be verified. It needs block-wise encryption and an
    `AVAssetResourceLoaderDelegate`
  - ⬜ muted autoplay in the feed
- Voice messages
  - ✅ recording by holding, the waveform, sending (design-review 06, offline-run 3)
  - ✅ playback with progress along the wave (offline-run 3)
  - ✅ a compact 220×42 bubble (BubbleLayout units, screenshots)
  - 🟡 the 0.3 s threshold and cancelling an accidental touch (not verified live)
  - 🟡 slide-to-cancel and lock (not verified live)
  - 🟡 seeking by tapping the wave (not verified live)
  - ⬜ speed ×1/×1.5/×2 (the player code is there, the button is not)
  - ⬜ playback continuing while moving between chats
- Files
  - 🟡 sending up to 100 MB with the name (not verified live)
  - ⬜ previewing a file in the app
- System messages
  - 🟡 «Код безопасности собеседника изменился» (not verified live)
  - ⬜ group events (joined, left, title changed) as separate messages
- Other
  - ⬜ contact and location
  - ⬜ stickers and GIFs

## Sending, statuses, offline

- Optimistic send
  - ✅ the message appears before the network, with the clock status (offline-run 1–3)
  - ✅ statuses: sent → delivered → read (media-run, case 32)
  - ✅ idempotency by clientMsgId (smoke `idempotent resend same seq`)
  - ✅ the ack right after the seq is assigned, before the fanout and the push (smoke `ack precedes push`, `ack while apns still hanging`)
  - 🟡 the «не отправлено» status once the attempts are spent (not verified live)
- Fanout
  - ✅ an alarm queue in ConversationDO: the cursor in storage, batches, retry until exhausted (smoke `fanout is queued, not inline`, `queue replays the whole burst`, `queue drains to empty cursor`)
  - ✅ a failing recipient does not break delivery to the rest, retry with backoff, typing is not retried (smoke `delivery survives a broken recipient`, `failed recipient gets retry`, `typing not retried`)
  - ✅ the order of a chat's frames is preserved (smoke `queue keeps frame order`)
- The offline queue
  - ✅ text, photo, voice offline → delivery after a reconnect (offline-run 1–3)
  - ✅ killing the app with something unsent: the message is still there and goes out (offline-run 4)
  - ✅ a reaction offline (offline-run 6)
  - 🟡 the service action queue: read marks, delete-for-all, accept (units, not verified live)
  - 🟡 media: the source in a permanent folder, uploaded by the worker (partly covered by offline-run 2–3)
- The connection
  - ✅ reconnect with backoff and a ceiling of 12 s (ReconnectBackoffTests units)
  - 🟡 an immediate reconnect when the network returns and from the foreground (in the run before the fix it waited 1–2 min, after the fix it was not re-checked)
  - 🟡 detecting a dead socket by a pong timeout (not verified live)
  - ✅ catch-up in portions by the client's cursor: one portion per frame, and
    between portions the object answers live traffic (smoke `catch-up goes in portions`,
    `catch-up cursor moves forward`, `live traffic is answered mid catch-up`)
  - ✅ a break in the middle of a catch-up resumes from the confirmed cursor, not
    from zero (smoke `interrupted catch-up resumes from the cursor`, units
    `CatchupCursorTests`, integration `testLongOfflineCatchesUpInPortions`)
  - ✅ replaying tombstones and read marks (smoke `sync replays tombstone`, `sync replays read mark`)

## Reply, forward, edit, delete

- Reply
  - ✅ creating one from the context menu (design-review 05)
  - 🟡 creating one by a swipe right with resistance and haptics (not verified live)
  - 🟡 rendering the quote: text on text (not verified live as a separate case)
  - 🟡 rendering the quote on a photo, video, album, voice message, file (not verified live)
  - 🟡 a quote of a deleted message: the preview is kept in the payload, the original is gone (not verified live)
  - ✅ tapping the quote → jumping to the original with a highlight, loading more of the history window
    (qa/runs/2026-08-15-reply-file-clipboard)
  - ✅ the author's name in the quote instead of the identifier, previews for media (ChatFeedTests units)
- Forward
  - 🟡 picking a chat and sending with the «Переслано от …» mark (not verified live)
  - 🟡 forwarding media and albums (not verified live)
  - ✅ forwarding several messages at once (qa/runs/2026-08-15-multiselect)
  - ⬜ forwarding while keeping the quote and the reactions
- Editing
  - 🟡 editing your own text message, the «изм.» mark (not verified live)
  - 🟡 an edit does not grow the peer's unread count (ServiceFrameTests units, smoke `service flag delivered`)
  - ⬜ edit history
- Deleting
  - ✅ delete for everyone: a tombstone on the server and a `deleted` frame (smoke `delete for all`, `tombstoned on server`)
  - ✅ confirmation before deleting; «у всех» only for your own messages (qa/runs/2026-08-15-multiselect, 03–04)
  - ✅ someone else's message is not removed for anyone by «у всех» (smoke `no fanout deleting someone else's message`)
  - 🟡 delete for me (not verified live)
  - ✅ «Сообщение удалено» in the feed for the author and for the peer (qa/runs/2026-08-15-multiselect, 05–06)
  - 🟡 a delete that arrived before the original is applied later (ServiceFrameTests units)
  - ✅ deleting several messages at once (qa/runs/2026-08-15-multiselect, 02–05)
- Clearing the history and deleting a chat
  - ✅ clearing the history for yourself, the peer keeps the conversation
    (qa/runs/2026-08-15-clear-delete-run, 04–07)
  - ✅ the cursors survive a clear: messages after it line up with no holes
    (ChatCleanupTests units, run 13–14)
  - ✅ deleting a conversation: the chat leaves your list, stays with the peer and
    comes back on their next message (run 08–12, smoke `chat comes back
    on the next message`)
  - ✅ deleting a group means leaving it (smoke `group delete leaves the group`)
  - 🟡 deleting offline: the request waits in the action queue (not verified live)

## Reactions and the context menu

- Reactions
  - ✅ setting one from the emoji row in the menu (unread-run, rule 3)
  - ✅ a capsule with the emoji and a counter under the bubble (design-review 03-chat-full)
  - ✅ a reaction made offline arrives after a reconnect (offline-run 6)
  - 🟡 removing it by tapping again and replacing your own reaction (not verified live)
  - 🟡 a double tap on the bubble = ❤️ (not verified live)
  - 🟡 capsules widen the bubble and wrap into rows (BubbleLayoutTests units)
  - ⬜ a list of who reacted
  - ⬜ particles when a reaction appears
- The context menu
  - ✅ opening on a long press: the blur, the bubble snapshot, the emoji cascade (anim-review, scenario 2)
  - ✅ closing with the bubble returning into place (anim-review)
  - ✅ items: reply, copy, select text, forward, select, pin, edit, delete (qa/runs/2026-08-15-multiselect, 01)
  - ✅ the «у меня» / «у всех» choice as a confirmation when deleting (qa/runs/2026-08-15-multiselect, 03–04)
  - ✅ forwarding from the menu opens the chat picker (qa/runs/2026-08-15-multiselect, 09–10)
  - 🟡 pinning a message from the menu (not verified live)
- Multi-select
  - ✅ entering through the «Выбрать» item, leaving by the cross (qa/runs/2026-08-15-multiselect, 02)
  - ✅ checkboxes next to the bubbles, the selected counter and the action bar (qa/runs/2026-08-15-multiselect, 02)
  - ✅ bulk delete and forward (qa/runs/2026-08-15-multiselect, 05, 10)
  - 🟡 bulk copy (no units, not captured live)

## The media viewer

- ✅ fullscreen above the header, opened from the bubble (media-run)
- 🟡 pinch zoom and a double tap 1 ↔ 2.5 (not verified live)
- 🟡 closing by a swipe down with dimming (not verified live)
- 🟡 paging through the album (not verified live)
- 🟡 sharing a file from the viewer (not verified live)
- ✅ video in the viewer (media-close-out)
- ⬜ a hero transition bubble ↔ viewer

## Marking up a picture before it is sent

Screenshot-level tools, not a photo editor: the point is to point at something.

- ⬜ the markup opens from the attachment sheet and from the viewer, over the
  picture that is already picked
- ⬜ an arrow, a line, a rectangle and an ellipse, drawn by dragging
- ⬜ freehand drawing, with a colour and a thickness
- ⬜ text on the picture with the same palette
- ⬜ blurring a region, for what should not be readable
- ⬜ cropping and rotating
- ⬜ undo and redo of every step, and leaving without saving
- ⬜ the result is a new image: the original stays untouched in the library

## E2EE, trust, privacy

- Cryptography
  - ✅ X3DH + Double Ratchet in a direct chat (CoreIntegrationTests, every live exchange in the runs)
  - ✅ media encryption: the key in the message, the blob in R2, the SHA-256 check (offline-run 2–3)
  - 🟡 sender keys in groups and rotation when a member leaves (CryptoTests units, no live group run)
  - ✅ a sender key handout is acknowledged by the recipient: an unacknowledged
    one is sent again, and a member can ask for a re-handout (MessageRepairTests
    units, CoreIntegrationTests `testGroupChatSenderKeys`)
  - ✅ /devices instead of burning a one-time prekey on every message (smoke prekey checks)
  - 🟡 one-time prekeys topped up automatically below 20 left (not verified live)
  - 🟡 the session archive and glare resolution (CryptoTests units)
  - ✅ a message that arrived before its key is replayed later (ServiceFrameTests, HistoricReplayTests units)
  - ✅ an unreadable envelope is stored whatever the reason and replayed by passes
    at start, on a reconnect and round the clock — with an attempt counter, a
    pause and a lifetime (MessageRepairTests units)
  - ✅ repair through the sender: an addressed request for a copy, an answer with
    the original msgId, up to 5 attempts with growing pauses; the pairwise
    session is rebuilt before the request (qa/runs/2026-08-16-repair;
    CoreIntegrationTests `testCorruptedSessionIsRepairedThroughSender`)
  - ✅ a skipped-key window of 5000 in the pairwise chain and in the sender key
    chain, with the skipped-key store bounded on both sides (CryptoTests units)
- Trust
  - 🟡 TOFU over all of the peer's devices (not verified live)
  - 🟡 outgoing messages blocked on a key change and a banner to accept it (not verified live)
  - 🟡 the 60-digit safety number in the chat info (not verified live)
  - ⬜ comparing by QR
  - ⬜ a "verified" mark after the comparison
- Privacy
  - ✅ blocking a user takes effect in an existing chat: a blocked user's send is
    not delivered, and the blocker gets an explicit `blocked` error instead of a
    silent "sent" (smoke `block: msg not delivered`,
    `blocker gets explicit error`)
  - ✅ creating a chat with someone who blocked you is refused (smoke `blocked direct rejected`)
  - ✅ a block takes effect in an already open chat too: a blocked user's message
    is not delivered and is not visible in the blocker's history (smoke `block: msg not delivered`,
    `block: hidden from blocker history`, `block: sync skips blocked msg`)
  - ✅ receipts and typing towards the blocker are not sent (smoke
    `block: no receipt to blocker`, `block: no typing to blocker`)
  - ✅ the blocker gets the `blocked` code on a send (smoke `block: blocker gets error code`)
  - 🟡 unblocking from the blocked list (not verified live)
  - ✅ after unblocking delivery resumes and what was hidden stays hidden
    (smoke `block: delivery resumes after unblock`)
  - ⬜ visibility settings for last seen and read receipts
  - ✅ a request's content is hidden until it is accepted: the feed, the chat list,
    the in-app banner, the badge (ChatPrivacyTests, ChatFeedTests units, request-privacy-run)

## Message requests

- ✅ before acceptance the author gets no receipts and no typing (smoke `no read receipt before accept`, `no typing before accept`; the client sends neither read nor recv for a request — unit `testMarkReadSkippedForRequestChat`, request-privacy-run)
- ✅ acceptance lifts the restriction (smoke `accept request`)
- ✅ the «… хочет вам написать» screen instead of the feed, with «Принять» and «Заблокировать» buttons (request-privacy-run)
- ✅ the requests section in the list with no preview and no counter (request-privacy-run)
- 🟡 accepting offline through the action queue (not verified live)
- ✅ the recipient's presence is not given out before acceptance over the REST profile either (smoke `no presence before accept`)
- ⬜ a push for a request with no preview: the server carries no plaintext, the NSE fills the text in from the shared database

## Presence, typing, receipts

- ✅ read receipts and counters going to zero (media-run, case 32)
- ✅ delivered receipts on recv (smoke `delivered receipt`)
- ✅ typing reaches the peer (smoke `typing`)
- 🟡 presence by ping freshness with a TTL of 35 s (not verified live)
- 🟡 «в сети» / «был(а) …» in the chat header (not verified live)
- 🟡 the typing indicator in the header and in the chat list (not verified live)
- 🟡 read on returning from the background (the code is there, no separate run)
- ⬜ aggregated read receipts in a group ("N read it")

## Notifications

- The server side
  - ✅ APNs for every content message, regardless of a live socket (smoke `push delivered despite live ws`)
  - ✅ the APNs call is awaited in the handler, without waitUntil; the sender does not wait for it (smoke `push follows its ack`)
  - ✅ no push for service frames, a muted chat and your own echo (smoke, three checks)
  - ✅ the badge from the server's unread cache, recounted after a read (smoke `push badge=1/2/after read`)
  - ✅ collapse-id = msgId, thread-id = chatId, the alert with no plaintext (smoke)
  - ✅ the dev path through the mock and `simctl push` without an Apple account (apns-mock, smoke `dev push unsigned`)
  - ✅ a 410 from APNs deletes the device token from the DO and D1 (smoke `dead token: dropped from d1`,
    `dead token: no push after drop`)
  - ✅ 429/5xx are retried with backoff, a failure on one token does not cancel the rest
    (smoke `429 retried once and succeeded`)
  - ✅ the APNs JWT lives in the storage of the `ApnsTokenDO` singleton, not in a module variable
- The client side
  - ✅ an in-app banner while the app is active (push-client/inapp-banner)
  - ✅ tapping the banner opens the chat (push-client/inapp-banner-tap-open-chat)
  - ✅ a system push is suppressed if the chat is open or the message has already been shown (push-client/push-suppressed-*)
  - ✅ a system push is shown for a new msgId (push-client/push-system-new-msgid)
  - ✅ the badge is counted by the server and stamped with a counter
    (`badgeStamp`); on the device it lives as a single row, the app and the
    extension write through a transaction, and an overtaken value is discarded
    (BadgeStoreTests, badge-run)
  - 🟡 withdrawing delivered notifications when the chat is read (not verified live)
  - 🟡 tapping a system push opens the chat (not verified live)
- A notification avalanche
  - ✅ the push carries seq and sentAt — the display order is built from them (smoke `push carries seq`, `push carries sentAt`)
  - 🟡 the coalescing window: the extension holds pushes back, plans a batch and answers by seq in a single chain
    (NotificationBurstTests, NotificationBurstGateTests units; not verified on a device)
  - 🟡 one message, one banner: the claim to show is written into the database and taken by both the app and the extension
    (NotificationBurstStoreTests units, qa/runs/2026-08-15-push-burst — the app's banner is in place)
  - ✅ the batch reaches the chat even when there were no banners (qa/runs/2026-08-15-push-burst)
  - ✅ a seq gap from a push opens a hole for the app to fill (unit `testBurstOpensTheHoleForTheApp`)
  - ✅ the extension's trace in the app group: every didReceive, answer and budget expiry
    (NotificationJournalTests units; on the simulator, 0 calls out of 30 pushes)
  - ⬜ the ceiling on extension calls during an avalanche — measurable only on a device, from the trace
- The message arrives by push
  - ✅ the push carries the envelope cut down to the device, and the sender; over
    4 KB the envelope is dropped (smoke `push carries the envelope`, `envelope trimmed to this device`,
    `oversized envelope is dropped from the push`)
  - 🟡 the extension decrypts and writes the message in the same transaction that claims the banner
    (PushMessageWriterTests units; the extension does not launch on the simulator, a device is needed)
  - ✅ the ratchet across two processes is kept apart by the gate: the position of the sending chain does not go out
    twice (CryptoGateTests units; without the gate the control run catches a repeat)
  - ✅ the same message over the socket and by push lands once, and the envelope of an already written
    message is dropped instead of repaired (PushMessageWriterTests units)
  - ✅ what the other process wrote is visible on returning to the screen
    (unit `testForegroundShowsWhatTheOtherProcessWrote`)
- The NSE and presentation
  - 🟡 previews from the shared database in the NSE (the extension does not launch on the simulator, a device is needed — docs/research/nse-simulator-experiment.md)
  - ⬜ the sender's avatar and name through Communication Notifications
  - ⬜ a group avatar in the notification
  - ⬜ quick reply straight from the push
  - ⬜ a photo preview as an image in the notification

## Groups

- ✅ creating a group and delivering a message to its members (smoke `create group`, `group message delivered`)
- ✅ an admin adding a member, a non-admin barred from removing one (smoke `admin adds member`, `non-admin cannot remove`)
- ✅ the invite link: created by a member, joining, idempotency (smoke, four checks)
- 🟡 creating a group from the interface, picking members and a title (not verified live)
- 🟡 the info screen: members, adding, removing by swipe, the link, leaving (not verified live)
- 🟡 the author's name in group bubbles (not verified live)
- ⬜ granting and revoking the admin role from the interface (the server can do it)
- ⬜ changing a group's title, avatar and description from the interface (the server can do it)
- ⬜ member rights (who can write, who can invite)
- ⬜ system messages about group events

## Channels

- ⬜ a "channel" chat kind with an explicit marker and a choice at creation
- ⬜ without E2EE: plaintext on the server, history for new subscribers
- ⬜ roles: owner, editors, readers
- ⬜ server-side search over a channel's history
- ⬜ channel media through CF Stream / Images
- ⬜ subscriber comments and reactions

## Stories

- ⬜ a story is composed from the library: several photos and videos at once, in
  the order they were picked
- ⬜ shooting a video for a story from the camera, without leaving the composer
- ⬜ text over a story: a style, a colour, a colour for the plate behind it
- ⬜ the editor from the section above works on a story frame too, so there is one
  set of tools and not two
- ⬜ publishing: who sees it, how long it lives, taking it down
- ⬜ the ring on the avatar in the chat list and the viewer with taps and holds
- ⬜ who watched it, and answering a story into the chat
- ⬜ no E2EE: a story is plaintext on the server, the way a channel is. Who may
  see it is an access rule, not a key, and the composer has to say that plainly
  before the story goes out.
- ⬜ a public link, if the creator asks for one: the story opens in a browser
  with no app and no account, so it can be shared outside msngr
- ⬜ the page behind that link: the media, the text over it, and nothing that
  identifies the audience — who watched belongs to the creator alone
- ⬜ revoking the link, and what a revoked link shows to someone who kept it

## Bots

- ⬜ a bot account: a separate kind, created and owned by a person, with a token
- ⬜ the API a bot talks over: receiving updates, sending, editing, deleting
- ⬜ commands with a list and autocomplete in the input
- ⬜ inline buttons under a message and a reply keyboard
- ⬜ a bot in a group: what it sees and what rights it needs
- ⬜ no E2EE with a bot, and the interface has to say so plainly, the way the
  channel does

## Calls

- ⬜ 1:1 audio on CF Calls, the provider behind our own protocol
- ⬜ end-to-end encryption over insertable streams
- ⬜ a video call
- ⬜ a group call
- ⬜ CallKit and PushKit

## Settings

- ✅ profile: name, bio, avatar (design-review 08)
- ✅ picking a palette from cards with instant application (palettes/live-*, settings-appearance)
- 🟡 the PIN: setting it, repeating it, checking it (not verified live)
- 🟡 Face ID and auto-lock after 30 s (not verified live)
- 🟡 the blur in the app switcher (not verified live)
- 🟡 the blocked list and unblocking (not verified live)
- 🟡 clearing the media cache with its size shown (not verified live)
- ⬜ notification settings (sound, previews)
- ⬜ language choice and localization
- ⬜ exporting and deleting the account

## Storage and data

- ✅ a single app group container for the app and the NSE (appgroup-run)
- ✅ moving the database, the key and the attachments out of Application Support while keeping the account and the history (appgroup-run)
- ✅ an interrupted move is finished on the next launch (StorageMigrationTests units)
- ✅ the GRDB schema migrator (units + live runs)
- ✅ storage is bound to the account: switching users wipes the container before
  the database is opened, and someone else's conversations and reactions are not inherited (qa/runs/2026-08-15-user-switch)
- ✅ the feed pages the local database by a seq window and goes to the server only for gaps
  (qa/runs/2026-08-15-pagination, HistoryWindowTests units)
- ✅ «История начинается здесь» instead of a placeholder for every unrecoverable message
  (HistoryFeedTests units)
- 🟡 Data Protection on the storage files (not verified on a locked screen)
- ⬜ cleaning out stale media by cache size
- ⬜ deleting messages automatically once their TTL expires (the timer is configurable and synchronized, there is no local cleanup)

- Backup to iCloud
  - ⬜ the backup itself: the history, the media and the settings, encrypted on
    the device before anything leaves it
  - ⬜ the key to the backup. Apple can read what is in iCloud unless Advanced
    Data Protection is on, so the backup carries its own key that iCloud never
    sees, and the user has to be able to get that key back on a new device —
    a passphrase or a recovery code. Undecided which; nothing else in the
    feature can be designed until it is.
  - ⬜ what the backup does NOT carry: the ratchet state and the sender keys.
    Restoring them on a second device would reuse a sending chain position, so a
    restored device starts its sessions fresh.
  - ⬜ when it runs: on a charger over Wi-Fi, with the last time shown and its size
  - ⬜ restoring during registration, and what happens when the restore is
    interrupted halfway
  - ⬜ turning it off, and deleting what is already in iCloud

## The macOS client

- 🟡 registration, the chat list, the chat, sending text (not verified live)
- 🟡 reactions and deleting a message (not verified live)
- ⬜ sending and viewing media
- ⬜ voice messages
- ⬜ notifications
- ⬜ parity with iOS on the context menu and the settings

## Performance and animations

- ✅ the outgoing bubble flying out of the input field (anim-review, frames after the fix)
- ✅ the incoming bubble rising (anim-review, frames after the fix)
- ✅ the context menu animation: the blur, the emoji cascade, the dismissal (anim-review)
- 🟡 swipe-to-reply with resistance and haptics (not verified live)
- 🟡 the reaction capsule appearing on a spring (not verified live)
- 🟡 a pointwise feed diff instead of reloadData, the layout plan cache (indirectly in the runs)
- ✅ the feed window is bounded by count while the reader is at the bottom:
    without a ceiling it grew for as long as the chat stayed open, and sending
    fell from 12 to 4 messages/s at 158% CPU (the 20k run, qa/runs/2026-08-15-20k-chat-run)
- ✅ the cost of receiving one message: the chat list was re-read by a query with
    no covering index, and a key change was read synchronously from the main
    thread; after the fix the chat list's cost fell by a factor of 81
- ⬜ measured 60/120 fps on a chat of tens of thousands of messages
- ⬜ animated reordering in the chat list
- ⬜ preloading and prefetching images along the scroll direction

## Versioning and compatibility

- ✅ the database schema version: the GRDB migrator (appgroup-run, units)
- ✅ D1 migrations: `server/migrations/` and wrangler's own runner, the schema moved
  into `0001_init.sql` (the run `wrangler d1 migrations apply msngr --local`)
- ✅ the protocol version: the client names it in the upgrade (`/ws?v=`), the
  server answers with both bounds in `hello` and `GET /api/version`, and a client
  below the floor gets 426 `client_too_old` and the «Приложение устарело» screen
  (smoke, a run on the simulator)
- ✅ the `v` field in the E2E envelope is checked by the client: an envelope newer
  than the build is stored as it arrived and is not repaired by a retry (VersioningTests)
- ✅ a schema newer than the build is neither opened nor wiped: `startOver` next to
  `wipe`/`keep`/`adopt`, and a clean start is the user's call (a run on the
  simulator, VersioningTests)

## Up next

From the open backlog (`docs/audits/2026-08-12-code-audit.md`, 37 items) and the
topics still not closed:

1. The badge from one source with a monotonic order, a queue in the dev APNs
   mock (in progress).
2. Reaction animations: particles on appearance, a rolling counter (waiting for a
   model that can debug animation frame by frame).
3. The media gallery, chat folders.
4. The NSE on hardware: the extension comes up, fits into the limits, sees the
   group container; the same run checks that what was read in the banner is in
   the chat in airplane mode, and measures the call ceiling during an avalanche —
   on the simulator `simctl push` does not launch the extension at all.
5. English across the whole repository: documentation, comments, commit history;
   an interface string catalog with English as the base language.
6. Working through the remaining audit items in order: crashes and data loss →
   offline reliability → E2EE edge cases → UI.
