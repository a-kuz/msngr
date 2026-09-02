# The notification extension on the simulator — live run, 2026-09-02

Main at 63205d7 plus the mute-queue and photo-preview changes committed right
after this run, against the shared stand (`msngr.a-kuz.online`, real APNs
through the relay on adad). Two simulators: `gate-runner` as bravo,
`fable-charlie` (28CE558E) as charlie, both on a fresh fixture trio
(`fixture.py seed --reset`). The receiver's app is killed with
`simctl terminate` before every send; the sender writes from the app.

## What was in the way, and what it was

1. **The push for a killed app waited at Apple.** Two sends were accepted by
   the relay (200) and delivered only when the receiver's app came to the
   foreground minutes later. SpringBoard's log showed the reason: the app's
   topic moved `Enabled → NonWaking` on every background, where the owner's
   simulator moved it `Enabled → Opportunistic`. The difference was the
   notification grant `fixture.py install` writes by hand: the archived
   section still carried `sectionID = ai.enface.Msngr` while the store key
   was `com.msngr.msngr`. With the id inside the blob fixed
   (`scripts/assets/notification-grant.bplist`) the topic goes opportunistic
   and pushes reach the killed app.
2. **`can be modified: 0` on gate-runner.** Even with the push delivered,
   SpringBoard skipped the extension there. `pluginkit -m -v -p
   com.apple.usernotifications.service` listed four registrations of our
   extension, two of them from old bundle ids at app paths long gone; after
   `pluginkit -r <path>` on the stale two, one current entry is left. A fresh
   simulator never has the problem.
3. **A mute from the banner was lost locally.** See below.

## The journal

`nse-journal.log` of charlie's group container, the app killed throughout
(seq 6/7 arrived minutes after the send, the topic still non-waking at the
time; 13/14 within a second of it):

```
received  …/seq 6   envelope        stored  stored     answered  show
received  …/seq 7   envelope        stored  stored     answered  show
received  …/seq 9   envelope        stored  stored     answered  show
received  …/seq 10  envelope        stored  stored     answered  show
received  …/seq 13  envelope        stored  stored     answered  show
received  …/seq 14  envelope        stored  stored     answered  show
                                                       answered  preview:attached
```

Every push was answered with the message written first; the rows were in
`message` before the app was next opened.

## What was verified

- **The receipt with the app killed.** The stand logged
  `POST /api/chats/direct:…/recv` from charlie's device at 16:32:52 UTC and
  again at 16:38:05, with no app process alive: the extension's queue flush.
- **Decrypt and write in one transaction, previews from the row.** The
  banner text is the decrypted message («Тыу лшддув фзз 1933» — the simulator
  keyboard's Russian layout over Latin input; the bytes match the sender's
  bubble), «📷 Фото» for the photo.
- **One banner per message.** Two pushes, two banners in the stack, none
  repeated after the app opened.
- **Quick reply.** The expanded banner is reachable on the simulator without
  the context-menu press: a short swipe on the banner in Notification Center
  → «Смотреть» → «Ответить». Typed «quick reply 1937» with charlie's app
  killed; the app launched in the background, the row got seq 8 on charlie
  and seq 8 on bravo's side.
- **Mute from the banner.** First run: `POST …/flags` reached the server
  (muted: true) but the local row read `muted = 0` until the next relaunch.
  The stand log shows why: the background launch fetched `GET /api/chats` a
  second before the flags POST, and the snapshot's `upsertChatState` wrote
  the server's old `false` over the local `1`. Fixed by sending the mute
  through the action queue (`SyncEngine.setMuted`, `pendingAction` type
  `mute`) and having the snapshot keep `muted`/`mutedUntil` while such an
  action is queued, the way it already keeps a queued pin (`MuteActionTests`).
  Re-run: the snapshot landed at 17:00:46, the POST at 17:00:47, the local
  row stayed `1` through both and the queue drained; `GET …/flags` answered
  `muted: true`. The muted chat then produced no pushes at all for the next
  two sends (the relay logged nothing), which is the server's side of the
  same flag.
- **The photo preview.** The extension fetched and decrypted the photo in
  0.35 s (`preview:attached`); SpringBoard logged
  `Will deliver mutated notification content … attachmentCount=1`, and the
  expanded banner shows the picture. The collapsed row in the stack shows
  the text only.

- **The group avatar.** The Design group got a picture through
  `POST /api/avatar?chatId=` as alfa; charlie's app cached it on its next
  launch, was killed, and bravo wrote to the group. The banner shows the
  group's picture with the app icon in its corner, «Bravo Service» over
  «Design» and the text; the extension's log has the intent image persisted.
- **A request from a stranger.** `msngrfixture knock` from a fresh account to
  charlie with the app killed: the journal answered `stored unknownChat` and
  the banner was the neutral «Msngr / Новое сообщение» — the device had no
  row for the chat or the person, and nothing to name them by. Fixed on both
  sides: the user object keeps the roster's public names as the chat frames
  carry them and puts `fromName` into the push (smoke «push carries the
  sender's name»), and the extension writes an unknown direct chat between
  this user and the author as the request it is, decrypts the message into it
  and shows «<name> / Новая заявка» (`RequestPushAdoptionTests`). Re-run with
  the stand on 0872a16 and the client rebuilt: a knock from «Echo Service» to
  the killed app gave `received envelope → stored → show`, the row
  `direct:… isRequest=1 iAccepted=0` with the author's name in `user`, and the
  banner «Echo Service / Новая заявка».

- **A reaction with the app killed.** Bravo long-pressed charlie's «Same
  here.» in Design and tapped 👍. The relay logged one push, to charlie's
  token alone (the frame named the target's author, `notifyUser`); the
  journal answered `stored → show`; charlie's row carries
  `{"👍": [bravo]}` before the app opened; the banner reads «Bravo Service /
  Design / Реакция 👍 на «Same here.»» under the group's picture.

- **The sound of a reply to you.** Bravo replied to charlie's «Same here.»
  in Design with charlie's app killed. The journal answered `stored → show`,
  and SpringBoard's store of delivered notifications
  (`Library/UserNotifications/…/DeliveredNotifications.plist`) holds the
  banner with sound `chime3.caf`, the default of the new «Sound: mentions and
  replies» setting; the plain messages before it carry the push's own sound.

- **A muted chat with the app closed.** Charlie muted Design (server flag
  and local row) and was killed. Bravo's plain message reached the relay as
  a push with no sound field and `muted: 1`; the journal answered
  `stored → skip:muted`, no banner, the row in the database. Bravo's reply to
  charlie's «Same here.» in the same muted chat answered `stored → show`: the
  banner «Bravo Service / Design / …2119» stands in the stack, the plain one
  does not.

- **A burst.** Five `msngrfixture send` processes fired in parallel from
  alfa's free home to the killed charlie; the relay logged the five pushes
  within one second (18:59:09–10 UTC). The journal shows the simulator's
  SpringBoard handing them to the extension strictly one at a time: every
  `received` is stamped ~10 ms after the previous `answered`, and each push
  waited the full 1.5 s window alone before `stored → show`, five banners
  over eight seconds, in seq order. On this platform the window buys nothing
  and costs its length per banner; whether a device enters `didReceive` in
  parallel is the one thing the batch path still needs a device for.

## Not run here
- The group avatar and the sender's avatar in the banner: the fixture
  accounts carry no avatar. The sender's avatar was seen by the owner on
  their own account earlier the same day.
