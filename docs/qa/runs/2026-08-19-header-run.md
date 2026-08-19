# The chat header, the quote strip and the edit mode

Everything the header says about the peer, and the one strip above the input
that carries two different modes. All of it was marked done and none of it had
been seen running.

Screenshots — `2026-08-19-header/`. Run date: 2026-08-18 into 2026-08-19.

## Stand

Two own simulators, iPhone 17, iOS 26.5, deleted after the run: `header-a`
(10040852) as `hdr_alex` / Alex and `header-b` (5E55BF20) as `akuz` / Akuz. Own
`wrangler dev` on :8843 with `--persist-to` outside the repository; both apps
launched with `MSNGR_SERVER=http://localhost:8843`. Build from the working tree.

Display names and message text are Latin typed through a Russian keyboard, so
the messages read as nonsense («Зштп1» is `ping1`). The four subtitle strings
and the declension are the parts under test and they are Russian in the code.

Taps were aimed with `scripts/grid.py`, which draws the grid in points.

## The back button

Reported as dead and missing from the accessibility tree, and blocking the gate.
It is neither. A tap on the drawn chevron at 42,82 leaves the chat, three times
out of three by hand, and `chat.back` is in the tree, hittable, and closes the
screen from XCUITest. Two tests now hold that: `testF_BackButtonLeavesTheChat`
and `testG_HeaderTitleIsInTheTree`.

What the report saw is an `idb` artifact. `idb ui describe-all` returns the
navigation bar as one `NavigationStackHosting` node with no children whenever the
feed is on screen; over the same chat as a pending request, with the request card
instead of the feed, the same call lists `chat.back` and `chat.header`. XCUITest
sees all of them either way, and so does the tap.

## Subtitle

| Step | Expectation | Fact |
|------|-------------|------|
| chat opened while the peer is in the app | «в сети» | «был(а) 1 мин. назад» before the fix, «в сети» after (`01`) |
| the peer types | «печатает…» in the accent colour | `02`; held through 11 s of typing without falling back once |
| the peer stops | back to «в сети» after the ttl | 6 samples 1.4 s apart, all «в сети» |
| the stand is killed | «подключение…» | `03`, and the green dot is gone with it |
| the stand comes back | «в сети» again, by itself | `04`, within 40 s of the port answering |
| the peer's app is killed | «был(а) только что» | `05` |
| a group | «2 участника» | `06` |
| someone types in a group | «Akuz печатает…» | seen on the group with the long name |

The first row is the defect this run was for. Presence reaches a device only as
a transition: a device that was not connected when the peer came online never
hears about it and keeps the row it had. Opening a chat now asks the server where
the peer is, and asks again when the app comes back on screen.

Two more the header was lying about: the green dot stayed lit while the socket
was down, next to a subtitle that said «подключение…», and a group carried the
dot of whichever member is not you.

## The header itself

The back chevron was 34pt bold beside a 17pt magnifier in the same bar. It is
17 medium now, ceiling 19, in a 44x44 frame — the size of its neighbour.

`fitted()` measured the title against a 208pt reserve left from the wide button.
Counting what is actually in the bar (a 44pt button with its 16pt inset on each
side, the avatar and its gap, 20pt clear of the glass), a 36-character group name
ends at 328pt with the button starting at 342 (`06`). Before that it ran under the
magnifier.

Checked on both appearances and at `accessibility-extra-extra-large`: the title
truncates further, the subtitle grows, the row still holds.

## The strip above the input

One strip, two modes, and it says which one it is: a reply carries the reply
arrow and the sender's name (`07`), an edit carries a pencil and «Редактирование»
(`08`).

| Step | Expectation | Fact |
|------|-------------|------|
| reply, type a draft, cancel | the field keeps the draft | kept |
| edit | the field takes the message text | took it, the draft waits |
| cancel the edit | the draft comes back | came back |
| edit on top of a reply, cancel | the reply comes back, and the draft with it | both came back |
| send the edit | the message changes, the strip clears, the draft returns | «изм.» on both devices, draft back |

## The pinned message

The bar draws with the accent stripe, «Закреплённое сообщение» and the preview,
and a tap on it flashes the message in the feed. The context menu offered
«Закрепить» over the message already in the bar; it offers «Открепить» now.

A pinned message older than the feed window is still not verified: the bar is
drawn from the window, so such a message does not exist for the screen, and the
tap calls `scrollTo` with no `ensureLoaded`. That waits for `run-feedwindow`,
which teaches the window to shrink and has not reached main.

## Not covered

- Pasting an image from the clipboard into the strip.
- The pinned message deeper than the window, as above.
