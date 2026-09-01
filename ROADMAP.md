# Msngr — feature map

Updated: 2026-09-01. The state of the `main` branch.

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
  - ✅ a card change on a device of the same account: a second device joined by
    code, the rename on the first showed up on the second with no action there
    (qa/runs/2026-09-01-second-device.md)
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
  - ✅ recovering an account when no device is left: restoring from the
    sealed backup during registration — the identity outlives its devices in
    `UserDO`, the claim proves possession of the identity key (the Backup
    section below; smoke `restore: start with zero devices`, live run
    2026-08-30)
  - ✅ server: a list of active devices, logout and revoking a specific device
    (smoke `sessions lists current device`, `logout ok`, `revoked token rejected on api`,
    `revoked token rejected on ws upgrade`, `revoke device by id`)
  - ✅ revocation takes the device's keys away: a peer stops addressing envelopes
    to it and stops spending prekeys on it (smoke `a revoked device leaves the peer's device list`,
    `a revoked device hands out no more prekey bundles`)
  - ✅ client: the screen of your own devices, adding one and signing out
    (qa/runs/2026-08-15-sessions, qa/runs/2026-08-16-second-device-run.md)
- Phone and contacts
  - ✅ the number's hash to the server, discovery over the address book: the
    number is set in the settings, normalized to E.164 and hashed on the
    device; the raw number never leaves it
    (qa/runs/2026-08-27-phone-discovery-run; PhoneTests units)
  - ✅ contact access on an explicit tap, the address book name taking
    precedence (qa/runs/2026-08-27-phone-discovery-run: «Boris Bravov» shown
    over the profile's «Bravo Service»)
  - ✅ inviting people who are not registered: the numbers discovery could
    not match get their own section in the new chat sheet, each row opening
    the share sheet with an invite text carrying the sender's handle
    (qa/runs/2026-09-01-invite-unregistered.md)

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
  - ✅ folders and tabs: a rule plus chats put in and taken out by hand, the
    manual exclusion winning over the rule, the tab with its own unread badge
    switched by a long horizontal swipe, and deletion leaving every chat in
    place (qa/runs/2026-08-21-folders; unit-covered in ChatFolderTests)
  - ✅ animated reordering on a new message: the row glides to the top through
    the rows above it instead of teleporting (qa/runs/2026-08-21-chatlist-reorder)
  - ✅ a chat with yourself for saved messages, first in the list and never a
    push; forwarding into it from any chat (qa/runs/2026-08-27-saved-messages;
    smoke `self chat created` … `self chat lists its one member`)
- Search and empty states
  - ✅ local search over the chat title and the username (design-review 02c)
  - ✅ an empty list with a «Начать переписку» button (palettes/chatlist-empty)
  - ✅ everything searched from one field: chats instantly, messages over the
    FTS table with the match highlighted, people from the server, and a hit
    landing the feed on the message mid-history
    (qa/runs/2026-08-21-unified-search; the specification is
    `docs/audits/2026-08-16-search.md`)

## Chat and feed

- The feed
  - ✅ an inverted list, opening at the newest messages (design-review 03-chat-full)
  - ✅ date separators «Сегодня» / «Вчера» / the date (unread-run)
  - ✅ grouping into runs: a 2/8 pt gap, a tail only on the last one (bubble-grouping, before/after screenshots)
  - ✅ the author's name on the first message of a run in a group, in per-name
    colours (qa/runs/2026-08-21-presence-names)
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
  - ✅ keeping the position between openings of a chat: the seq at the visual
    top is stored on leaving and restored on entry, the bottom clears it, and
    the unread banner and search jumps outrank it
    (qa/runs/2026-08-27-reading-position-run.md; ReadingPositionTests units)
  - ✅ the scroll-down button with a badge: it appears only once the newest
    message has left the screen; the same signal drives the read receipt
    (viewing-bottom-run, cases 1–4; ViewingBottomTests units)
  - ✅ sticky date separators: the current day's capsule floats under the header
    while the reader scrolls, yields to the real separator cell at a day
    boundary and fades once the scrolling stops (2026-08-21-feedextras run;
    FeedExtrasTests units)
  - ✅ sender avatars in the feed: in groups an incoming run reserves the
    avatar column and the run's last message carries the picture; direct chats
    stay clean (2026-08-21-feedextras run; FeedExtrasTests units)
- The unread banner
  - ✅ appearing on entry with unread messages, scrolling to the banner (unread-run, rule 1)
  - ✅ the counter growing on an incoming message, the anchor staying put (rule 2)
  - ✅ clearing on your own send and your own reaction (rule 3)
  - ✅ clearing when going to the background and a new banner on return (rules 4–5)
  - ✅ the «непрочитанное/непрочитанных сообщение/сообщения/сообщений» declension (units + a run)
  - ✅ the banner's disappearance captured frame by frame: it leaves in a
    single frame together with the send's jump to the bottom, where no
    separate animation would be visible (qa/runs/2026-08-27-banner-dismiss-run.md)
- The header and the bars
  - ✅ a pinned message as a bar on top, its tap flashing the message, «Открепить»
    over the pinned one (design-review 03b; header-run)
  - ✅ an empty chat: «Напишите первое сообщение» and the encryption note (palettes/chat-empty-hint)
  - ✅ the subtitle: «подключение…», «печатает…», «в сети», «был(а)…», «N участников»
    (header-run, two devices)
  - ✅ tapping the pinned message scrolls to it, including a message a thousand
    behind the newest (pin-depth-run)
  - ✅ several pinned messages at once: the bar counts them with a segmented
    rail, tapping walks through them with a wrap, and a list opens all of
    them with per-pin unpinning (qa/runs/2026-08-21-multipin; smoke pin
    checks, MultiPinTests units)
  - ✅ a jump to a date: a tap on a date separator or the floating day capsule
    opens the calendar over the local history, and picking a day lands the
    feed on its first message (qa/runs/2026-08-21-date-jump)
- Input
  - ✅ a growing field, the attachment menu «Фото или видео» / «Файл» (design-review 04, 05a)
  - ✅ a draft survives leaving the chat and a kill (offline-run 5)
  - ✅ the reply strip and the edit mode above the field, cancel returning the
    draft (header-run)
  - ✅ pasting an image from the clipboard: the attachment menu offers «Вставить»
    when the pasteboard holds one, the system paste gesture lands it as an
    attachment, and it goes out as a photo message
    (qa/runs/2026-08-15-reply-file-clipboard)
  - ✅ mentions and autocomplete: the panel above the field on an open
    "@prefix", a tap inserts the handle, sending resolves it into the mention
    token by the chat's members (qa/runs/2026-08-28-mention-token;
    tokenizeMentions in MentionMarkdownTests)
  - ✅ sending at a chosen time: the message waits in the outbox, the chat shows
    what is queued for when, and it can be edited, rescheduled, sent now or
    cancelled before it leaves (qa/runs/2026-08-30-scheduled-send;
    ScheduledSendTests)
  - ✅ a send that survives a killed app and a cold start at the appointed time
    (the same run: killed before the deadline, launched after it, the message
    left on its own)
  - ✅ leaving on time with the app backgrounded, killed or the phone off:
    a deferred envelope. The device encrypts at scheduling time exactly as a
    normal send would and hands the server the ciphertext with the moment it
    is due; at that moment the ConversationDO journals it as an ordinary
    message (the seq is assigned then) and fans it out. The server learns
    what it learns of any message — ciphertext and size — plus the fact and
    time of the deferral; cancel, reschedule and edit before the deadline
    are a delete or replace of the stored envelope. The late delivery rides
    the ratchet's skipped-message keys; a recipient device enrolled after
    scheduling cannot open it and heals through the usual repair path. The
    author who is offline at the deadline learns the outcome from the echo:
    msg frames carry the clientMsgId on every transport, and the row closes
    from the journal when the `sent` ack found no live socket.
    (Cloud-plaintext messengers schedule on the server; E2EE ones either
    lack the feature or send from the device — this keeps E2EE and the
    server's reliability at once; qa/runs/2026-08-31-deferred-envelope,
    ScheduledSendTests, the defer block in smoke)

## Message kinds

- Text
  - ✅ sending and receiving (every run)
  - ✅ long text and emoji (design-review)
  - ✅ mini-markdown: bold, italic, strikethrough, mono, code blocks, autolinks
    (qa/runs/2026-08-15-markdown, MarkdownTests units)
  - ✅ tapping a link opens the built-in browser, copying keeps the markup
    (qa/runs/2026-08-15-markdown)
  - ✅ selecting and copying part of the text from the menu (qa/runs/2026-08-15-multiselect, 07–08)
- A link in the text
  - ✅ a preview card under the message: the title, the description and the
    picture. The server never sees the plaintext: the sender's client fetches
    the page (Open Graph tags, the <title> fallback) and carries the card
    inside the encrypted message; the receiver renders, never fetches
    (qa/runs/2026-08-30-link-preview-run.md; LinkPreviewTests,
    LinkCardLayoutTests)
  - ✅ the sender decides: the strip over the composer shows the card with a
    cross that sends the link bare, and the «Превью ссылок» toggle in Privacy
    keeps the client from fetching pages at all (same run; the toggle is local
    to the device)
  - ✅ the picture of the card travels like any other media, encrypted through
    R2, uploaded by the outbox worker alongside the message (same run: the
    thumbnail arrived on the peer with no request to the page's host)
- Mentions
  - ✅ a mention in the text renders as a link and its tap opens the direct
    chat with that person; the token carries the userId, previews and
    notifications show the visible name (qa/runs/2026-08-28-mention-token;
    MentionMarkdownTests)
  - ✅ your own mention is marked: an «@» circle next to the unread badge on
    the chat row, and an accent wash under the bubble in the feed
    (qa/runs/2026-08-28-mention-token; MentionMarksTests, MentionWashTests)
  - ✅ a counter of unread mentions and a jump to the earliest one: the «@»
    button above the way down, its tap lands the feed on the earliest unread
    mention (qa/runs/2026-08-28-mention-token; MentionMarksTests)
  - ✅ a mention survives a rename: it carries the userId, not the handle
    (qa/runs/2026-08-28-mention-rename-run)
  - ✅ «@все» in a group: the token addresses every member, only an admin gets
    it offered and it pierces the mute like a personal mention; its tap leads
    nowhere (qa/runs/2026-08-28-mention-token; ChatSettingsTests
    `canMentionAll`, MentionMarkdownTests, MentionMarksTests)
- Photo
  - ✅ sending, downscale to 1280 + JPEG 0.8, a preview in the feed (media-run, case 21)
  - ✅ the bubble is in the feed the moment of the confirm tap — placeholder in
    its frame first, tiles resolving as preparation finishes, the outbox waiting
    for the file, no rollback on any path (media-appears-on-send run: ~2 s to
    the bubble for a 5-photo album and for a video)
  - ✅ photos and videos picked together go as one album, the row appears before
    the library hands over a byte, and every tile wears a ring with the percent
    of its transcode and upload until the ack (qa/runs/2026-08-27-video-album)
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
  - ✅ muted autoplay in the feed: a video whose file is on the device loops
    in place without sound and without stopping the user's music; one that
    would need a download keeps the preview and the glyph
    (qa/runs/2026-08-21-video-autoplay)
- Voice messages
  - ✅ recording by holding, the waveform, sending (design-review 06, offline-run 3)
  - ✅ playback with progress along the wave (offline-run 3)
  - ✅ a compact 220×42 bubble (BubbleLayout units, screenshots)
  - ✅ the 0.3 s threshold and cancelling an accidental touch (voice-run)
  - ✅ slide-to-cancel and lock (voice-run)
  - ✅ seeking by tapping the wave (voice-run)
  - ✅ speed ×1/×1.5/×2, kept between messages (voice-run)
  - ✅ playback continuing while moving between chats (voice-run)
  - ✅ a take interrupted by the screen or the app going away is dropped (voice-run)
  - ✅ a transcript of a voice message on demand, on the device: the Aa button
    by the waveform recognizes locally (SpeechAnalyzer, or SFSpeechRecognizer
    pinned on-device for languages the new models lack — Russian among them),
    caches the result, unfolds it under the wave, and playback underlines the
    words as they are spoken (qa/runs/2026-08-31-voice-transcript; confirmed
    by the owner on a device, 2026-08-31)
- Round video messages
  - ✅ recording from the front camera by holding, the same gesture as a voice
    message, with slide-to-cancel and lock; a tap flips microphone ↔ camera,
    persisted device-wide (qa/runs/2026-08-31-round-video; the simulator has
    no camera, capture itself verified on the owner's device)
  - ✅ a round bubble in the feed, playing without sound until it is tapped;
    the tap gives it sound, a swell and a progress ring
    (qa/runs/2026-08-31-round-video, RoundVideoTests)
  - ✅ playback continuing in a small circle while the reader scrolls away;
    tapping the dock returns to the bubble (qa/runs/2026-08-31-round-video)
  - ✅ notes play one after another: a finished voice or circle starts the
    next unheard incoming note (RoundVideoTests chain cases, live two-sim run)
  - ✅ listened marks: the sender sees who started playing a voice or circle —
    a dot for someone, a second dot in groups under 15 for everyone; the
    event travels encrypted as a service frame (NoteListenedTests, live run)
- Files
  - ✅ sending up to 100 MB with the name: a 99.6 MB file sent from the Files
    app, acked and stored as one encrypted blob on the stand
    (qa/runs/2026-08-27-file-100mb-run.md)
  - ✅ previewing a file in the app: QuickLook over the decrypted cache, a
    spinner for the long fetch, unreadable types going to the share sheet
    (qa/runs/2026-08-21-file-preview, a 98.9 MB PDF of 642 pages)
- Polls
  - ✅ creating one: the question, two to ten options, single or multiple
    choice (the run 2026-08-31-poll)
  - ✅ voting, the result as a share of the votes with animated bars,
    retracting a vote, and revoting — every tap sends the voter's whole
    current choice, so a replay lands the same state (PollTests, the run)
  - ✅ anonymity: the flag hides the voters everywhere, only the shares and
    the count show. The count is counted on every device from the encrypted
    `pollVote` events, not by the server — the server is E2EE-blind, so a
    server-side count would mean plaintext votes; anonymity is a display
    promise, the events always name their sender (the really-anonymous line
    below lifts that). A non-anonymous poll shows its voters: the footer of
    a poll with earned results opens a sheet grouped by option, names and
    avatars (PollVotersTests, live on the alfa fixture 2026-08-31)
  - ⬜ really anonymous polls: the vote of an anonymous poll carries a
    per-poll pseudonym — an HMAC of the account key over the poll id —
    instead of the voter's name, so even a modified client of a member
    cannot tell who chose what; the pseudonym stays stable across the
    account's devices, which keeps replace-and-retract and one-person-one-vote
    working. The server envelope still names the sender for routing: hiding
    the voter from the server too would take blind signatures and a mix, and
    in a three-member group the anonymity set is small whatever the crypto
- System messages
  - ✅ «Код безопасности собеседника изменился» inserted into the feed on a
    real key change (qa/runs/2026-08-27-key-change-run.md)
  - ✅ group events (left, title, photo, description, the admin role) as separate
    messages, worded for the actor, for the member it touches and for everyone else
    (qa/runs/2026-08-17-groups-run)
- Shaders (user code, the Shadertoy dialect of GLSL, transpiled to MSL on the
  device; design in `docs/plans/2026-08-28-shader-messages-design.md`). The
  product here is the procedural format under stickers, effects, backgrounds
  and avatars: a document weighs kilobytes, draws at any size and reacts to
  the finger, the clock and the theme. The shader message with the code in the
  composer is the owner's debugging tool, not a scenario for users
  (the owner, 2026-08-28).
  - ✅ a peer's document reads no sensor. In the feed a document that came
    from the peer gets time, touch and the palette only; the sensors, the
    microphone, the cameras and the location open for the stickers of the
    user's own pack (adding a sticker is the act of trust), for the user's
    own surfaces and in the full-screen player the user opened — a denied
    feed reads as zeros and an empty channel texture
    (`ShaderRenderer.deviceInputs`; run live 2026-08-28: an incoming shader
    message and sticker reading the camera, the location and the gyroscope
    started no feed and raised no prompt in the feed, and opening the player
    turned motion, location and the camera on and closing it turned them
    off — qa/runs/2026-08-28-shader-sensor-isolation-run.md)
  - ✅ the shader composer behind a switch in Settings → «Шейдеры»: off by
    default, the «Shader» and «Bubble shader» items leave the attachment
    menu; the sticker panel, the backgrounds, the avatar and the effects
    keep their own composer entries, and a received shader message still
    opens in the player and keeps its previews
    (`ShaderSurfaces.composerEnabled`; run live 2026-08-29: the menu
    without and with the entries, the panel's own «+» opening the
    sticker composer under the switch off —
    qa/runs/2026-08-29-shader-composer-toggle-run.md)
  - ✅ a drawable scale setting in Settings → «Шейдеры»: «Половинное
    разрешение в чатах» halves the drawable of the feed, the chat list and
    the backgrounds; the player, the composer preview and the effects stay
    at full scale (`ShaderSurfaces.halfScale`; run live 2026-08-28:
    540×540/915×513 → 270×270/457×256 in the feed while the player kept
    1206×2622 — qa/runs/2026-08-28-shader-half-scale-run.md). What half
    scale buys in frame time and thermal state is still a device question:
    the simulator says nothing about either
  - ✅ a shader message: Shadertoy code or a JSON export pasted into the
    composer, a live preview, the bubble animating in the peer's feed, a
    full-screen player with touches as `iMouse` and the source to copy;
    multipass (Image + Buffer A–D, a pass reading its own previous frame)
    (qa/runs/2026-08-28-shader-messages-run; ShaderTranspilerTests compile the
    emitted MSL, including the owner's 300-line sample)
  - ✅ a shader as the chat background, and «Set as background» from a
    received shader message; local, no sync (`ShaderSurfaces`, the chat
    info's «Фон» section, the message menu; seen by the owner 2026-08-28)
  - ✅ a shader behind a text bubble, chosen by the sender (`bubbleShader`
    on a text message, the strip over the input field, white text under a
    shadow in the cell; seen by the owner 2026-08-28)
  - ✅ a shader avatar, seen by the peers (the document as the avatar blob,
    told from a picture by the first byte; chat list, feed and info draw it
    live under the budget; run live 2026-08-28: set from charlie's Settings,
    live on alfa's chat list and in charlie's own Settings)
  - ✅ shader stickers: a transparent bubble that honours `O.a`, a local pack
    keyed by the hash of the document, «В стикеры» on a received one. The
    document travels inline in every sticker message: a reference the
    receiver might not hold would be an unreadable message. A sticker keeps
    its touches, so it can react to a tap; the pack starts with two bundled
    ones, Heart (beats when tapped, state in a buffer texel, the beat on the
    haptics) and Sparkle (seen live on the simulator: the pack, a send, the
    feed, taps on the heart; `BundledStickersTests` compile both)
  - ✅ shader effects on events: the send burst and the reaction burst, two
    bundled shaders the user replaces from Settings → «Шейдеры» (run live
    2026-08-28: sparks out of the send button, confetti out of a bubble a
    reaction landed on; qa/defects.md holds the reaction path that was silent)
  - 🟡 the device as input, each a uniform or a channel texture (the uniform
    block and the feeds are built, `ShaderTranspilerTests` compile a shader
    reading every one; seen live on the simulator: a tap through `iMouse`, the
    palette and `iDark` following the appearance switch; the sensors, the
    microphone, the cameras, the keyboard, the Pencil and the haptics need a
    device to be seen moving): multitouch
    (`iTouch[5]` with pressure), gyroscope, accelerometer, magnetometer and
    the attitude quaternion, the microphone as an FFT and waveform texture
    (Shadertoy's Music/Mic channel), the cameras as a channel texture,
    compass heading and GPS, barometer, proximity, battery, the keyboard as
    Shadertoy's Keyboard texture, Pencil hover and pressure, the light and
    dark theme with the palette colours, the text size, and where the bubble
    sits on the screen with the feed's scroll offset; haptics as an output a
    shader writes into a texel
  - ✅ a budget of live shaders on one screen; the rest hold a frame
    (`ShaderBudget`, four live slots by priority and recency; run live
    2026-08-28 with five canvases on one screen — a background, a shader
    message, three stickers: four animate and one heart stands still, 13
    pixels changed between two frames 0.7 s apart against thousands on
    the others)
  - ✅ the showcase: a gallery with one shader per surface (`ShaderGallery`:
    five tap-reactive stickers, the aurora background, two bubble shaders,
    two avatars), the stickers in every new pack, `msngrfixture showcase`
    dressing fresh demo accounts on the stand, and the script of the demo in
    `docs/demo/shaders-showcase.md`
- Other
  - ✅ contact and location: the card from the system picker and the point
    under the map picker's pin; bubbles with initials or a map snapshot, a
    tap opens the card sheet or the full map
    (qa/runs/2026-08-31-contact-location; ContactLocationTests)
  - 🟡 GIFs: an animated one is sent unchanged and plays in the feed and the
    viewer (qa/runs/2026-08-21-gif-run.md); a GIF picker and stickers are not
    built
  - ⬜ shooting a photo or a video from the attachment sheet, without leaving the
    chat for the system camera
  - ✅ receiving what other apps share: a photo, a file or a link arrives through
    a share extension and lands in a chat picked there — written straight into
    the shared database as an offline send, the app's worker uploads and sends
    (qa/runs/2026-08-31-share-extension; ShareComposerTests)

## Sending, statuses, offline

- Optimistic send
  - ✅ the message appears before the network, with the clock status (offline-run 1–3)
  - ✅ a queued message sends at the slightest opportunity and never gives up:
    the drain wakes on a reconnect, on the foreground, on a network change and
    on a 30 s timer; with the stand killed for 45 s the clock held, and the
    socket was back within the first second of the stand's return with the
    message acked (qa/runs/2026-08-27-offline-queue)
  - ✅ statuses: sent → delivered → read (media-run, case 32)
  - ✅ read only while the recipient is in front of the message: not from the
    chat list, not from the background, not with the feed scrolled up, and at
    once when it arrives with the reader at the end (receipts-run)
  - ✅ the tick of a group waits for the member furthest behind, in a group of
    three (receipts-run)
  - ✅ a mark the server never heard is queued again from the chat state, so a
    receipt lost into a dying socket still arrives (receipts-run, `DeliveryReceiptTests`)
  - 🟡 the receipt from the notification extension, with the app not running:
    `POST /api/chats/:id/recv` and the queue behind it (integration test
    `testDeliveredReceiptWithoutASocket`, smoke `rest recv …`; the extension
    itself needs a device, `simctl push` does not launch it)
  - ✅ idempotency by clientMsgId (smoke `idempotent resend same seq`)
  - ✅ the ack right after the seq is assigned, before the fanout and the push (smoke `ack precedes push`, `ack while apns still hanging`)
  - ✅ «не отправлено» when the server refuses the send, and «Отправить заново»
    repeating the message from the payload it was written with (receipts-run)
  - ✅ the «не отправлено» status once the attempts are spent: the accounting
    under units (`spendSendAttempt` — the ceiling, the failed pair,
    SendFailureTests), and the live path watched end to end — a stand whose
    media uploads answer 500 while the socket stays alive spends the eleven
    attempts, the bubble takes the failure mark, and «Отправить заново» with
    the uploads healed delivers the same payload
    (qa/runs/2026-09-01-send-failed.md)
- Fanout
  - ✅ an alarm queue in ConversationDO: the cursor in storage, batches, retry until exhausted (smoke `fanout is queued, not inline`, `queue replays the whole burst`, `queue drains to empty cursor`)
  - ✅ a failing recipient does not break delivery to the rest, retry with backoff, typing is not retried (smoke `delivery survives a broken recipient`, `failed recipient gets retry`, `typing not retried`)
  - ✅ the order of a chat's frames is preserved (smoke `queue keeps frame order`)
- The offline queue
  - ✅ text, photo, voice offline → delivery after a reconnect (offline-run 1–3)
  - ✅ killing the app with something unsent: the message is still there and goes out (offline-run 4)
  - ✅ a reaction offline (offline-run 6)
  - ✅ the service action queue: read marks and accept (receipts-run)
  - ✅ the service action queue: delete-for-all, chosen with the stand dead and
    landed in the journal on its return (qa/runs/2026-08-27-offline-queue)
  - ✅ media: the source in a permanent folder, uploaded by the worker — a
    photo sent offline survived an app kill and an offline relaunch, and went
    out five seconds after the stand returned
    (qa/runs/2026-08-27-offline-media-run.md)
- The connection
  - ✅ reconnect with backoff and a ceiling of 12 s (ReconnectBackoffTests units)
  - ✅ an immediate reconnect when the network returns and from the foreground
    (devices-version run: 8 proxy kills, both apps re-upgraded and delivered
    9/9 right after each return)
  - ✅ detecting a dead socket by a pong timeout: with the stand's processes
    frozen and the TCP connection left open, the header reads «подключение…»
    17 s later, and «был(а) …» again 4 s after the thaw
    (qa/runs/2026-08-27-dead-socket)
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
  - ✅ creating one by a swipe right: the bubble follows with a capped offset
    and the reply arrow, releasing arms the strip; haptics are not observable
    on the simulator (qa/runs/2026-08-21-swipe-reply)
  - ✅ rendering the quote: text on text (qa/runs/2026-08-21-swipe-reply)
  - ✅ rendering the quote on media: photo, video, voice message and file each
    quoted live, the file by its own name; the album case was live earlier
    (qa/runs/2026-08-27-quote-on-media; qa/runs/2026-08-21-swipe-reply)
  - ✅ a quote of a deleted message: the preview is kept in the payload while
    the original shows the tombstone (qa/runs/2026-08-21-swipe-reply)
  - ✅ tapping the quote → jumping to the original with a highlight, loading more of the history window
    (qa/runs/2026-08-15-reply-file-clipboard)
  - ✅ the author's name in the quote instead of the identifier, previews for media (ChatFeedTests units)
- Forward
  - ✅ picking a chat and sending with the «Переслано от …» mark (2026-08-21-reactions-forward run, 06)
  - ✅ forwarding media and albums (2026-08-21-reactions-forward run, 07; the mark
    used to vanish under full-bleed media and read as bubble gray on own bubbles —
    both fixed in the run, BubbleLayoutTests forward cases)
  - ✅ forwarding several messages at once (qa/runs/2026-08-15-multiselect)
  - ✅ forwarding keeps the quote preview; reactions stay behind by decision
    (docs/protocol.md, ForwardPayloadTests units, run 12)
- Editing
  - ✅ editing your own text message, the «изм.» mark (2026-08-21-reactions-forward run, 08–09)
  - ✅ an edit does not grow the peer's unread count: two edit frames landed on
    a peer holding one unread and the count stayed at 1
    (qa/runs/2026-08-27-edit-unread-run.md; ServiceFrameTests units, smoke
    `service flag delivered`)
  - ✅ edit history: every text kept with its time, a context-menu item shows them
    on both sides (EditHistoryTests units, run 10–11)
- Deleting
  - ✅ delete for everyone: a tombstone on the server and a `deleted` frame (smoke `delete for all`, `tombstoned on server`)
  - ✅ confirmation before deleting; «у всех» only for your own messages (qa/runs/2026-08-15-multiselect, 03–04)
  - ✅ someone else's message is not removed for anyone by «у всех» (smoke `no fanout deleting someone else's message`)
  - ✅ delete for me: gone from the feed and the database, surviving a
    relaunch with no repair pulling it back, the peer's copy untouched
    (qa/runs/2026-08-21-delete-for-me)
  - ✅ «Сообщение удалено» in the feed for the author and for the peer (qa/runs/2026-08-15-multiselect, 05–06)
  - ✅ a delete that arrived before the original is applied later
    (ServiceFrameTests units; live behind a missing group sender key the seq
    settles as a tombstone at once — a deleted message is never repaired or
    decrypted, qa/runs/2026-08-29-delete-before-original-run.md)
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
  - ✅ deleting offline: the request waits in the action queue and lands as
    `POST /delete` on the reconnect (qa/runs/2026-08-27-offline-queue)

## Reactions and the context menu

- Reactions
  - ✅ setting one from the emoji row in the menu (unread-run, rule 3)
  - ✅ a capsule with the emoji and a counter under the bubble (design-review 03-chat-full)
  - ✅ a reaction made offline arrives after a reconnect (offline-run 6)
  - ✅ removing it by tapping again and replacing your own reaction (2026-08-21-reactions-forward run, 01–03)
  - ✅ a double tap on the bubble = ❤️ (2026-08-21-reactions-forward run, 04–05)
  - ✅ capsules widen the bubble and wrap into rows (BubbleLayoutTests units;
    confirmed done by the owner, 2026-08-29)
  - ✅ a list of who reacted: a capsule tap in a group opens the sheet, in a direct
    chat it keeps toggling (ReactionRosterTests units, run 13)
  - ✅ particles when a reaction appears: the burst plays when a visible
    message's reaction count grows — a first incoming reaction live, with the
    peer's emoji swaps and retractions correctly silent; the paths log their
    verdicts in the `shader` category
    (qa/runs/2026-08-29-reaction-burst-run.md, frames in
    qa/runs/2026-08-29-reaction-burst/)
- The context menu
  - ✅ opening on a long press: the blur, the bubble snapshot, the emoji cascade (anim-review, scenario 2)
  - ✅ closing with the bubble returning into place (anim-review)
  - ✅ items: reply, copy, select text, forward, select, pin, edit, delete (qa/runs/2026-08-15-multiselect, 01)
  - ✅ the «у меня» / «у всех» choice as a confirmation when deleting (qa/runs/2026-08-15-multiselect, 03–04)
  - ✅ forwarding from the menu opens the chat picker (qa/runs/2026-08-15-multiselect, 09–10)
  - ✅ pinning a message from the menu, applied to both members within a second
    (pin-depth-run)
- Multi-select
  - ✅ entering through the «Выбрать» item, leaving by the cross (qa/runs/2026-08-15-multiselect, 02)
  - ✅ checkboxes next to the bubbles, the selected counter and the action bar (qa/runs/2026-08-15-multiselect, 02)
  - ✅ bulk delete and forward (qa/runs/2026-08-15-multiselect, 05, 10)
  - ✅ bulk copy: one line per message, oldest on top, read back off the
    simulator's pasteboard (MessageClipboardTests units, qa/runs/2026-08-21-bulk-copy)

## The media viewer

- ✅ fullscreen above the header, opened from the bubble (media-run)
- ✅ pinch zoom and a double tap 1 ↔ 2.5 (the double tap live in
  qa/runs/2026-08-27-viewer; the pinch run with two real fingers through
  Simulator.app's ⌥-touches — zoom out, back in and the snap to fit,
  qa/runs/2026-09-01-pinch.md)
- ✅ closing by a swipe down with dimming (qa/runs/2026-08-21-media-viewer)
- ✅ paging through the album, both directions (qa/runs/2026-08-21-media-viewer)
- ✅ sharing a file from the viewer: the share sheet opens on the cached file
  with the system's save actions (qa/runs/2026-08-27-viewer)
- ✅ video in the viewer (media-close-out)
- ✅ a hero transition bubble ↔ viewer: the tapped thumbnail flies from its
  bubble frame into the fitted full-screen frame and back on close — the X
  and the swipe down alike, the return starting from the dragged position;
  after paging away the close falls back to the fade
  (qa/runs/2026-08-29-hero-viewer-run.md, mid-flight frames in
  qa/runs/2026-08-29-hero-viewer/)

## Marking up a picture before it is sent

Screenshot-level tools, not a photo editor: the point is to point at something.

- ✅ the markup opens over the picture that is already picked: photos from the
  picker and the clipboard wait in the input bar, and a tap on the waiting
  thumbnail opens the editor (the run 2026-08-31-markup)
- ✅ the viewer of a photo already in the chat opens the same editor; the
  marked-up copy lands in the input bar as a new attachment (same run)
- ✅ an arrow, a line, a rectangle and an ellipse, drawn by dragging (same run)
- ✅ freehand drawing, with a colour and a thickness; a pen line held still at
  its end straightens into an arrow, and the finger keeps dragging its tip
  (MarkupTests, the run)
- ✅ text on the picture with the same palette, retyped and dragged by the
  text tool (MarkupTests, the run)
- ✅ blurring a region, for what should not be readable — the blur fades out
  at its edge instead of ending at a seam (MarkupTests, the run)
- ✅ cropping and rotating (MarkupTests, the run)
- ✅ undo and redo of every step, and leaving without saving asks once
  (MarkupTests, the run)
- ✅ the result is a new image: the original message and the library stay
  untouched (the run)

## E2EE, trust, privacy

- Cryptography
  - ✅ X3DH + Double Ratchet in a direct chat (CoreIntegrationTests, every live exchange in the runs)
  - ✅ media encryption: the key in the message, the blob in R2, the SHA-256 check (offline-run 2–3)
  - ✅ sender keys in groups and rotation when a member leaves: a live trio
    decrypted the group message on both peers, and the leave dropped the chain
    — the next send handed a fresh key to the remaining member only
    (qa/runs/2026-08-27-sender-keys-run.md; CryptoTests units)
  - ✅ a sender key handout is acknowledged by the recipient: an unacknowledged
    one is sent again, and a member can ask for a re-handout (MessageRepairTests
    units, CoreIntegrationTests `testGroupChatSenderKeys`)
  - ✅ /devices instead of burning a one-time prekey on every message (smoke prekey checks)
  - ✅ one-time prekeys topped up automatically below 20 left: burned to 14 by
    bundle handouts, back at 100 three seconds after the next launch
    (qa/runs/2026-08-27-prekey-topup-run.md)
  - ✅ the session archive and glare resolution (CryptoTests units; live glare
    with both sides archiving and a readable round-trip after it,
    qa/runs/2026-08-29-glare-run.md)
  - ✅ a message that arrived before its key is replayed later (ServiceFrameTests, HistoricReplayTests units)
  - ✅ an unreadable envelope is stored whatever the reason and replayed by passes
    at start, on a reconnect and round the clock — with an attempt counter, a
    pause and a lifetime (MessageRepairTests units)
  - ✅ repair through the sender: an addressed request for a copy, an answer with
    the original msgId, up to 5 attempts with growing pauses; the pairwise
    session is rebuilt before the request (qa/runs/2026-08-16-repair;
    CoreIntegrationTests `testCorruptedSessionIsRepairedThroughSender`)
  - ✅ a service frame is repairable too: the ack records its payload under the
    assigned seq, and a request for a seq with no message row is answered from
    that record (qa/runs/2026-08-27-service-frame-repair-run;
    MessageRepairTests units)
  - ✅ a skipped-key window of 5000 in the pairwise chain and in the sender key
    chain, with the skipped-key store bounded on both sides (CryptoTests units)
- Trust
  - ✅ TOFU over all of the peer's devices: a peer whose second device presents
    a divergent identity key blocks the send, not just the first device
    (MultiDeviceTofuTests `testASecondDeviceWithADivergentKeyBlocksTheSend`,
    live against the stand)
  - ✅ outgoing messages blocked on a key change and a banner to accept it: a
    real identity re-publish on the stand blocked the send, and «Принять»
    released it (qa/runs/2026-08-27-key-change-run.md)
  - ✅ the 60-digit safety number in the chat info, matching the number an
    independent side computes for the same pair (qa/runs/2026-08-21-safety-number)
  - ⬜ comparing by QR
  - ✅ a "verified" mark after the comparison: the toggle under the unfolded
    safety number, a static seal while it is folded, kept in the local trust
    table and dropped by an accepted key change
    (qa/runs/2026-09-01-verified-mark.md; KeyChangeTests
    `testVerifiedMarkClearsOnKeyChange`)
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
  - ✅ unblocking from the blocked list (qa/runs/2026-08-21-block)
  - ✅ after unblocking delivery resumes and what was hidden stays hidden
    (smoke `block: delivery resumes after unblock`)
  - ✅ who sees «был(а) в сети» and «в сети»: everyone, my contacts, or nobody
    (server: `privacy_settings.last_seen`, `GET/POST /api/privacy`); hiding it
    takes the peer's away too (smoke `hiding your own last seen blinds you to
    everyone else's`); the "contacts" tier is enforced against the synced
    address book (qa/runs/2026-08-31-contacts-discovery)
  - ✅ exceptions for named people: always/never lists behind every tier
    (last seen, avatar and bio, phone discovery, group adds), enforced ahead
    of the tier by the same server checks
    (qa/runs/2026-08-31-privacy-exceptions; the exceptions block in smoke)
  - ✅ read receipts and «печатает…» turned off, in both directions (smoke
    `read receipt off reciprocally`, `typing off reciprocally`)
  - ✅ who sees my avatar and bio: everyone, my contacts or nobody, enforced
    by the server (`privacy_settings.avatar_visibility`; the card, search,
    chat lists and the avatar bytes themselves are withheld, and the profile
    frame the peers get is already blanked — under the contacts tier for
    every peer, contacts refetch the full card from the pull paths). The
    name is never hidden — a nameless peer is indistinguishable in a list
    (smoke: the avatar-privacy and discovery blocks; the placeholder switch
    seen live 2026-08-31)
  - ✅ who can find me: by username always, by the number's hash under
    everyone / my contacts / nobody — "my contacts" answers only searchers
    whose number the found user holds in their own synced book
    (qa/runs/2026-08-31-contacts-discovery; the discovery block in smoke)
  - ✅ who can add me to a group (everyone / my contacts / nobody): the
    protected are left out on the server and the adder's client sends them
    the invite link as a message instead; joining by the link stays open
    (qa/runs/2026-08-31-group-invites; the group-invites block in smoke)
  - ✅ who can call me (everyone / my contacts / nobody, with the named
    exceptions): the callee's CallManager answers a gated offer busy without
    ringing, fail-closed; the viewer's dial button follows `canCall` in the
    user card (CallManagerTests gate tests; live two-simulator run 2026-09-01)
  - ✅ a default disappearing timer for new chats: a Privacy picker (off / 1
    day / 1 week / 1 month) local to the device; a chat this device creates —
    direct or group — gets one disappearing message with the chosen TTL right
    after creation, existing chats keep theirs
  - ✅ every one of these is enforced by the server, not only hidden in the
    interface: a hidden last seen is not in the state the server sends
    (`presenceVisible`), a receipt or typing that is off is dropped by the
    ConversationDO fanout for both directions, the avatar bytes and the card
    are withheld, discovery and group adds are refused at the API, and the
    named exceptions ride the same single check (`privacyAllows`; the
    privacy, discovery, group-invites, exceptions and receipts blocks in
    smoke)
  - ✅ reporting a chat or a message: what leaves the device is only what the
    reporter chose to attach, and blocking is offered in the same step —
    «Пожаловаться» in the message menu and the chat card, a reason, optional
    details, the attach toggle with the E2EE footnote, and «Пожаловаться и
    заблокировать» (smoke report block, qa/runs/2026-09-01-report.md)
  - ✅ a request's content is hidden until it is accepted: the feed, the chat list,
    the in-app banner, the badge (ChatPrivacyTests, ChatFeedTests units, request-privacy-run)

## Message requests

- ✅ before acceptance the author gets no receipts and no typing (smoke `no read receipt before accept`, `no typing before accept`; the client sends neither read nor recv for a request — unit `testMarkReadSkippedForRequestChat`, request-privacy-run)
- ✅ acceptance lifts the restriction (smoke `accept request`)
- ✅ the «… хочет вам написать» screen instead of the feed, with «Принять» and «Заблокировать» buttons (request-privacy-run)
- ✅ the requests section in the list with no preview and no counter (request-privacy-run)
- ✅ accepting offline through the action queue: the accept and the read wait
  in `pendingAction` while the stand is down and drain on reconnect, and the
  requester's next message arrives as an ordinary one
  (qa/runs/2026-08-28-offline-accept-run)
- ✅ the recipient's presence is not given out before acceptance over the REST profile either (smoke `no presence before accept`)
- ⬜ a push for a request with no preview: the server carries no plaintext, the NSE fills the text in from the shared database

## Presence, typing, receipts

- ✅ read receipts and counters going to zero (media-run, case 32)
- ✅ delivered receipts on recv (smoke `delivered receipt`)
- ✅ typing reaches the peer (smoke `typing`)
- ✅ presence by ping freshness with a TTL of 35 s: a peer whose process is
  frozen with its socket open reads «был(а) только что» 28 s after the freeze
  (qa/runs/2026-08-27-presence-ttl)
- ✅ «в сети» / «был(а) …» in the chat header, flipping live with the peer's
  socket (qa/runs/2026-08-21-presence-names)
- ✅ the typing indicator in the header and in the chat list
  (qa/runs/2026-08-21-presence-names)
- ✅ read on returning from the background: the receipt goes out on the
  foreground return with the reader at the message (qa/runs/2026-08-21-read-on-return)
- ✅ the read-by list of an outgoing group message: «Кто прочитал» in the
  context menu opens who has read and who has only received it, from the
  per-member marks the receipts already keep (the owner's call over an
  aggregated "N read it"; qa/runs/2026-08-30-read-by-run)

## Notifications

- The server side
  - ✅ APNs for every content message, regardless of a live socket (smoke `push delivered despite live ws`)
  - ✅ the APNs call is awaited in the handler, without waitUntil; the sender does not wait for it (smoke `push follows its ack`)
  - ✅ no push for service frames, a muted chat and your own echo (smoke, three checks)
  - ✅ being added to a group raises its own push, the group's title in the clear
    and no envelope; re-adding a member is a no-op with no push (smoke
    `push on being added to a group`, `group-add push names the group`,
    `re-add is a no-op with no push`)
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
  - ✅ withdrawing delivered notifications when the chat is read: a stack of
    pushes and the badge left the shade on reading the chat
    (qa/runs/2026-08-27-notification-withdraw-run.md)
  - ✅ tapping a system push opens the chat: the push delivered through the dev
    mock raised the system banner and the badge, and the tap was confirmed by
    the owner watching the run (qa/runs/2026-08-27-push-tap-run.md)
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
  - 🟡 quick reply straight from the push (category, action routing and the
    reply/mute handlers are in — NotificationActionRouteTests; the expanded
    banner itself needs a device: idb cannot produce the SpringBoard
    context-menu press, and the NSE path does not run on the simulator)
  - 🟡 mute the chat straight from the push (same category; same device caveat)
  - 🟡 a banner when someone reacts to your message («Реакция 👍 на «🖼 Альбом»»,
    live run 2026-08-28 on the WS path, NotificationContentTests for the body;
    the reaction frame is service on the wire — with the app killed there is no
    push for it yet, that part needs the server to raise a targeted push and
    the NSE to render it, device-gated)
  - ⬜ a photo preview as an image in the notification
- Sounds and exceptions
  - ✅ a sound of its own for one chat, overriding the default: a flag on the
    receiver's object, resolved when the push is sent; three bundled chimes
    with a preview in the chat-info picker (qa/runs/2026-09-01-notify-sounds;
    the sound block in smoke)
  - ✅ separate defaults for direct chats and for groups (the same run; the
    pickers in Settings → Notifications)
  - ✅ a sound of its own for a person, applied wherever they write: keyed by
    the sender on the receiver's object, between the chat's explicit sound
    and the shape default; the picker on the direct chat's info screen
    (the person-sound cases in smoke; live pick 2026-09-01)
  - ⬜ a sound of its own for a mention, louder than the chat's own
  - ✅ a muted chat still notifying on a mention or a reply to you
    (qa/runs/2026-08-28-mute-reply; NotificationDecisionTests,
    MentionMarkdownTests `mentionsUser`; the mention live run in
    qa/runs/2026-08-28-mention-token)
  - ⬜ a set of sounds to pick from, and a silent choice
  - ⬜ the sound travels with the push (`apns-sound`) so the extension does not
    have to be running for it to be right

## Groups

- ✅ creating a group and delivering a message to its members (smoke `create group`, `group message delivered`)
- ✅ an admin adding a member, a non-admin barred from removing one (smoke `admin adds member`, `non-admin cannot remove`)
- ✅ the invite link: created by a member, joining, idempotency (smoke, four checks)
- ✅ creating a group from the interface, picking members and a title (qa/runs/2026-08-17-groups-run)
- ✅ the info screen: the member list, the row's swipe actions, leaving a group (qa/runs/2026-08-17-groups-run)
- ✅ adding a member and the invite link from the info screen
  (qa/runs/2026-08-27-info-screen-and-voice-run)
- ✅ the author's name in group bubbles (qa/runs/2026-08-21-presence-names)
- ✅ granting and revoking the admin role from the interface, live on all three
  devices (qa/runs/2026-08-17-groups-run)
- ✅ changing a group's title, avatar and description from the interface (qa/runs/2026-08-17-groups-run)
- ✅ member rights: who can write, who can invite; what a member cannot do is not
  shown to them (qa/runs/2026-08-17-groups-run; smoke `member cannot write in a
  read-only group`, `member cannot add once inviting is locked`)
- ✅ system messages about group events, raising no unread count and no push
  (qa/runs/2026-08-17-groups-run)

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

- ✅ 1:1 audio over WebRTC: signaling as E2EE `call` service messages on the
  existing send path (no server change), CallManager behind a transport seam
  (glare, busy, timeout, held ICE, another device's echo — CallManagerTests),
  the WebRTC binary in its own MsngrCalls package, the call screen and the
  dial button in a direct chat's header; rings only over a live socket by
  design in v1 (a `call` frame is service: no unread, no push)
  (live two-simulator run 2026-08-31)
- ✅ the call log row in the feed: sent by the caller alone on hang-up
  (`callLog`, deduplicated), outgoing / incoming / missed with the duration,
  «📞» previews in the chat list, a tap redials (live run 2026-08-31)
- ⬜ a VoIP/call push so an incoming call rings with the app closed (blocked
  on the dev signing certificate for device pushes)
- ✅ our own TURN (coturn on the stand) for NAT paths STUN cannot cross:
  coturn on adad (:3478, relay 49160–49400, systemd) and `turn:` in the
  client's ICE servers (the merge of worktree-calls, 2026-09-01; details in
  CALLS-ROADMAP.md)
- ⬜ 1:1 audio on CF Calls, the provider behind our own protocol
- ⬜ end-to-end encryption over insertable streams
- ✅ a 1:1 video call: the video button in the chat header dials with the
  camera on and the callee rings as a video call (`video` on the first
  offer), the camera toggle renegotiates the running call, the peer's stream
  full-screen, the self-view tile with a front/back flip, the camera's off
  state carried on the renegotiation offer; the simulator runs the whole
  pipeline through a synthetic capturer (live two-simulator runs 2026-09-01;
  the real-camera device check remains — CALLS-ROADMAP.md)
- ✅ ICE restart when the path dies under a live call: the caller sends a
  fresh-credentials offer for the same call after a held disconnect, the
  callee answers in place (CallManagerTests; the Wi-Fi→LTE device check
  remains)
- ✅ ICE candidates off the journal: an ephemeral `callRelay` frame (E2E
  envelope, live sockets only, never journaled) carries them; a batch that
  outruns its offer is held by callId (smoke + a live call on relayed
  candidates alone, 2026-09-01)
- ✅ the peer of a call named as in the owner's address book: discovery
  stores the book names (`contactBookName`), and the chat list, the chat
  header, the call screen and notification banners show them over the
  profile name (live run 2026-09-01)
- ⬜ a group call
- ⬜ CallKit and PushKit
- ✅ ringback while dialing, and the callee's ringtone (CallSounds, the merge
  of worktree-calls 2026-09-01)
- 🟡 a push for an incoming call, and a missed-call notification with a way
  back (the missed-call push is shipped — the caller's `callLog` rides
  `service` + `notify`, covered in smoke; the incoming-call ring with the app
  closed is the VoIP push, blocked on the device signing certificate)
- ✅ the in-app call bar: the call folds into a floating tile over the chats,
  the timer on it, a tap returns to the call screen (the merge of
  worktree-calls 2026-09-01)
- ⬜ picture-in-picture for a video call, including the call minimized to the
  system PiP window
- ✅ a second incoming call during a call: the banner over the live call
  with decline (the caller hears busy), end-and-accept, or hold-and-accept —
  the live call parks silent on its open transport (the `hold` signal shows
  «На удержании» on the peer), a switch row swaps the two, hanging up or
  losing the live call brings the parked one back, and a call that ends by
  itself rings the waiter (CallManagerTests waiting and hold tests; live
  three-simulator runs 2026-09-01)
- ✅ the call log: outgoing, answered and missed in the chat (the `callLog`
  feed row) and in a list — the phone button on the chat list opens every
  call newest-first, named as the address book names them, with direction,
  outcome and duration; a tap redials (live run 2026-09-01)
- ✅ pulling a third person into a 1:1 call: the add button on the call
  screen, a short-lived mesh of three (each pair on its own transport over
  their direct chat, the callId as the ticket — a same-callId offer joins in
  place), the primary peer leaving promotes the remaining leg, everyone hears
  everyone (live three-simulator run 2026-09-01; growing past three is the
  SFU's job — CALLS-ROADMAP.md)
- ✅ the invited-by row in the pairwise chat of the inviter and the invited
  (created on the spot when they had none): «Вы пригласили X в звонок», a
  system line written by the inviter once (live run 2026-09-01)
- ⬜ the live call bubble that stays live in the chats it was placed into:
  join from there, the timer and the participants on it

## Settings

- ✅ profile: name, bio, avatar (design-review 08)
- ✅ the username on its own screen, with the taken case seen live
  (qa/runs/2026-08-17-profile)
- ✅ picking a palette from cards with instant application (palettes/live-*, settings-appearance)
- ✅ a muted count beside every row that leads to a list — blocked users, active
  devices, members and attachments in the chat info — and on the attachment
  tabs, shortened as 9/550/1k by one shared formatter
  (qa/runs/2026-08-31-counts; CountFormatterTests)
- ✅ a background for the feed: a set to pick from (Aurora, Dusk, Paper — live
  shader previews) and a picture of your own, set everywhere from the settings
  or for one chat from its card; the chat's own choice wins over the global
  one (qa/runs/2026-09-01-feed-background.md)
- ✅ the PIN: setting it, repeating it, a mismatch resetting the setup, a wrong
  code rejected at the lock, auto-lock after 30 s in the background
  (qa/runs/2026-08-21-pin)
- ✅ Face ID: the lock invokes the scan itself, a matching face unlocks, a
  non-matching one is refused with the pad as the fallback; auto-lock after
  30 s (qa/runs/2026-08-21-pin)
- ✅ the blur in the app switcher: the card is unreadable, the chat glyph over
  it (qa/runs/2026-08-21-switcher-blur)
- ✅ the blocked list and unblocking, delivery resuming after
  (qa/runs/2026-08-21-block)
- ✅ clearing the media cache with its size shown: the label follows the clear
  in place (qa/runs/2026-08-21-media-viewer, the run also caught and fixed the
  stale label)
- ✅ notification settings: one screen under Settings → «Уведомления» with the
  banner preview toggle, the default sounds for direct chats and groups, and
  the per-chat and per-person sound exceptions listed with removal
  (`/api/notify-sounds/exceptions` over the receiver's object; the exceptions
  checks in smoke; qa/runs/2026-09-01-notifications-settings.md)
- ✅ a privacy screen gathering what E2EE, trust, privacy lists: last seen,
  receipts and typing, the profile's visibility, who finds me and who adds
  me, who can call me, link previews and the default disappearing timer —
  each tier with its named exceptions
  (qa/runs/2026-09-01-privacy-screen.md)
- ✅ language choice: the bundle ships English and Russian, iOS offers the
  per-app language on the app's page in Settings, and the app's settings show
  a «Язык» row with the current language that opens Settings
  (qa/runs/2026-08-27-language)
- ✅ exporting and deleting the account: the backup file in «Данные» is the
  full export; «Удалить аккаунт» in the settings leaves every group, wipes the
  UserDO and the D1 rows, frees the username and returns the app to
  registration (qa/runs/2026-09-01-delete-account.md, smoke delete-account
  block)

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
- ✅ cleaning out stale media by cache size: the decrypted cache keeps to a
  user-set ceiling («Данные» → «Лимит кэша медиа», default 1 GB), evicting the
  files untouched the longest — a cache hit refreshes the file — after every
  download and at startup (qa/runs/2026-08-30-cache-ceiling-run.md;
  MediaCacheCeilingTests)
- ✅ deleting messages automatically once their TTL expires: a sweep on the
  maintenance loop plus an alarm for the nearest deadline, attachments removed
  with the rows; a 20 s timer took an outgoing and an incoming message off the
  screen and out of the table within the half minute (qa/runs/2026-08-27-ttl;
  the deadline stamping in DisappearingTests; an expiring attachment's file
  is not yet watched)

- Backup to iCloud
  - ✅ the backup itself: the history, the media and the settings, sealed on the
    device (ChaChaPoly, key from HKDF over the recovery code) before anything
    leaves it (`AccountBackup`, `BackupSeal`; live run 2026-08-30 — alfa's three
    direct chats, three groups and one photo attachment all came back byte-exact)
  - ✅ the key to the backup: a recovery code, not a passphrase. 15 random bytes
    (120 bits), shown once as Crockford base32 when backup is turned on, never
    stored — HKDF derives the seal key from it directly, the same way every
    other key derivation here starts from a high-entropy secret rather than
    something typed. There is no password reset: losing the code loses the backup.
  - ✅ the user's own password as the alternative (the owner's ask, 2026-08-30):
    turning backup on offers a generated code or a typed password; a password
    seals a `v: 2` file through PBKDF2-HMAC-SHA256 (600k rounds, random salt in
    the file), and the restore screen reads the file's version to know which of
    the two to ask for. The code on its screen is copied by a tap.
    (BackupSealTests units; live run 2026-08-30: password backup → logout →
    restore with the password brought the account back)
  - ✅ restoring works after the last device logged out: the account identity
    outlives its devices in `UserDO` (`accountIdentity`), so
    `/api/restore/start` no longer answers `account_has_no_devices` to the
    exact state a backup is for (found live by the owner 2026-08-30; smoke
    `restore: start with zero devices` … `the restored device authenticates`)
  - ✅ what the backup does NOT carry: `ratchetSession`, `senderKeyIn`/`Out`,
    `trustedIdentity`, and the ratchet's own bookkeeping tables. A restored
    device adopts the account's identity keys and generates its own fresh
    prekeys, exactly as a linked device does — sessions with every peer start
    over (live run 2026-08-30: messages sent from the restored device were
    decrypted and read by the peer, confirming a clean new session)
  - 🟡 when it runs: manual only, from Settings → Backup → "Back up now". Not
    done: running on its own on a charger over Wi-Fi
  - ✅ restoring during registration: `RestoreFromBackupView`, a third path off
    the registration screen. A restore that fails partway (bad recovery code,
    a claim the server refuses) leaves the container wiped and the screen on
    its failure state — there is no partially-restored account to clean up,
    since the identity claim happens before any row is written
  - ✅ turning it off (Settings → Backup → "Turn off backup", stops future
    backups on this device only). No iCloud yet, so nothing there to delete —
    see the storage note below
  - the storage is a file, not iCloud: `fileExporter`/`fileImporter` (Files,
    AirDrop, iCloud Drive as a plain file) — CloudKit needs a signed-in Apple ID,
    which the simulator this was built and tested on does not have. The sealed
    bytes (`BackupSeal.SealedBackup`) don't know or care which transport carries
    them, so a CloudKit private-database uploader can be added later without
    touching `AccountBackup`/`BackupSeal`; nothing about that path is verified yet
  - ⬜ no password at all, for iCloud only (the owner's ask, 2026-08-30): a
    random key held in the iCloud Keychain instead of anything typed, so a
    restore on a signed-in device asks for nothing — lands together with the
    CloudKit transport, since only the keychain makes it safe
  - server: `/api/restore/start` and `/api/restore/:id/claim` add a device to an
    existing account with no other device online to approve it, by having the
    claim sign a server-issued nonce with the account's Ed25519 identity key
    (`@noble/ed25519` verifies it) — proof of possession standing in for the
    live-device approval `/api/provision/*` uses instead

## The desktop client

One binary for every screen (the owner's call, 2026-08-30: two clients
written in parallel is the wrong path): the iOS app targets the iPad family
and a Mac runs it as «Designed for iPad». The native MsngrMac target is
deleted. The signing team never enters the repository — a device or desktop
build takes it from the environment (`make device TEAM=…`, local.mk).

- ✅ the iPad family in the target; the chat list and the chat hold on an
  iPad screen as they are (first run 2026-08-30, fable-ipad)
- ✅ chat list from the keyboard: arrows walk the rows, Enter opens, Cmd+N
  new chat, Cmd+F into search, Cmd+1..9 folder tabs
  (KeyboardNavigationTests, real HID events)
- ✅ chat keys: the composer takes focus as a chat opens under a hardware
  keyboard, Enter sends, Shift+Enter breaks the line, Esc walks out of the
  edit, the reply and the chat (KeyboardComposerTests units, live run
  qa/runs/2026-08-30-keyboard-run.md)
- ✅ the keys the owner's first real-keyboard run missed (2026-08-30): Tab is
  consumed instead of printing a tab character; ↑/↓ over an empty composer
  walk the feed message by message with Enter replying to the walked one and
  Esc ending the walk; Cmd+B/I toggle bold/italic markers around the
  selection and Cmd+K makes a `[text](url)` link, with that markup added to
  the message markdown (KeyboardComposerTests, FeedKeyWalkTests,
  MarkdownTests; qa/runs/2026-08-30-keyboard-defects-run.md — the composer
  keys hold on units, the simulator's keyboard pipe being undriveable from
  tests is written down in the report)
- ✅ Cmd+↑ puts your newest own text message into the edit mode — the bare ↑
  walks the feed, so the edit has its own key; the same gate the context
  menu's Edit has, skipping delete-for-all leftovers (KeyboardComposerTests,
  FeedKeyWalkTests)
- ✅ Ctrl+Tab / Cmd+[ ] switch to the neighbouring chat of the current tab
  from inside a chat, Ctrl+Shift+Tab back (the keys post a direction, the
  open screen names itself, the list swaps the top of the path; pinned by
  KeyboardComposerTests over the same undriveable simulator keyboard pipe)
- ✅ the iPad layout reviewed screen by screen: the list, the feed with a
  shader background and stickers, settings, backup, chat info, attachments,
  the sticker sheet, the picker and the media viewer all hold at 834 pt; the
  shader-avatar square from the first run is fixed (the list clips to the
  circle, like the feed) — qa/runs/2026-08-30-ipad-review-run.md. The feed
  spans the full width with bubbles at the left edge; a bubble-column cap is
  the owner's design call.
- ✅ a menu bar on the Mac (UIMenuBuilder): the app delegate inserts Chats
  (next/previous chat, edit last message) and Format (bold/italic/link),
  each item naming a composer selector so the responder chain enables it
  exactly where its key works; the keystrokes stay in keyCommands
  (KeyboardMenuTests pins the selectors both ways; seen live on the
  development Mac — qa/runs/2026-09-01-mac-run.md)
- ✅ a signed run on a real Mac as «Designed for iPad»: the iphoneos build
  wrapped the way the App Store installs iOS apps runs as a Mac window —
  the feed, voice playback and the composer all live
  (qa/runs/2026-09-01-mac-run.md, watched by the owner)

## Performance and animations

- ✅ the outgoing bubble flying out of the input field (anim-review, frames after the fix)
- ✅ the incoming bubble rising (anim-review, frames after the fix)
- ✅ the context menu animation: the blur, the emoji cascade, the dismissal (anim-review)
- ✅ swipe-to-reply: the drag, the capped offset and the arrow are live
  (qa/runs/2026-08-21-swipe-reply); haptics are not observable on the simulator
- ✅ the reaction capsule appearing on a spring: recorded frame by frame, the
  whole capsule scales as one unit (qa/runs/2026-08-27-reaction-spring-run.md;
  the clipped-glyph entrance it replaced is in defects.md, closed)
- ✅ a pointwise feed diff instead of reloadData, the layout plan cache:
  held directly by FeedDiffTests — a counting data source shows an insert
  materialises the new cell without re-asking for the screen, and an edit
  reconfigures in place with no dequeue at all
- ✅ the feed window is bounded by count while the reader is at the bottom:
    without a ceiling it grew for as long as the chat stayed open, and sending
    fell from 12 to 4 messages/s at 158% CPU (the 20k run, qa/runs/2026-08-15-20k-chat-run)
- ✅ the cost of receiving one message: the chat list was re-read by a query with
    no covering index, and a key change was read synchronously from the main
    thread; after the fix the chat list's cost fell by a factor of 81
- ⬜ measured 60/120 fps on a chat of tens of thousands of messages
- ✅ animated reordering in the chat list (qa/runs/2026-08-21-chatlist-reorder)
- 🟡 preloading and prefetching images along the scroll direction: the feed is
    a prefetching data source and pulls the pictures of the cells the scroll is
    about to reach, albums included (verified live by the callback and queue
    counters on a chat of hundreds of photos); what it wins is not measurable
    on the simulator against a local stand and needs a device

## The backend rework: a DO per user

Decided in `docs/research/2026-08-19-per-user-do.md`; the queue orders the steps.

- ✅ the fanout as an outbox: a delivery record per recipient until acknowledged,
  independent chains, the push in its own persisted queue (run-delivery,
  `runs/2026-08-19-delivery-run.md`)
- ✅ a receipt writes one per-member mark key; the cmid idempotency records are
  swept behind the sender's delivered mark (`17354b3`, smoke holds the rule)
- ✅ identity keys, one-time prekeys and the device list live in `UserDO`; a
  first message costs 2 D1 statements instead of 7 (run-userdo,
  `runs/2026-08-21-userdo-run.md`)
- ✅ the message's identity is `(chatId, seq)`, the msgId ULID is gone from the
  database, the frames and the REST (run-msgid,
  `runs/2026-08-21-msgid-run.md`)
- ⬜ `HandleDO`: the username claim and quarantine, designed together with the
  people-search index
- ⬜ subscriptions between objects: a snapshot on subscribe, deltas after, the
  source deciding what a subscriber may see
- ⬜ what is left in D1 follows into the user's object; the leftover tables are
  dropped with the schema version bumped

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

From the open backlog (`docs/audits/2026-08-12-code-audit.md`) and the topics
still not closed:

1. The device run that closes the NSE family of 🟡 lines: the extension comes
   up on hardware, fits into the limits, sees the group container; the same
   run checks the banner-to-chat write in airplane mode, quick reply and mute
   from the push, the coalescing window, and measures the call ceiling during
   an avalanche — `simctl push` does not launch the extension on the simulator
   at all. Data Protection on a locked screen rides along.
2. Calls v2 by `CALLS-ROADMAP.md`: the SFU path, E2EE over insertable streams,
   video; the VoIP push stays blocked on the device signing certificate.
3. The per-user DO rework's tail: `HandleDO`, subscriptions between objects,
   the last D1 tables moving into the user's object.
4. Channels, stories, bots — the three plaintext surfaces not yet started.
5. Translating the Russian that remains in older documentation by separate
   passes; new content is English already, the interface strings live in the
   catalog.
6. Working through the remaining audit items in order: crashes and data loss →
   offline reliability → E2EE edge cases → UI.
