# The author learns what happened to his message

Sent, delivered, read: the mechanics were all in place and the ticks still lied.
The receipt left only from a live socket, and only as a frame nobody watched, so
a recipient who had the message could leave its author on one tick indefinitely.
This run drives the states on real simulators and breaks the delivery on purpose
to see the marks repair themselves.

## Stand

Own simulators `receipts-a` (21CC7719), `receipts-b` (38D2E907) and `receipts-c`
(13626FCE), iPhone 17, iOS 26.5, deleted after the run. Own `wrangler dev` on
:8803 with `--persist-to ~/ws/msngr-stands/run-receipts/state`, outside the
repository; the shared stand on :8787 was not touched. Apps launched with
`SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8803`, build from the working tree.
Users `ada_r1` (A, author), `bo_r1` (B), `cy_r1` (C), group «Trio» of all three.
Taps aimed with `scripts/grid.py` and with a helper that reads element frames out
of `idb ui describe-all` by accessibility identifier. Palette: graphite (the
default), so the read tick is amber and the unread one pale lavender.

## Direct chat

| Step | Expectation | Fact |
|------|-------------|------|
| A writes to B, B has not accepted the request | one tick: the recipient is invisible until he accepts | one tick |
| B accepts and lands in the chat | read | two amber ticks |
| B goes back to the chat list, A sends | delivered, not read | two pale ticks while the earlier two stay amber |
| B stands in the chat, app sent to the background, A sends | delivered only | two pale ticks |
| B's app comes back to the foreground | read | amber |
| B scrolls the chat to the start of history, A sends | delivered only | two pale ticks |
| B returns to the end of the feed | read | amber |
| B sits at the end, A sends | read with nothing touched on B | amber |

The chat list row shows the same pair, in the same colours.

## A send the server refuses

The server refuses a send from someone who blocked the addressee, so the block
was set through `POST /api/block` with B's own token while A's screen still had
its input bar.

| Step | Expectation | Fact |
|------|-------------|------|
| A sends into the refusal | «не отправлено» in place of the tick | the failed mark, same size as the ticks |
| long press on the failed message | send again, copy, delete, and no reactions | exactly those three |
| «Отправить заново» while the refusal stands | fails again, the message stays | failed again |
| the block is lifted, «Отправить заново» | the message A wrote goes out | delivered, then read |

The queue entry now survives the failure, which is what carries the original
text and its attachments into the repeat; a message deleted for yourself takes
its entry with it.

## Group of three

The tick speaks for the whole chat, so it waits for whoever is furthest behind.

| Step | Expectation | Fact |
|------|-------------|------|
| C's app killed, A sends into «Trio» | one tick: B has it, C does not | one tick |
| C's app launched and caught up | delivered | two pale ticks |
| B opens the group and reads | still delivered: C has not read | two pale ticks |
| C opens the group | read | amber |

## A receipt lost on the way out

`URLSessionWebSocketTask.send` into a connection that is already dying returns
without an error, and the queue entry is then dropped as sent. Reproduced by
hand: A sends, B is on the chat list, the stand is killed with `SIGKILL`, B opens
the chat. B's `myReadUpTo` moves to 23 and its `pendingAction` queue is empty:
the read was handed over, the entry was dropped as sent, and there was no server
to take it — nothing was left to send it again.

With the stand back up the chat state comes down with the catch-up, and it says
where the server thinks each member stands, including the reader itself. The mark
the server never heard is queued again from there: `readMarks` moved to 23 and
the tick on A turned amber, with nothing touched on either side.

## What the run did not cover

The receipt from the notification extension — two ticks on delivery to a device
whose app is not running. `simctl push` does not launch the extension on a
simulator in any state of the app (`docs/research/nse-simulator-experiment.md`),
and no device was available, so this path waits for the owner's `.p8` key. What
stands behind it meanwhile: `testDeliveredReceiptWithoutASocket` in
`CoreIntegrationTests`, which posts the receipt exactly as the extension does,
over HTTP with no socket at all, against a live server and moves the author's
message to delivered; and six checks in the server smoke test that the REST door
answers, reaches the author, repeats without harm, refuses an empty list and
marks nothing for a stranger. The extension's own reach into that door is covered
by code alone: the app group holds the address of the stand
(`server.baseURL = http://localhost:8803` in the container, written by the app
and read by the extension) and the queue it drains is the same table the app
drains.

macOS: the read mark there went out on every message-list update regardless of
the window's state, and now waits for the same three conditions as on iOS. The
target builds; the live check needs the host screen, which belonged to the owner
at the time of the run.
