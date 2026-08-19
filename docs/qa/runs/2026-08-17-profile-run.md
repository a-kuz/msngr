# Registration and the profile card: the button, the avatar, the rename

Run date: 2026-08-17, finished 2026-08-18. No screenshots kept.

## Stand

Own simulators `profile-a` (2EBA8AFF) and `profile-b` (662C3DAC), both iPhone 17
on iOS 26.5, deleted after the run. Own `wrangler dev` on :8820 with
`--persist-to ~/.msngr/stands/profile` outside the repository, migrations applied
into it; both apps launched with `SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8820`.
Two real accounts with real keys: `anna_p` («Анна Ким») on A, `boris_v`
(«Борис Волков») on B, so every message and every profile frame in this run
crossed a real socket. Both devices driven through the accessibility tree with
`idb`; text went in through the pasteboard because `idb ui text` types HID
keycodes and this host's layout turns Latin into ЙЦУКЕН («anna_p» arrived as
«фттф_з»).

Graphite palette, the default. Contrast figures below are sRGB relative
luminance ratios computed from the colour values in `Theme.swift`, not eyeballed.

## The disabled button was unreadable in the light appearance only

The old button painted the accent at 40% opacity and the white label at 85%.
Composited, that is 1.4:1 label against fill in the light appearance — the
screenshot shows a pale orange slab with a suggestion of text on it. In the dark
appearance the same code gives 8.4:1, because the accent at 40% over black comes
out dark; the design review saw one appearance and the defect was real in that
one.

The enabled state was wrong too, and nobody had written it down: white on the
graphite orange is 2.88:1, under the 3:1 floor even for large text.

Now both states come from named roles (`controlFill`, `controlLabel`,
`controlFillDisabled`, `controlLabelDisabled`) through one `PrimaryActionButtonStyle`:

| state | fill | label | ratio |
|-------|------|-------|-------|
| disabled, light | grey 0.88 | grey 0.35 | 5.31:1 |
| disabled, dark | grey 0.24 | grey 0.70 | 5.14:1 |
| enabled, graphite | accent | near-black | 6.00:1 |

Seen live in both appearances and at `accessibility-extra-extra-extra-large`.
The style has no fixed 48 pt height — a minimum height plus vertical padding that
scales with the size category — so at the largest size the box grows and
«Создать аккаунт» sits inside it whole instead of being clipped. Checked with the
form both filled and empty at that size.

The button still says nothing about why it is off, so each field now says it for
itself, and only once its value is wrong: `Юзернейм — от 3 до 32 символов:
латиница, цифры и _` appeared under the field as typed, and went away when the
value became valid. Registration errors no longer surface server codes; a taken
handle reads «Юзернейм занят» and anything else «Не удалось создать аккаунт».

## The avatar never reached anybody, including its owner

`AvatarView` fetched the picture with `AsyncImage` straight off
`GET /api/avatar/<id>`, and that route is behind the device token. Proven rather
than assumed: on the stand the same id answered 401 without an `Authorization`
header and 200 with one. `AsyncImage` sends no headers, so no avatar had ever
rendered anywhere — not at the peer, not in your own settings. The screenshots in
`design-review 08-settings` show initials.

`AvatarView` now goes through `AvatarCache`, which downloads with the token and
leaves the file in the app group container where the notification extension reads
it as well, and through an `AvatarImageLoader` actor that decodes once, keeps 200
images in an `NSCache` and collapses concurrent asks for the same id into one
download. A file whose bytes do not decode is discarded so the next ask
re-downloads instead of failing on the same bad file.

Two-device result. Anna picked a photo in her settings; `POST /api/avatar` 200,
and her own settings row showed the picture immediately. On Boris's device, with
no restart and no user action, the row in the chat list turned into the photo, and
so did the header when he opened the chat: one `GET /api/avatar/<id>` 200 in the
stand log, and the file written into his app group container. After a full app
restart the picture came back with no request at all — read from that file.

That live delivery needed the server side, which did not exist: a card change
reached nobody. `POST /api/profile`, `POST /api/username` and an own-avatar upload
now broadcast the whole public card (`{t:"profile", user}`) to the actor's other
devices and, through each of their conversations, to every member except the
actor, skipping blocked peers. The client writes the row in `SyncEngine`; the chat
list and the chat header re-emit from that row on their own, so nothing refetches
and no new stream was needed.

Feed: the request said "and in the feed", and there are no avatars in the feed by
design — `docs/ui-spec.md` says so and the ROADMAP lists sender avatars in the
feed as planned. Nothing about that changed here.

## Renaming

`POST /api/username` validates through the same `isValidUsername` as registration
and does one `UPDATE users SET username = ?`, so the new handle is taken and the
old one released in a single statement under the same `UNIQUE COLLATE NOCASE`
index; a conflict comes back as 409 `username_taken`. There is no window in which
both names are held or neither is.

Live from the new «Юзернейм» screen in settings. `boris_v` gave 409 and the footer
turned into «Юзернейм занят» in place of the hint, with the value left in the
field. `anna_kim` gave 200 and settings showed `@anna_kim` at once. The session
file was rewritten without re-bootstrapping — a rename should not drop the socket
over a name — and Boris's device, over the same profile frame, ended up holding
`anna_kim` in its own `user` row.

The freed handle was registrable immediately: `POST /api/register` with `anna_p`
returned 200 straight after the rename, and a second attempt with the same handle
returned 409. Both directions are also covered in the smoke.

## Required or optional name

Decided as required, one option instead of the fork. What the code showed: the
register screen already refused an empty name through `formValid`, while the
server filled `display_name` with the username when the field was empty, and the
settings screen let a name be erased entirely. Three places, three answers.

The name is the only spelling of a person that the product ever shows — a handle
holds no Cyrillic and no spaces — and every screen that names somebody (the chat
list row, the chat header, the banner, a group member) reads `displayName`. So it
is required everywhere: `isValidDisplayName` on the server rejects an empty or
whitespace-only name and stores it trimmed, `AccountValidator` is the one client
rule for both screens, and settings refuses to save an empty name with the hint
under the field.

The floor is one character, not three: «Ян» and «Li» are names, and a floor of
three refused them. Ceiling 64.

## What was not covered

`make check` was not run. The host is at 99% of its disk (7.7 GB free against the
100 GB floor `tidy.py` asks at) with a load average around 930; simulators died
mid-command twice and `simctl boot` came back with `ipc/mig server died`. A gate
under that says nothing about the code. Server `tsc --noEmit` is clean and
`scripts/smoke-stand.sh` passed with the 15 new checks; the iOS build succeeded
before the host went down. The gate itself is still owed.

`anna_p` got registered once on the shared stand on :8787 by accident — the app
on `profile-a` was launched without `MSNGR_SERVER` and fell back to the default
port. There is no account-deletion route, so that row is still there; I did not
touch `server/.wrangler` to remove it.

The rename was seen on one device per account. Nothing here proves what a second
device of the *same* account does with a rename, though the broadcast sends the
card to the actor's other sockets by the same path.

The notification extension was not exercised: `simctl push` does not launch it on
the simulator, so the avatar in a banner is unverified.
