# The unread banner counts what the database counts

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803. The bursts are
`msngrfixture send --repeat`, which enqueues N real E2E messages over one
connection.

## The defect, reproduced first

With 700 unread planted (the chat opened offline, the banner read «700
непрочитанных сообщений», the feed pinned to the banner mid-history), the
stand returned and 300 more caught up while the chat stayed open. The banner
still read 700; the scroll-down badge said 300; the database held 1000
incoming messages at or after the anchor — the owner's 56-vs-1004 from
2026-08-21, staged on demand.

## The fix, verified the same way

Same staging on the fixed build: the banner planted 600 offline, the stand
returned with 300 more, and within the catch-up's five seconds the banner
read «900 непрочитанных сообщений» — the exact count of incoming rows at or
after the anchor. The scroll-down badge read 300 (what stands below the
viewport), which is its own number and correct.

The count is now derived: whenever the chat row's `lastSeq` moves past what
was last derived, the database is asked how many incoming messages stand at
or after the anchor (`ChatViewModel.reconcileUnreadMarker`); the return from
the background plants the banner from the same kind of query, so arrivals
that never enter a feed window snapshot count too. The rule matrix and the
derivation queries are covered in `UnreadMarkerStateTests` (19 tests).
