# An edit does not grow the peer's unread count

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5) with the
`alfa` home against a private stand on :8803. The peer is a headless engine:
`msngrfixture typing --as charlie --to alfa`, which syncs charlie's database
live and never marks anything read — so charlie's `unreadCount` is exactly what
the sync writes.

The direct chat alfa↔charlie was clean before the run: `lastSeq=4, unread=0`.

## Seen

```
15:09  alfa sends «dit unread probe»           charlie: lastSeq=5, unread=1
15:11  alfa edits it (text unchanged)          seq 6, service: true
15:13  alfa edits it to «dit unread probe plus» seq 7, service: true
15:14  charlie: lastSeq=7, syncedSeq=7, unread=1
```

Charlie's row for seq 5 reads «dit unread probe plus» with `edited=1`;
`historyGap` and `pendingDecrypt` are empty, so the contiguous prefix followed
the service frames to 7 without stalling. Alfa's bubble wears «изм.». The
server's journal (`/history?fromSeq=4`) shows seq 5 as content and 6–7 as
`service: true` with `contentAt: 5`.

Two edit frames arrived while charlie held one unread content message, and the
count stayed at 1 through both.

## In passing

The edit envelopes here are the same pairwise `dr` boxes that failed with
`no_session` in the alfa↔bravo chat (docs/qa/defects.md): on a clean session
they open and settle normally, which is consistent with that defect being a
chain-identity loss under session churn rather than anything about the service
path itself.
