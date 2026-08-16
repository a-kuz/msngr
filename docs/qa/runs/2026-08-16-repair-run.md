# An unreadable message repairs itself

A message that cannot be decrypted is a defect, so the device works on it alone:
it keeps the envelope, replays it, and when no replay can help it asks the
sender for a fresh copy. This run breaks a session for real and watches the
message come back.

## Stand

Own simulators `msngr-repair-a` (EA5BEB89) and `msngr-repair-b` (181F8DBF),
iPhone 17, iOS 26.5, deleted after the run. Own `wrangler dev` on :8814 with a
separate `--persist-to` (`server/.wrangler-repair`, D1 schema applied with
`wrangler d1 execute msngr --local --persist-to … --file schema.sql`). Both apps
launched with `SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8814`, build from the
working tree. Users `repalice` (A, sender) and `repbob` (B, receiver). The
`repair` log channel was read with `log stream --predicate 'subsystem ==
"ai.enface.msngr"'` on B.

## Run

| Step | Expectation | Fact |
|------|-------------|------|
| B's app is closed and its ratchet session state is overwritten with random bytes | nothing decrypts from A any more | `ratchetSession.state` replaced, archive cleared |
| A sends «Broken session message» | B records the failure and keeps the envelope | `unreadable … seq=2 reason=exception attempts=1` at 12:26:18, `pendingDecrypt` holds the envelope |
| background sweep after the grace period | copy asked from the sender, once | `repair asked … seq=2 reason=exception attempt=1` at 12:27:32 |
| sender answers | copy applied under the original msgId | `repaired … seq=2` at 12:27:32, 64 ms after the request |

Nothing was tapped between the break and the repair: the request, the answer and
the replacement all ran in the background.

## Databases after the run

B: messages at seq 1, 2, 5 (seq 3 and 4 are the repair request and its answer —
service frames without a row of their own), `syncedSeq` 5, `pendingDecrypt` and
`historyGap` empty. A: the same three messages, all read, empty outbox, no
records of anything unreadable — the request it received and the answer it sent
left no trace in its feed.

## Why the session came back

The repair request is a pairwise message from B to A. B's session could not open
anything, so it is marked for a rebuild before the request goes out: the request
travels as a fresh X3DH prekey message, A installs the responder session from
it, and the answer already rides the new session. That is why the third message
needed no repair at all.

## What the run did not cover

A group chat. The sender key path — confirmation of a distribution and
redistribution to a member who complains — is covered by unit tests and by
`testGroupChatSenderKeys` against a live server, not by a simulator run.
