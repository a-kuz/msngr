# A banner when someone reacts to your message

Date: 2026-08-28. Simulator: solo-live (165449DB-8D23-4128-B3B0-63D26B8B00C2),
shared stand :8787, fixture alfa3; the reacting peer is bravo3 via the new
`msngrfixture react` command.

## What was delivered

- `SyncEngine.reactionStream`: the live batch announces a peer's reaction once
  its target is written and confirmed to be an own message. A cleared reaction,
  a reaction to somebody else's message and one still waiting in `pendingApply`
  raise nothing.
- `NotificationContentBuilder.reactionContent`: sender name in the title, the
  emoji and a quoted preview of the target in the body; the privacy setting
  swaps the quote for «Реакция … на ваше сообщение». The media placeholder
  comes from the regular preview («🖼 Альбом» and the rest).
- `NotificationCoordinator` subscribes and runs the same decision, claim and
  show path as a message banner: in-app banner in the foreground, a local
  notification in the background, muted and open chats stay silent, the claim
  dedups by the reaction frame's own seq.
- `msngrfixture react --as bravo --to alfa --emoji ❤️` reacts to the peer's
  latest message end-to-end through the real core.

## Verified

- `swift test --filter NotificationContentTests` — 23/23 (three new reaction
  cases: text quote, media placeholder, hidden text).
- Live: with alfa's app in the background, bravo's 👍 raised the banner
  «Bravo Service — Реакция 👍 на «🖼 Альбом»» on the simulator.

## Left out, and why

- With the app killed there is no banner: the reaction travels as a service
  frame and the server raises no push for it. That half needs a targeted push
  for the message author and NSE rendering — the NSE does not run on the
  simulator, so it belongs to the device pass blocked on the K2 development
  certificate.
