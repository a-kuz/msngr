# Messages arrived only after a relaunch — one sighting, cause unknown

Reported 2026-08-16 by the agent doing the Dynamic Type work, as an aside to its
own task. Recording it so it is not lost; it is not confirmed and not reproduced.

## What was seen

On the agent's own two simulators and its own stand, messages sent by one user
reached the other only after the receiving app was relaunched. Once. The
simulator in question had been through a language change and several
terminate/launch cycles before this happened.

When the messages did arrive, they came over the socket — so the socket was
alive by then.

## Why it is worth keeping

Nothing in the Dynamic Type change touches sync, the socket or the engine, so
the sighting is unexplained rather than explained-away. A message that needs a
relaunch to appear is, by the product's own rules, a defect and not a state.

## What would confirm or kill it

- Whether the socket was connected but not delivering, or disconnected without
  the client noticing. `SyncEngine.connectionStream` and the fanout state
  endpoint (`/api/chats/:id/fanout`, which now reports `oldestMs`) answer this.
- Whether the fanout queue on the server had the job and did not drain it —
  the alarm-arming defect fixed earlier today had exactly this shape, and the
  fix is in, so a recurrence would mean a second path to the same symptom.
- Whether a language change plus repeated terminate/launch is load-bearing, or
  incidental to how that simulator happened to be used.

Until one of those is answered this stays open with no owner and no priority.
