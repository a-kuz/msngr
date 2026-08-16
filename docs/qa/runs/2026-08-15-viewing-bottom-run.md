# Feed at the bottom: the down button and marking read (#65)

## Stand

A pair of temporary iPhone 17 simulators, created and deleted within the run.
Users `vbsender` (Sender A, the sender) and `vbrecv` (Recv B, the receiver). Own
`wrangler dev` on :8808 with `--persist-to server/.wrangler-vb`, both apps
launched with `SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8808`, the chat created
through `POST /api/chats` with the tokens from session.json. Message texts are
digits: the simulator has the Russian keyboard layout on, so latin characters
typed over HID come out Cyrillic.

## What was fixed

The "feed is at the bottom" flag was computed as `contentOffset.y > 300`.
Entering a chat with unread messages parks the feed on the marker, the offset is
then past the threshold, so the down button with its badge was drawn on top of
messages that were already on screen and `markVisibleRead()` never fired. The
flag is now whether item 0, the newest message of the inverted feed, is among the
visible cells.

## Run

| Case | Action | Result |
|---|---|---|
| 1. Opening with 4 unread | receiver's app killed, 4 incoming, launch and open the chat | badge 4 in the chat list; in the chat the marker «4 непрочитанных сообщения», all four messages on screen, no down button |
| 1. Read is marked | the same opening | the sender shows double ticks on all eight messages |
| 2. Scrolled up | swipe until the bottom of the feed leaves the screen | the down button appeared, with no badge, unread being 0 |
| 2. Incoming while scrolled up | +1 message | badge «1» on the button, the feed did not jump; on the sender the double ticks stayed grey, read was not marked |
| 3. Back to the bottom | tap on the down button | button and badge gone; the sender's ticks turned orange |
| 4. Long history | 35 messages (several screens), app killed, 4 incoming, chat opened | the marker «4 непрочитанных сообщения», the unread messages on screen, no button; the badge in the chat list cleared |
| Regression: own send | from deep in the history (scrolled up) send a message of your own | the feed went to the bottom at once, the own message visible, the button gone |

## Tests

MsngrTests: 100 checks green, including ViewingBottomTests, which decides "is the
feed at the bottom" from the set of visible indexes and the item count (opening
on the marker, marker above the screen, empty feed, feed with no materialised
cells). `swift test` in MsngrKit: 128 green. The build on the run's simulator
succeeded.

## What the run did not cover

The server smoke test: the stand for this run was raised separately, and the
owner's :8787 and apns-mock on :9871 were left alone. The appearance and
disappearance animation of the button was not examined frame by frame.
