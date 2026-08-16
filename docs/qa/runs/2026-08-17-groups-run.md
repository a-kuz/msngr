# Managing a group from the interface

An admin changes the title, the photo, the description and the two rights of a
group; grants and takes back the admin role; a member leaves. Every change is
published to the group as a service frame and lands in the feed as a system
line. A member who cannot do a thing is not shown it at all.

Screenshots — `2026-08-17-groups/`. Run date: 2026-08-17.

## Stand

Three own simulators, iPhone 17, iOS 26.5, shut down after the run: `groups-a`
(2153A12C) as `ganna`, `groups-b` (4B358094) as `gboris`, `groups-c`
(8ADEBB42) as `gvera`. Own `wrangler dev` on :8894 with `--persist-to` outside
the repository; all three apps launched with
`MSNGR_SERVER=http://localhost:8894`. Build from the working tree.

Аня created the group «Крыша дома» from the interface and picked both members,
so she is its admin. The DEBUG button seeded 1000 messages into it: the events
had to be read at the end of a real feed, not in an empty one.

Display names are Cyrillic. The simulator's input source is Russian and cannot
be switched, so ASCII text goes in through `simctl pbcopy` and the field's
Paste, and Russian text by typing the ASCII key that sits on the same ЙЦУКЕН
position.

## Run

Every row is one change on Аня's device and what the other two saw without
being reloaded.

| Step | Expectation | Fact |
|------|-------------|------|
| rename the group | the new title everywhere, a line in the feed | «Аня изменил(а) название на «Крыша дома»» on both peers (`04`) |
| write a description | it appears for everyone who opens the info | «Аня изменил(а) описание группы», text «Про дачу» on the peers' screens |
| set a group photo | the picture reaches the peers | the event arrived at once, the picture only after the fix below (`09`) |
| «Кто может писать» → «Только администраторы» | the members lose the input bar | «Писать в этой группе могут только администраторы» in place of the bar on both (`02`) |
| «Кто может приглашать» → «Только администраторы» | the members lose the invite actions | «Добавить участника» and «Ссылка-приглашение» gone from the members' info (`07`) |
| «Сделать админом» on Боря | he gains the admin's screen and the input bar | «админ» next to his name for everyone, rights and invites appear on his own screen, «Аня назначил(а) вас администратором» (`04`) |
| «Снять админа» on Боря | everything above goes back | the mark gone on A and C, the read-only note back on B, «Аня снял(а) с вас права администратора» (`02`) |
| Вера taps «Покинуть группу» | the event is published before the membership goes | «Вера покинул(а) группу» on A and B, header «2 участников», Вера's list empty (`08`) |

## The wording of an event

The same event reads differently depending on who reads it. The actor sees «Вы
сняли права администратора: Боря» (`01`), the member it was done to sees «Аня
снял(а) с вас права администратора» (`02`), and a third party sees «Аня
снял(а) права администратора: Боря» (`03`). Gender is avoided with the «(а)»
ending, because the profile has no gender to read.

The payload carries the actor's name, the member's name and the member's id
next to the verb. A line about someone who has since left the group still
reads: nothing has to be looked up in a membership list that no longer holds
them.

## What a member without rights sees

Nothing disabled. Вера's info screen (`07`) goes from the member list straight
to «Очистить историю» and «Покинуть группу»: no «Права участников» section, no
«Добавить участника», no «Ссылка-приглашение», the title is a label rather than
a field, the group photo has no camera badge, and a swipe over a member row
offers nothing. An admin gets the same screen with all of it (`05`), and the
swipe over a row gives «Снять админа» and «Удалить» (`06`).

## The event raises no unread and no push

The four events arrived at Боря with his chat closed. The list showed no badge
and the chat kept the place and the preview its last real message gave it
(`09`); `chat.unreadCount` stayed at 0 and the `badge` row at 0. The stand's log
recorded no APNs attempt for any of them.

As a control, one ordinary message was then sent into the same group with the
same chat closed: `unreadCount` 1, badge 1, and an `apns:` line in the log at
once (the stand has no receiver on :9894, so it is an error line). So the
silence above is the service flag, not a dead push path.

`groupEvent` is service on the wire and still leaves a row. It sits in
`SyncEngine.serviceKinds` with `edit`, `reaction` and `disappearing`, and it is
the one kind subtracted in `rowlessKinds`, which is what the feed reads.

## The avatar arrived but did not show

The photo of the group reached the peers as an `avatarId` and as an event line,
and the row kept drawing initials. The stand's log had the answer:
`GET /api/avatar/<id> 401 Unauthorized`. `AvatarView` loaded the picture with
`AsyncImage` from a bare URL, and every `/api/*` route is behind authentication.
It now goes through `AvatarCache`, which carries the token and keeps the file
the notification extension needs anyway; `APIClient.avatarURL` had no other
caller and is gone. After the rebuild the picture is in the list, in the header
and on the info screen of all three devices.

## Not covered here

Removing a member by swipe: the action is on the row and was seen, but never
tapped — the group had three members and each of them was needed to the end of
the run.

Adding a member and the invite link from the info screen as an admin. Members
were picked at creation instead.

The push itself on a device. `simctl push` does not start the NSE on a
simulator, and group events raise no push anyway.

An observation from the way, outside this run's scope: `/api/users` search
matches with SQLite's `LOWER()`, which only folds ASCII, so «Боря» is not found
by «боря» while «оря» finds him. The comment at `server/src/index.ts:333`
claims the opposite.
