# List-entry counts: live run 2026-08-31

## Stand

Own simulator `counts-a` (iPhone 17, deleted after the run per the housekeeping
rule — do not touch the owner's or the gate-runner devices), the app built with
`MSNGR_APP_ID=msngr.msngr` (an unset value produces an empty
`CFBundleIdentifier` and a silent install failure) and installed fresh. The
`alfa` fixture from `scripts/fixture.py` against the shared stand
(`msngr.a-kuz.online`), one session (this simulator).

## Run

| # | Scenario | Status |
|---|----------|--------|
| 1 | Settings → Blocked users / Active devices show a count | PASS |
| 2 | Chat info → Attachments row shows a count | PASS |
| 3 | Chat info → Members section header shows a count | PASS |
| 4 | Gallery tabs (Media/Files/Voice/Links) show a count each | PASS |

## Details

### 1. Settings counts, PASS

`docs/qa/runs/2026-08-31-counts/settings-security.png`: "Заблокированные" reads
0, "Активные устройства" reads 1. Verified by hand: opening "Активные
устройства" (`docs/qa/runs/2026-08-31-counts/settings-devices-list.png`) lists
exactly one row ("fixture", added 30 August 2026), matching the count — alfa's
fixture has no blocked users and this is its only session.

### 2 and 3. Chat info counts, PASS

Opened the `Design` group (3 members, no attachments in the seed data).
`docs/qa/runs/2026-08-31-counts/chatinfo-attachments-members.png` shows
"Вложения 0" and "Участники 3" in one frame.
`docs/qa/runs/2026-08-31-counts/chatinfo-members-list.png` verifies the second
number by hand: the member list right below the header holds exactly 3 rows
(Alfa, Bravo, Charlie Service).

### 4. Gallery tab labels, PASS

`docs/qa/runs/2026-08-31-counts/gallery-tabs.png`: the segmented control reads
"Медиа 0", "Файлы 0", "Голосовые 0", "Ссылки 0" — the empty state matches, since
the seeded conversation carries no media, files, voice messages or links.

## Not covered

No non-zero attachment/link count was available to check by hand: the seeded
`alfa`/`bravo`/`charlie` fixtures carry no media, files, voice notes or links in
their history. The zero case and the two non-zero cases above (1 device, 3
members) were verified instead.

## Note on tooling

After `scripts/fixture.py install ... --launch` (which reboots the simulator to
apply the notification-permission grant), `idb` keeps reporting the target as
booted with a companion socket, but touches stop landing until `idb connect
<udid>` is run again. A tap that visibly does nothing twice in a row is worth
checking against the aim shot before assuming it is a coordinate problem — here
it was a dead companion connection instead.
