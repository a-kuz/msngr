# The offline queue: a send, a leave and a delete-for-all with the stand dead

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5)
against a stand of its own: `wrangler dev --port 8803` over a fresh
`--persist-to` directory, a trio seeded there with `msngrfixture seed`, the
`alfa` home installed from that directory and the app launched with
`MSNGR_SERVER=http://localhost:8803`. "Offline" is the stand's process killed
and started again over the same state.

## The send (ROADMAP: never gives up)

```
14:24:48  stand killed; header «подключение…»
14:24:57  «Offline one» sent: the bubble with the clock, one tick nowhere
14:25:33  stand started again
          the stand's log has GET /ws 101 right after «Ready»: the socket was
          back inside the first second, the message got seq 5, the bubble
          shows one tick (bravo has no live device, so no second one)
```

Forty-five seconds dark, nothing lost, nothing asked of the user.

## Leaving a group offline (ROADMAP: deleting offline)

With the stand dead, the `Design` row was swiped and «Покинуть» confirmed:
the row left the list at once. Fifteen seconds later the stand came back; its
log shows `POST /api/chats/…QSVAW5/delete 200` and `GET /api/chats` for alfa
lists Standup, Random, two direct chats and the saved messages — no Design.
The list did not bring the row back on the reconnect.

## Delete for everyone offline (ROADMAP: the service action queue)

With the stand dead again, «Offline one» was long-pressed → «Удалить» →
«Удалить у всех»: the feed showed the tombstone at once. After the restart the
journal read from the server has seq 5 with no body and `deleted: true`. The
request travelled over the socket, so the stand's HTTP log has no line for it;
the journal is the evidence.

## Also seen

`history?fromSeq=5` answered an empty list for a chat whose `lastSeq` was 5:
`fromSeq` is exclusive by contract (the scan starts at `fromSeq + 1`), which
`docs/protocol.md` states and the run's first poll forgot. Not a defect.

## Not covered

Accepting a request offline: the trio has no pending request to accept. The
30 s timer as the only wake-up: the reconnect fired first, as it should, so the
timer never had to.
