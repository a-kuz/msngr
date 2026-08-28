# Accepting a message request offline

Date: 2026-08-28. Simulator solo-live (165449DB-8D23-4128-B3B0-63D26B8B00C2),
a private stand `wrangler dev --port 8807` with its own persist dir and a
fresh `msngrfixture seed` trio; the app launched with
`SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8807`.

## The scenario

1. A fresh account (`sofia`, via `msngrfixture knock`) sent alfa a message
   request; the row appeared under «Заявки на переписку».
2. The stand process was killed — the header honestly said «подключение…».
3. «Принять» tapped while offline: the request card left, the chat opened
   and the message «Привет! Можно к вам в бету?» became readable. The device
   database held the queue: `pendingAction` rows `accept` and `read`
   (attempts 0), the chat row already at `isRequest = 0, iAccepted = 1`.
4. The stand came back. With no touch on the app the queue drained on its
   own: `pendingAction` count 0.
5. `msngrfixture send --as sofia` after the accept: «Ура, приняли!» arrived
   as an ordinary message into the same chat (the row in the device database,
   the bubble in the open feed).

## Verdict

The action queue holds an accept across an outage and replays it on
reconnect with no human involved — the 🟡 «accepting offline through the
action queue» line is confirmed live.
