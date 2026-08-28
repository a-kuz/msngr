# UI: how it works today

A description of what the client actually does. The constants come from the code
(`ios/Msngr/Chat/*`, `ios/Msngr/ChatList/*`, `ios/Msngr/App/Theme.swift`).
Interface text is quoted in Russian because that is what ships.

## The message feed

A `UICollectionView` with a `UICollectionViewFlowLayout`, wrapped into SwiftUI
through `UIViewControllerRepresentable`. The feed is inverted: the collection
carries `transform = scaleY(-1)`, every cell is counter-inverted, the bottom of
the chat is `contentOffset 0`, and the insets swap ends.

There is no diffable data source. `apply(_:)` computes the diff over ids by
hand. If the set of ids has not changed, only the cells whose content changed
are updated; otherwise the inserts and deletes go through
`performWithoutAnimation { performBatchUpdates }`. A full `reloadData()` is kept
for a complicated reordering, or when `deletes + inserts >= 60`.

A live cell is always updated by reconfiguring it in place, inside a 0.35 s
spring at damping 0.86; when the plan height moved (`|Δh| ≥ 0.5`, a reaction
arrived or left) a `performBatchUpdates(nil)` joins the same animation, so the
bubble resizes on screen and the neighbours slide instead of jumping.
`contentOffset` stays untouched, which in the inverted feed keeps the bubble's
bottom edge anchored. `reloadItems` is not used on a visible cell: it would
recreate it and cut off the appearance animation when the `sending → sent` ack
lands in the first milliseconds after the insert.

What the feed reads is a window rather than the whole chat. `FeedWindow` holds a
floor and a capacity of `HistoryWindow.pageSize` (60); while the reader sits at
the bottom the floor is recomputed on every change and the window slides, and
while they read history it stays put. Order is `COALESCE(seq, 999999999) DESC,
sentAt DESC`. Coming within 600 pt of the top edge, `loadOlder()` drops the
floor by another page over what is already in the database; only when the local
history runs out does it ask the server, and then only for the seq gaps this
device has never decrypted, handing what comes back to `engine.storeHistoric`.
Layout plans are cached in an `NSCache` whose key covers
the id, the width, the grouping flags and a hash of the content; the cache is
dropped when the width, the palette or the type size changes.

The keyboard uses `keyboardDismissMode = .interactive` and the insets are
computed by hand from the safe area and the keyboard frame. A feed that was at
the bottom returns to the bottom once the insets change.

## The bubble: where the status sits

The status block is the time `HH:mm` (from `serverTs ?? sentAt`), plus «изм. »
on an edited message, plus the ticks on outgoing ones (20 pt). Sizes are named
roles in `Theme.Text` rather than numbers at the call site — text 17 pt, time
12 pt, name 14 pt semibold — each scaled through `UIFontMetrics` up to its own
ceiling. The rest of the geometry: horizontal padding 12, vertical 7, side
inset 10, corner radius 17, a bubble at most 0.76 of the screen wide, and 6 pt
between the text and the status.

`BubbleLayout` decides in this order:

1. **Media with no caption, and albums** — the status becomes a capsule over the
   image in the bottom right corner (height 20, inset 18 from the right edge).
   Reactions go in rows underneath the media.
2. **There are reactions** — if the text is a single line and `text + capsules +
   status` fit the content width, everything sits on one line. Otherwise the
   capsules take their own rows and the status joins the end of the last row if
   it fits, dropping to a line of its own if it does not.
3. **Text with no reactions** — if `last line width + 6 + status width` is
   within the content width, the status stays on the last line; otherwise it is
   pushed onto its own.
4. **Voice and files with no reactions** — the status sits in the bottom right
   of the same row.

The status is always flush with the right edge of the bubble, and the bubble is
never narrower than the status plus its padding.

Media: photos and videos are as wide as the bubble, with height
`min(max(w / aspect, 120), 420)`. An album is laid out by `AlbumMosaic` — fixed
patterns for one to four photos, and for more than that a search over splits
into rows of two or three, penalised by how much each split distorts the
proportions. Only the outer corners of the mosaic grid are rounded. A video gets
a 44×44 `play.circle.fill` in the middle. The placeholder is a 32×32 blurhash
and the real image cross-fades in over 0.18 s.

The reply strip is up to 220 wide and 36 high, with a 3 pt vertical bar, the
author at 13 pt semibold and the text at 13 pt. A forward is the line
«Переслано от …» in 13 pt italic. Reactions are capsules 26 high, corner radius
13, 0.5 pt stroke, ordered stably by descending count and then by emoji; your
own reaction is filled with the accent colour; rows wrap at the bubble width.

## Grouping into runs

Messages from one author join a run when `fromUserId` matches, the `sentAt`
difference is strictly under 60 seconds, the calendar day is the same and
neither message is a system one. Inside a run the gap above a bubble is 2 pt,
between runs 8 pt; the gap always lives at the top, inside the cell.

The bubble tail is drawn only on the last message of a run, which is the newest
one. The author's name shows on the first message of a run, only on incoming
messages and only in a group (`members.count > 2`); its colour is a stable hash
of the userId over a palette of seven. There are no avatars in the feed.

Date separators are ordinary cells («Сегодня», «Вчера», otherwise the date), a
capsule 22 high on translucent black. Nothing is sticky.

## The unread banner

A full-width strip reading «N непрочитанных сообщений», declined by mod100 and
mod10 («1 непрочитанное сообщение», «2 непрочитанных сообщения», «5 непрочитанных
сообщений»). `UnreadMarkerState` holds five rules:

1. Entering a chat with unread messages anchors the banner at `myReadUpTo + 1`
   with `unreadCount` as its number. With nothing unread there is no banner.
2. A message arriving while the chat is open raises the number and leaves the
   anchor alone.
3. Sending something, or reacting, clears the banner; incoming messages do not
   bring it back while the screen is visible.
4. Going to the background or into the notification shade clears it and resets
   the accumulator.
5. Coming back to the screen turns whatever arrived while away into a new
   banner; if nothing arrived, the old one does not return.

The banner is inserted above the first unread message and its id,
`unread:<anchorSeq>`, stays stable as the count grows. Opening the chat scrolls
straight to it. Its disappearance is animated: this is the one delete in the
diff that is not wrapped in `performWithoutAnimation`.

## Optimistic send and offline

`enqueue` writes the message with status `sending` and the outbox row in one
transaction, so the UI has the message before it reaches the network — the feed
is a `ValueObservation` over SQLite. Media goes into the permanent
`media-outgoing` folder first and the outbox worker uploads it, which is why an
attachment picked while offline is not lost.

Statuses and their glyphs: `failed` is a red `exclamationmark.circle.fill`,
`sending` a clock, `sent` one tick, `delivered` and `read` a double tick that
differ only in colour (`read` uses the palette's `outgoingTickRead`).

With the socket down the header subtitle reads «подключение…».

## Animations

- An outgoing message leaving the input field starts near the send button at
  `scale 0.15` and alpha 0.5; a 0.6 s spring, damping 0.72, velocity 1.1, with
  the bubble content fading in separately (0.25 s after a 0.18 s delay).
- An incoming message arrives from 14 pt away at `scale 0.96` and alpha 0.4; a
  0.42 s spring, damping 0.82. Both start after the inserted cell has laid out.
- Someone else's message scrolls the feed down only if the reader was at the
  bottom (`contentOffset.y < 60`); your own always scrolls, immediately.
- The press dip: a touch that settles on a bubble for 0.1 s scales it to 0.96
  over 0.22 s ease-out. It runs alongside every other gesture, releases on a
  0.35/0.8 spring, lets go as soon as the finger moves 12 pt (a scroll or a
  swipe), and hands the transform to swipe-to-reply without a restore.
- The context menu: a 0.35 s long press with `Haptics.medium()`; a
  `systemUltraThinMaterial` backdrop over 0.25 s; the bubble snapshot starts at
  the press-dip scale read off the presentation layer and lifts on a 0.45/0.8
  spring, so the dip flows into the menu; the reaction bar and the card from
  `scale 0.2` over 0.4 s after a 0.05 s delay, damping 0.75; the emoji cascade
  0.35 s at a 0.03 step. Dismissal takes 0.3 s at damping 0.9, and stepping
  into the delete submenu is a 0.2 s cross-dissolve.
- Swipe to reply: the pan only starts on horizontal movement to the right,
  travel is capped at 90 pt with resistance `60 * (1 - exp(-x/60))`, the icon
  fades in along the way, the threshold is 44 pt with `Haptics.medium()`, and
  the return is a 0.35/0.8 spring.
- Reactions: a new capsule appears over 0.4 s at damping 0.6 from `scale 0.5`;
  tapping a capsule runs 0.12 s up to 1.25 and back. Capsules are reused by
  emoji, so a count change animates in the same view, and a withdrawn reaction
  shrinks away over 0.2 s to `scale 0.5`. The bubble's own resize rides the
  feed's reconfigure spring above.
- A double tap on a bubble leaves «❤️» with `Haptics.medium()`.
- The scroll-to-bottom button appears when the newest message (item 0 of the
  inverted feed) is off screen, transitioning on `scale + opacity` with
  `Theme.springFast`. The same signal drives the read receipt, so opening a chat
  whose unread messages are already on screen shows no button.

The theme's springs: `springFast` 0.35/0.82, `spring` 0.45/0.84, `springSlow`
0.55/0.86.

## The context menu

Items: «Ответить», «Копировать» (text only), «Переслать», «Закрепить»,
«Изменить» (your own text messages only), and «Удалить» leading to a submenu of
«Удалить у меня» and «Удалить у всех». A message deleted for everyone does not
open a menu at all.

The reaction row is «❤️», «👍», «🔥», «😂», «😮», «😢», with your current one
highlighted. The card is 252 wide with 44 pt rows; the menu and the bar hug the
side the bubble is on.

Opening the menu sends the keyboard down so the card has the whole screen; the
composer keeps its draft. The bubble itself is hidden while the overlay is up —
the lifted snapshot is the only copy on screen — and dismissal returns the
snapshot to wherever the bubble stands after the feed has relaid itself out.

## Media

Photos are downscaled to 1280 on the long side and encoded as JPEG at quality
0.8; the blurhash is computed from a 32 px copy (4×3 components). Several photos
go out as one album message.

Video is exported through `AVAssetExportPreset1280x720` into mp4 with
`shouldOptimizeForNetworkUse` (faststart). The frame at 0.1 s becomes the
preview, as its own blob plus blurhash, and duration and dimensions go into
`MediaInfo`.

Files go up to 100 MB and keep their name in `MediaInfo.name`.

The viewer is a separate `UIWindow` above the nav bar: it pages through the
album, pinch-zooms (double tap toggles 1 ↔ 2.5), closes on a vertical swipe past
120 pt with the backdrop dimming along the way, and offers a close button and a
`ShareLink`. Video plays through `VideoPlayer` once the file has fully
downloaded; there is no streaming.

The media cache is flat (`<mediaId>.<ext>`, plaintext on disk) and the extension
is derived from the MIME type, because that is how AVPlayer identifies the
container. A download is checked against the SHA-256 of its ciphertext before
being decrypted.

## Voice messages

Recording runs while the microphone is held; the gesture begins on the first
`onChanged`. The format is m4a, AAC, 24 kHz, mono, 48 kbit/s. Anything under
0.3 s is dropped as an accidental touch and anything longer is a real message.

The take belongs to the finger that started it, and `RecordingGesture` is where
that is written down. Access is asked for before the recorder runs, so a touch
that ends while the request is still in flight starts nothing at all; a take
dropped by the slide is not started again by the same finger going on moving
over the button; and a take that loses the screen, the foreground or the
microphone to a call is dropped whole rather than sent as a stump of what was
said before.

While recording: the button pulses, a timer counts tenths, and a live waveform
is drawn (a 0.05 s timer over `averagePower` from −60 to 0 dB, keeping the last
60 values). Swiping left past 110 pt cancels; swiping up past 70 pt locks the
recording, after which a cancel button and a send button appear.

The message carries a waveform of 100 buckets valued 0 to 31, computed from the
finished file. The voice bubble is fixed at 220×42 with a 40×40 play button, a
waveform 22 high and the duration beneath it. Tapping or panning the waveform
seeks, along the wave only: a drag that goes up or down over the bubble is the
reader scrolling the feed. The file bubble uses the same slot: up to 240 wide,
42 high.

One player serves the whole app (`VoicePlayer`), so a message goes on playing
while the reader walks into another chat and its bubble picks the position back
up when they return. The plate of the message being played shows a pause icon
and a speed button stepping ×1 → ×1,5 → ×2; the speed belongs to the player and
carries on to the next message.

## Shader messages

A shader is user code in the Shadertoy dialect of GLSL, carried as a
`ShaderDocument` (the passes of a Shadertoy project with the wiring of their
channels; `docs/protocol.md`). On the device each pass is transpiled to MSL by
`ShaderTranspiler` and compiled once per distinct document (`ShaderProgram`);
`ShaderRenderer` runs the buffer passes into float textures and the image pass
into the drawable, with `iTime`, `iTimeDelta`, `iFrame`, `iResolution`,
`iMouse`, `iDate` and `iChannel0–3` as Shadertoy defines them. A pass reading
its own buffer gets the previous frame; the noise channels are generated on
the device from a fixed seed, so a shader looks the same to the sender and
the peer.

The bubble takes a photo's width at 16:9 with the status capsule over the
picture, and the shader runs at the screen's own scale at 60 fps for as long
as the cell is on screen: `willDisplay` starts it, `didEndDisplaying` and
`prepareForReuse` stop it. While the program compiles the bubble shows a
spinner; a program that failed to compile, or whose command buffer the GPU
gave up on, shows «Не удалось отобразить» and stays that way for the process.

A tap opens the player in a `UIWindow` above the status bar, the way the media
viewer opens: the shader fills the screen, touches become `iMouse`, a tap
toggles the controls (close, source, restart, pause, the clock). The source
sheet shows every pass and copies a one-pass shader as GLSL, a multipass one
as the document's JSON, which the composer accepts back.

The composer opens from «Shader» in the attachment menu: the live preview on
top, a monospaced editor below, the compiler's first error line between them.
Code on the clipboard is picked up on opening; «Send» is enabled once the
program compiled on this device. A pasted Shadertoy JSON export is imported
whole: Image, Buffer A–D, Common, the channel wiring, the wrap and filter of
each sampler. The same composer serves every other surface below, with the
preview in that surface's shape (square, circle, phone) and its action word
(«Прикрепить», «Сохранить», «Установить», «Использовать»); the verdict line
also names the device inputs the code reads (motion, location, microphone,
camera, keyboard, haptics).

### Where else a shader lives

- **The chat background.** «Сделать фоном» in a shader message's menu, or
  «Фон» in the chat info (set, change, remove). Local to this device, per
  chat, kept in `kv`; it runs under the feed while the chat is in front.
- **Behind a text bubble.** «Шейдер пузыря» in the attachment menu opens the
  composer; the chosen shader waits in a strip over the input field with a
  live thumbnail and goes out with the next text message as `bubbleShader`.
  The receiver paints it in place of the bubble colour, clipped to the bubble,
  with white text under a shadow and the time in its capsule.
- **Stickers.** «Стикер» opens the pack: a grid of live tiles, a tap sends,
  the plus writes a new one, a long press removes. A sticker is a square with
  no bubble behind it: the shader's `O.a` decides what shows through. A
  received sticker is saved with «В стикеры»; the pack is local, keyed by the
  hash of the document, so the same sticker saved twice is one tile. A new
  pack starts with the four bundled stickers (`ShaderStickers`: Gloop, Flame
  heart, Orb, Sparkle), seeded once into the same table, so they are removed
  and re-added like any other; Gloop and Orb follow the finger through
  `iMouse`, Sparkle bakes its polygon's distance field in a buffer pass.
- **The avatar.** «Шейдер-аватар…» in Settings (and in a group's info for an
  admin) uploads the document as the avatar blob; every peer's app tells it
  from a picture by the first byte and runs it in the circle, in the chat
  list, the feed and the info screen. The notification extension shows no
  picture for a shader avatar.
- **Effects.** A burst plays out of the send button on every own send and out
  of a bubble when a reaction lands, in a transparent canvas over the feed for
  about a second, with `iMouse.xy` at the event. Two are bundled; Settings →
  «Шейдеры» switches them off or replaces either with the user's code.

### The device as input

Beyond Shadertoy's uniforms a shader reads the phone: `iTouch[5]` (x, y,
force, id) for every finger, `iGyro`, `iAccel`, `iGravity`, `iMagnet`,
`iAttitude` (a quaternion), `iLocation` (latitude, longitude, altitude,
heading), `iPressure`, `iAltitude`, `iProximity`, `iBattery`,
`iBatteryState`, `iDark`, `iTextScale`, `iPencil` (x, y, force, altitude),
`iPencilAzimuth`, `iPencilHover`, `iBubble` (where the canvas sits on the
screen), `iScroll`, `iScreen`, and the palette as `iAccent`, `iBackground`,
`iBubbleIn`, `iBubbleOut`, `iLabel`. The microphone, the cameras and the
keyboard are channel textures (`#pragma msngr channelN mic|camera|
camera:front|keyboard`, or the matching inputs of a Shadertoy export).
`#pragma msngr haptics` turns fragment (0, 0) into the haptic engine's
intensity and sharpness. A sensor starts when the first shader that names it
starts and stops with the last one, so a chat with no such shader asks for
nothing; location and the microphone and camera ask the system's permission
the first time.

### The budget

Four shaders animate at once (`ShaderBudget.maxLive`); the rest render one
frame and hold it. A slot goes by priority (the one the user opened, then the
background, then the feed, then avatars) and by recency, so the message that
just scrolled in runs while the one about to leave stands still.

## The input field

A growing `UITextView` (17 pt, corner radius 18) from 36 pt up to six lines
(142 pt), scrolling beyond that, with the placeholder «Сообщение». The button on
the right is the send arrow when there is text or a locked recording, and the
microphone otherwise.

The attachment menu behind the `plus` icon offers «Фото или видео» and «Файл».

The strip above the field serves both replying and editing, with editing taking
precedence: a title of «Редактирование» or the author's name, a one-line preview
below it, and a cross that leaves the mode. The draft is written to `chat.draft`
on every change and restored when the chat opens if the field is empty. The same
handler sends typing notifications, throttled to 3 s.

## The chat screen

The header carries a 40×40 avatar, the title, and a subtitle that is one of
«подключение…», «печатает…» (with a name, in a group), «N участников», «в сети»
or «был(а) …».

A pinned message gets a bar at the top, and tapping it scrolls to the message.

A magnifier in the header opens search over this chat. The field stands where the
header was, with the keyboard up and «Отмена» beside it; the matches cover the
feed, newest first, each row carrying the author, the time and a slice of the
text with the word highlighted. Tapping a row shows that message in the feed and
leaves a bar in place of the input field: the position in the result («3 из 47»)
and two arrows, up towards older matches and down towards newer ones. Tapping the
position brings the list back. The bar reads «Ищем в переписке…» until both the
first page and the count of all matches are in, «Ничего не нашлось» when the chat
has no such text. «Отмена» closes search and puts the reader back on the message
they were reading when they opened it.

The matches come from the same paged full-text query the chat list runs, scoped
to this chat. A match already in the feed window costs a scroll; one deeper than
it makes the feed load the history between it and the end, so search asks for
that only when a match is chosen.

A message request takes the whole screen in place of the feed: a 96×96 avatar,
the name, the username, «хочет вам написать», the explanation «Сообщения
откроются после принятия», and the buttons «Принять» and «Заблокировать». There
is no input field and incoming messages do not reach the screen. «Принять»
reveals the whole accumulated history; «Заблокировать» deletes the chat locally
and closes the screen.

When the peer's key changes, a banner reads «Код безопасности изменился» and
explains that nothing will be sent until the new key is accepted.

An empty chat shows «Напишите первое сообщение» and a note about end-to-end
encryption.

System messages are rendered as human sentences: `identity_changed:<uid>` as
«Код безопасности собеседника изменился», `undecryptable` as «Сообщение не может
быть расшифровано на этом устройстве».

A group event is a system line too: «Аня добавил(а): Боря», «Боря покинул(а)
группу», «Аня изменил(а) название на «Крыша»», «Аня обновил(а) фото группы»,
«Аня удалил(а) описание группы», «Аня назначил(а) вас администратором». The one
who performed it reads «Вы …», the one it happened to reads «вас», everyone else
reads the name. The line does not raise unread, does not raise a push and does
not move the chat up the list.

In a group where only admins may write, the input bar is replaced by «Писать в
этой группе могут только администраторы».

## Chat info

For a direct chat: the safety number (60 digits in groups of 5, fetching the
peer's key from the prekey bundle if it is not at hand), «Заблокировать», «Без
звука», and disappearing messages («Выкл», «24 часа», «7 дней», «90 дней»,
delivered as a `disappearing` service message).

For a group: the member list (an admin marked «админ»), adding a member through
search, an invite link with a copy button, and leaving the group. A swipe over a
member row gives an admin «Удалить» and «Сделать админом» / «Снять админа».

An admin also gets the title and the group photo, a description under «Описание»
with a save button, and «Права участников»: «Кто может писать» and «Кто может
приглашать», each of them «Все участники» or «Только администраторы».

What a member cannot do is not shown to them at all, rather than shown disabled:
without the right to invite there is no «Добавить участника» and no invite link,
a plain member sees the description as plain text and no «Права участников»
section, and a swipe over a member row offers nothing. Every change is announced
in the feed as a group event once the server has accepted it.

## The chat list

A row holds a 54×54 avatar with an online dot, the title (the peer's name for a
direct chat), the mute icon, the ticks of the last message (only when it is
outgoing), the time (`HH:mm` today, the weekday this week, `dd.MM.yy` otherwise),
the preview and the unread badge. The badge and the pin icon are mutually
exclusive: with nothing unread, that spot holds the `pin`.

The preview goes by priority: an unaccepted request, then typing, then
«Черновик: …», then the last message («Сообщение удалено», «Фото», «Видео»,
«Голосовое сообщение», the file name, «Альбом», otherwise the text). Media
previews are drawn as SF Symbols in the accent colour, and system messages never
reach a preview. An unaccepted request shows «Новая заявка» instead of a preview
and carries neither an unread badge nor ticks.

Sorting puts pinned chats on top and orders the rest by `lastActivityAt`.
Requests and the archive are separate sections, and a request outranks the
archive. Swipes: archive and mute from the right, pin from the left; «Принять»
and «Заблокировать» among the requests; «Из архива» in the archive. Every action
is written to the local database first and goes to the server afterwards.

Tabs are folders: a rule plus the chats put in and taken out by hand. A chat can
live in any number of them, and the archive and the requests appear only in
«Все». Membership is computed once per chat-list emission, so switching a tab
does not go to the database. A long horizontal swipe over the list switches tabs
while a short one stays with the row's swipe actions, which is why a row has no
full swipe.

Search is one field over three sections. «Чаты» matches the title and the peer's
username across active and archived chats, filtered on each keystroke out of the
list already loaded. «Сообщения» is full text over `messageFts`, paged, newest
matches first, each row showing a slice of the text with the word highlighted;
tapping one opens the chat on that message. «Люди» is the same server search the
new-chat screen uses, from two characters. The slow sections run after a pause in
typing and do not hold up the chats; while messages are being searched their
place reads «Ищем в переписке…». An unaccepted request does not appear in text
results.

The empty state is «Нет чатов» with a «Начать переписку» button.

New chat: search by username or name from two characters; contacts are synced
only on an explicit tap of «Найти по контактам» (number → E.164 → SHA-256 →
discover), and a name from the address book wins over the server's; a group mode
takes a title and a set of members.

## Themes

Three palettes, chosen in settings under «Оформление» through preview cards and
stored in `UserDefaults` under the key `palette`, defaulting to `graphite`:

- `iMessage` — a neutral light background, blue outgoing, grey incoming;
- `Telegram` — a background with a faint green cast, mint outgoing, blue accent;
- `Графит` — a cream background, indigo outgoing, orange accent.

Each palette defines the chat background, the bubble colours, the accent, the
colour of read ticks, and the text and metadata colours of an outgoing message,
separately for light and dark. Switching palettes clears the bubble background
cache, posts `paletteChanged` and forces a `reloadData()` on the feed.

## Text size

Every size is a named role in `Theme.Text`, scaled through `UIFontMetrics` with a
ceiling per role: the feed's ceilings are high, the header's and the chat list's
are low, because their heights are fixed. Feed measurement happens outside the
view hierarchy, so the size category comes from the `TypeScale.category` snapshot
rather than `UITraitCollection.current`. A size change drops the plan cache,
re-measures the feed and puts the reader back where they were.

## Notifications

- App active, chat not open — an in-app banner of our own at the top: its own
  window, hidden after 3.5 s, tap opens the chat, swipe up dismisses it.
- App active, chat open — nothing.
- A system push that catches up is suppressed in `willPresent` when the chat is
  open, a banner for that msgId has already been shown, the message is already
  in the database, it is already read, or the chat is muted.
- In the background there is no in-app banner; the system push shows.
- The badge number is computed by the server and stamped with a counter, and it
  travels in the push payload. On the device it lives as a single row
  (`BadgeStore`); the app writes its own local unread total into the same row
  and a value overtaken by a later stamp is discarded. Clearing a chat's unread
  count also withdraws that chat's delivered notifications from the shade.
- For an unaccepted request the banner carries the sender's name and «Новая
  заявка» in place of a preview.

## PIN and privacy

A four-digit PIN, stored as SHA-256(salt + pin) in `UserDefaults`. Face ID is a
separate switch and is offered automatically on the lock screen. Auto-lock
triggers on returning from the background after more than 30 seconds, and
launching with a PIN set locks immediately. In the app switcher an
`ultraThinMaterial` with the app glyph covers the content.
