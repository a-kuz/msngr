# Tap atlas

Coordinates are in points, for `idb ui tap`/`scripts/grid.py --tap`. Valid for
the default text size and portrait orientation. If the screen doesn't match a
coordinate here, run `scripts/grid.py <udid>` first and re-aim — don't guess.

A new row goes in only after a tap confirmed real effect on both devices
(screen changed, field took focus, alert closed) — or a note that the control
doesn't exist on one of them. Coordinates below were captured against
`atlas-phone` (iPhone 17, 402×874 pt) and `atlas-pad` (iPad Pro 11-inch M4,
834×1210 pt), both on the shared stand, default text size, English keyboard.

Caveat found while capturing this atlas: the iOS system notification-permission
alert (`UNUserNotificationCenter` prompt) cannot be tapped through
`idb ui tap` — same class of limitation as the status-bar tap documented in
`CLAUDE.md` (`MsngrTests/StatusBarTapTests`). It's SpringBoard-owned, not
in-app. Grant it ahead of time with `scripts/fixture.py grant <udid>` instead
of tapping through it.

## Registration

| control | iPhone 17 (pt) | iPad Pro 11 (pt) |
|---|---|---|
| Username field | (200, 410) | (417, 492) |
| Name field | (200, 455) | (417, 538) |
| "Создать аккаунт" button | (200, 500) | (417, 494)¹ |
| "Уже есть аккаунт — войти по коду" link | (200, 565) | (417, 651) |
| "Восстановить из резервной копии" link | (200, 600) | (417, 687) |

¹ iPad button position shifts up once the fields are filled and validation
kicks in (from y≈575 empty to y≈470 filled) because the helper text under the
username field disappears; use `describe-all`/`grid.py` to re-check when
retargeting rather than trusting a single cached y.

Registration was completed for real on both devices: `atlasphone01` /
"Atlas Phone" and `atlaspad01` / "Atlas Pad", both against
`https://msngr.a-kuz.online`.

## Chat list

| control | iPhone 17 (pt) | iPad Pro 11 (pt) |
|---|---|---|
| Settings gear | (38, 84) | (32, 54) |
| New chat (compose) | (364, 84) | (542, 54) |
| Search field | (201, 822) | (700, 54) |
| "Все" tab | (36, 188) | (36, 158) |
| First chat row ("Избранное") | (200, 235) | (400, 220) |

The iPad chat list keeps the search field permanently in the header (next to
compose), not as a scrollable row at the bottom like on the phone.

## Chat screen (opened via "Избранное")

| control | iPhone 17 (pt) | iPad Pro 11 (pt) |
|---|---|---|
| Back button | (38, 84) | (32, 54) |
| Chat header (title) | (200, 84) | (417, 54) |
| Message input field | (201, 814) | (417, 1159) |
| Attach button | (26, 816) | (26, 1161) |
| Microphone icon | (376, 816) | (808, 1161) |
| Send button (appears once text is entered) | (375, 514)¹ | (807, 846)¹ |

¹ The send button only exists while the input has text, and the input row
moves up above the keyboard once it's focused — these y-coordinates are for
the keyboard-open layout, not the resting one. Re-derive with
`idb ui describe-all` (`AXUniqueId: chat.send`) rather than reusing a cached
number if the keyboard height differs (e.g. a different keyboard language).

## Settings

Reached via the gear icon on the chat list. On iPhone it's a full-screen push;
on iPad it opens as a sheet, and its own "Готово" close button moves with it.

| control | iPhone 17 (pt) | iPad Pro 11 (pt) |
|---|---|---|
| "Готово" (close) | (343, 100) | (654, 307) |
| Username row (Юзернейм) | (200, 364)¹ | not re-verified¹ |
| "Шейдер-аватар…" row | (200, 825)¹ | not re-verified¹ |

¹ Seen and read off `describe-all` on the phone but not tap-confirmed on
either device — don't rely on these two until someone actually taps them and
checks the screen changes.

## Known idb/simulator gotchas hit while building this atlas

- A fresh `atlas-*` simulator inherits the host's keyboard input source
  (Russian, on this machine) through Simulator.app's "Use the Same Keyboard
  Language as macOS" — `idb ui text` then types Cyrillic transliterations of
  Latin input instead of the Latin text. Fix: Simulator app menu bar → I/O →
  Keyboard → uncheck "Use the Same Keyboard Language as macOS" and uncheck
  "Connect Hardware Keyboard" (this shows the on-screen keyboard again), then
  tap a text field and use the globe key to pick "English (US)" before typing.
  This is a per-window (per Simulator app front window) menu state, not a
  device setting — repeat it for every simulator window, and after any
  Simulator.app restart.
- `idb ui key <code>` sent too fast in a `seq` loop (no delay) drops most of
  the events; add a short `sleep` between repeated key presses (e.g. repeated
  backspaces) or they silently don't reach the field.
