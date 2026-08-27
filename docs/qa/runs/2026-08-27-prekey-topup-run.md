# One-time prekeys are topped up below 20

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803.

## How

Alfa's device held 29 one-time prekeys on the stand. Fifteen bundle handouts
(`GET /api/users/<alfa>/prekeys`, charlie's token) each consumed one, taking
the count to 14 — under the client's threshold of 20. The app was then
relaunched: `replenishPrekeysIfNeeded` runs once per session on start.

## Seen

```
after burn:  {"count":14}
t=3s         {"count":100}
```

Three seconds after launch the server held 100 again — the client asked for
the count, generated the missing 86 and uploaded them, exactly the once-per-
session path in `SyncEngine.replenishPrekeysIfNeeded` (threshold 20, target
100).
