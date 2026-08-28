# Code map: adding a message kind (for shader messages)

Collected 2026-08-28 before designing the `shader` kind. Paths and line
numbers are as of commit 7d69262.

## Content kinds on the wire and in the database

- `ContentPayload` (`ios/MsngrKit/Sources/MsngrCore/Models.swift:263-297`) is
  the plaintext of a content frame: `kind: String` plus a flat bag of optional
  fields (`text`, `media`, `album`, `replyTo`, `fwd`, `targetSeq`, `emoji`,
  `ttlSeconds`, ...). JSON keys are the property names. The same struct is
  serialized into `OutboxItem.payload`.
- There is no enum of wire kinds; the strings are literals at the construction
  sites (`grep 'ContentPayload(kind:'`: ChatViewModel.swift, ChatScreen.swift,
  ChatInfoView.swift, SyncEngine.swift, AttachmentSeed.swift).
- `MessageKind` (`Models.swift:112-114`): `text, photo, video, file, voice,
  album, contact, system`. Persisted in `message.kind`; decoded with a silent
  `?? .text` fallback at `Database.swift:511`, `SyncEngine.swift:1412/1483/1814`,
  `MessageSearch.swift:159`. An unknown wire kind therefore renders as text on
  a client that does not know it.
- `ReplyPreview.kind` (`Models.swift:154`) is a string copy of the kind,
  re-parsed in `BubbleLayout.swift:431`.
- `SyncEngine.serviceKinds` / `rowlessKinds` / `recordedServiceKinds`
  (`SyncEngine.swift:1769-1781`). A user-visible kind stays out of all three.
- The server is content-kind-blind (`server/src/types.ts` knows chat kinds and
  typing/receipt kinds only).

## Feed: one cell class, variation in the plan

- Cell registration: `ios/Msngr/Chat/MessagesViewController.swift:115-118`
  (`MessageCell`, `DateSeparatorCell`, `SystemCell`, `UnreadMarkerCell`).
  Routing in `cellForItemAt` (`:758-790`): only `.system` gets its own cell.
- Height comes from `plan.cellHeight` (`:794-818`, and `:448` for in-place
  updates).
- `BubbleLayoutPlan` (`ios/Msngr/Chat/BubbleLayout.swift:6-39`), all frames
  precomputed off the main thread. `plan(for:)` at `:98` with an NSCache keyed
  by `cacheKey` (`:91`, encodes text/status/edited/reactions/deletedForAll).
  The per-kind switch is `compute` at `:173-219` (`.photo, .video`, `.album`,
  `.voice`, `.file`, default).
- `MessageCell` (`ios/Msngr/Chat/MessageCell.swift`) places fixed subviews
  from the plan: text `:314`, media `:456`, voice/file `:360-366`. A `file`
  message reuses `voiceFrame` (`BubbleLayout.swift:210`) and
  `VoiceMessageView` switches on the kind (`ios/Msngr/Chat/Voice.swift:423,
  471, 628`). That is the precedent for a new content view.
- `FeedWindow` is kind-agnostic. Cells are recycled and the window slides, so
  a live view must start and stop with `prepareForReuse` and visibility.

## Composer

- Attachment menu: `ios/Msngr/Chat/InputBar.swift:61-81` (SwiftUI `Menu`:
  photo, file, paste). Callbacks wired in `ios/Msngr/Chat/ChatScreen.swift:86-87`.
- Pickers: `ChatScreen.swift:206` (`.photosPicker`), `:213` (`.fileImporter`).
- Send paths in `ChatScreen.swift`: `sendPicked` `:797`, `sendImages` `:837`,
  `sendPhotoSources` `:848`, `stash` `:1002`, `sendFile` `:1009`, `sendVoice`
  `:1024`.
- Two routes into the core: the simple one (`ContentPayload` →
  `ChatViewModel.enqueue` ~`:760` → `SyncEngine.enqueue` `:1809`, message row +
  outbox row in one transaction) and the staged media one
  (`beginMedia` / `updateMediaPreview` / `finalizeMedia`,
  `SyncEngine.swift:1843-1858`).
- `PickedBatch.kind(of:)` (`ios/Msngr/Chat/PickedBatch.swift:10`).
- Seeding every kind for a quick look: `ios/Msngr/Screens/AttachmentSeed.swift:72-143`.

## Preview and banner text

- Chat list row: `ios/Msngr/ChatList/ChatRowView.swift:108-131`
  (`switch last.kind`, `default: Text(last.text ?? "")`).
- Push banner / NSE: `ios/MsngrKit/Sources/MsngrCore/NotificationContent.swift:131-147`,
  `preview(_ payload:)` switching on the raw kind string; `build(message:)` at
  `:121` re-wraps a `Message` to reuse it.
- Reply quote: `ChatViewModel.previewText(_:)` (`ChatViewModel.swift:837-846`).
- Also `ChatSearchResults.kindIcon(_:)` (`ios/Msngr/ChatList/ChatSearchResults.swift:170-179`)
  and `GalleryTab.kinds` (`ios/MsngrKit/Sources/MsngrCore/ChatGallery.swift:12-19`).
- Localization: app catalog `ios/Msngr/Localizable.xcstrings` (via
  `String(localized:)` / `Text`), core catalog
  `ios/MsngrKit/Sources/MsngrCore/Resources/Localizable.xcstrings` read through
  `CoreStrings.string(_:)`; the NSE strings live in the core catalog.

## Protocol doc

`docs/protocol.md:362-392`: the `ContentPayload` block and the kind list at
`:369-371`. `:180-186` describes the `service: true` flag.

## Metal

Not used anywhere in `ios/`: no `MTKView`, `MTLDevice`, `CAMetalLayer`, no
`.metal` files. `ios/project.yml` declares sources as whole directories
(`sources: [Msngr]`), no `frameworks:` key; Metal/MetalKit are auto-linked
by `import`. Runtime MSL compilation is `MTLDevice.makeLibrary(source:options:)`.
Deployment target iOS 17.0.

## Per-chat visual settings

None exist. Theming is global (`Palette` in `ios/Msngr/App/Theme.swift:5-11`,
`ThemeStore` at `:118`, picker in `Screens/SettingsView.swift:339`). Per-chat
state lives as columns on the `Chat` row (`Models.swift:32-84`) and in the
`kv` table (`Database.swift:168`).
