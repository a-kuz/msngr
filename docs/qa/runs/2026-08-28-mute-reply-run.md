# A muted chat still notifies about a reply to you

Date: 2026-08-28. Simulator: solo-live (165449DB-8D23-4128-B3B0-63D26B8B00C2),
shared stand :8787, fixture alfa3; sender bravo3 via `msngrfixture send --reply`
(the new flag quotes the peer's latest message).

## What was delivered

- `NotificationDecision` takes `repliesToMe`: a muted chat's message that
  quotes one of yours notifies anyway, on both paths — the WS banner and the
  system push (willPresent). The exception lifts the mute alone: an open chat,
  an own echo, a shown key still silence it.
- The coordinator reads the quote's author from the message row (WS path) and
  from the stored row at willPresent time.

## Verified

- `MsngrTests/NotificationDecisionTests` — 18/18, including the new matrix:
  reply-to-me through mute on both paths, and the exception not overriding the
  other silence reasons.
- Live, with the Bravo chat muted through the row swipe and the app in the
  background: a plain message from bravo raised nothing; a reply to alfa's
  message raised the banner «Bravo Service — А это ответ тебе».

## Notes

- The mention half of the ROADMAP line stays open: mentions are not in the
  product yet, the exception hook is the same `repliesToMe`-style input.
