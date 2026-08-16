# Chat header: items 1 and 2, and a re-check of the five closed ones

Run date: 2026-08-16. Screenshots — `2026-08-16-chat-header/`.

## Stand

Own simulators `chatui2-a` (D8416611) and `chatui2-b` (3C59B88B), both iPhone 17
on iOS 26.5, deleted after the run. Own `wrangler dev` on :8873 with
`--persist-to` in the session scratchpad and D1 migrations applied into it; both
apps launched with `MSNGR_SERVER=http://localhost:8873`. Users `kira_v` («Kira»)
and `denis_m` («Denis»); the direct chat holds about 300 messages from the DEBUG
seeding button, 100 incoming and 200 outgoing, plus the handful sent by hand
during the run. Build from this working tree, reinstalled on the simulator after
every change.

## Item 1, the feed under the header

What stood before was a 150 pt linear gradient of the background colour and
nothing else: no blur, and the feed itself still ended at the bottom of the
navigation bar, so a bubble scrolling up met a hard edge a few points below the
title.

The band is now `HeaderFade`: four `UIVisualEffectView`s stacked towards the top
edge, each masked by its own gradient, over the feed's background tone on the
same height. Every layer blurs what is behind it, previous layers included, so
the blur gathers instead of switching on. The band is the status bar plus 44 pt,
103 pt on this device, which is what the header occupies. The feed runs under it
(`.ignoresSafeArea(.container, edges: .top)`) while its insets keep counting from
the safe area, so at rest nothing hides under the header and only a message being
scrolled past it dissolves.

Checked at rest at the end of the chat (`01`), scrolled into incoming history
(`02`) and into outgoing history where the bubbles are dark and the contrast with
the band is largest (`03`), and in the dark appearance (`04`). One message
dissolves fully, the next one softens at its top edge, the third is clean.

**The system fought this.** Once the feed went under the header, iOS 26 put its
own scroll edge effect on the collection view, and because the feed is flipped
(`transform` with `scaleY: -1`) the effect landed mirrored: the strip it should
have softened stayed sharp and the entire rest of the feed was blurred down to
the input bar (`05`). It is switched off for this collection view; the band under
the header is ours.

## Item 2, the back button

The chevron is 34 pt bold in the accent colour in a 56×44 target, and the peer
avatar next to it drops from 40 to 34 pt, so nothing in the header outweighs it
(`02`). The system's own glass capsule on iOS 26 sits behind it and adds to the
weight rather than competing.

## The five items closed in code

| Item | Expectation | Fact |
|------|-------------|------|
| 3 | Delete enters selection, the confirmation sits at the bottom | selection with that message ticked, «Удалить 1 сообщение?» below the feed (`06`); on an own message both «Удалить у всех» and «Удалить у меня» (`07`), on someone else's or a mixed selection only «Удалить у меня» |
| 5 | The status bar tap goes to the beginning of the chat | not driven by hand, see the gaps; `testF_StatusBarTapGoesToChatStart` passes in the gate |
| 6 | Sending from deep history lands the feed on the new message and animates it | sent from around «Test message 45 of 100», the feed came to the end and the message was in place (`10`); the appearance itself is three recorded frames of a spring settling, about 0.1 s at the recorder's ~30 fps (`11`) |
| 7 | A reaction leaves the time and ticks where a plain bubble keeps them | the reaction chip sits before the time and the right inset matches the plain bubbles above (`09`) |
| 8 | Dragging over the lifted text selects it | the drag selects, handles and «Скопировать» appear, no «Выделить текст» row in the menu (`08`) |

## Gaps

Item 5 was not driven by hand: a synthetic touch does not reach the status bar,
so the only evidence is the UI test.

Scrolling with the four stacked blur layers was not measured. It looks smooth by
eye on the simulator, and the simulator is not where a frame rate means anything.

Only the graphite palette was checked, in both appearances. The band takes its
tone from `Theme.chatBackground` and resolves it against the view's traits, so
the other two palettes should follow, but nobody looked at them.

The peer device was used only to seed the incoming half of the chat; nothing in
this run says anything about the receiving side.

The width the header title fits itself into moved with the button by arithmetic,
not by measurement: the peer here is called «Denis» and no long name was tried.
The new number is the more conservative one, so a name can now truncate a little
earlier than it has to, but it cannot reach the bar and be clipped.

## Checked with

`make gen build unit layout crashes DEV_UDID=8FDCB62D` (own throwaway simulator
`chatui2-gate`), `make uitest DEV_UDID=8FDCB62D` against the shared stand on
:8787, which is the one holding the `akuz` user the UI tests look for, and
`make server-smoke MSNGR_SERVER=http://localhost:8873 PUSH_PORT=9877` against the
own stand so the shared APNs mock port stays free.
