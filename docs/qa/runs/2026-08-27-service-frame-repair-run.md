# A repair delivers a service frame the peer could not decrypt

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803, with bravo as a headless engine
(`msngrfixture typing`, 200 s) over the `solo-fixtures` homes.

## The change under test

An edit takes a seq but no message row of its own, so a repair request for it
used to be answered with "we do not hold": the requester burned its five
attempts and the seq never settled (`docs/qa/defects.md`, the no_session
entry). Now the ack of a service frame records its payload under the assigned
seq (`sentServiceFrame`, target resolved to its seq), and the repair answer
falls back to that record when the seq has no message row.

## How

- Alfa sent «Repair probe» into the direct chat with bravo (seq 18), then
  drove two edits of it from the UI (seq 19 and 20). Alfa's store showed
  `sentServiceFrame` rows for 19 and 20 with `{"kind":"edit","targetSeq":18}`.
- Bravo's pairwise session with alfa was deleted from his home
  (`DELETE FROM ratchetSession WHERE peerUserId = <alfa>`), so every dr frame
  from alfa is `no_session` for him.
- Bravo's engine ran for 200 s against the stand while alfa's app stayed
  foregrounded.

## Seen

- 30 s in: seqs 18–20 sat in bravo's `pendingDecrypt` as `no_session`, replay
  attempts counting, no repair yet (the 60 s grace).
- 90 s in: all three were gone from `pendingDecrypt`. Seq 18 stood as a
  message row with its text; 19 and 20 were settled in `historyGap` as
  `service`. Alfa's outbox was drained — both kinds of answer went out: the
  message from its row, the edits from `sentServiceFrame`.
- The two seqs stuck from the 08-27 reproduction (9 and 11, edits acked by
  the pre-fix build) stayed in `pendingDecrypt` with the attempt counter
  moving 3 → 4: nothing recorded their payloads at ack time, so no copy
  exists to answer with. Frames sent by the fixed build do not join them.

`MessageRepairTests` holds both sides as units: the sender answers a repair
request for an edit from the sent-frame record with the target resolved to a
seq, and the repaired edit applies to its target, clears `pendingDecrypt` and
settles the seq as a `service` gap.
