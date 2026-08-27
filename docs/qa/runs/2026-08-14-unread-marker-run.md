# The «N непрочитанных сообщений» marker (#36)

## Stand

A pair of temporary iPhone 17 simulators, created and deleted within the run.
Users ua_unread1 (sender) and ub_unread2 (receiver), the server the shared
`wrangler dev` on :8787, the chat created through `POST /api/chats` with the
tokens from the session.json of the two containers.

## Run

| Rule | Action | Result |
|---|---|---|
| 1. Opening with unread > 0 | 5 incoming while the app was killed, launch, open the chat | the marker «5 непрочитанных сообщений» above the first unread message, under «Сегодня» |
| 1. Feed not right at the bottom | 14 unread, more than fits below the screen | opened on the marker: the marker in the upper part, the whole run of unread messages below it, the end of the feed off screen |
| 2. Incoming with the chat open | +1 message from the peer | the counter went 5 to 6 in place, the anchor did not move |
| 3. Own send | sent «Privet» | the marker disappeared |
| 3. Reaction | ❤️ by long tap on a bubble | the marker «19 непрочитанных» disappeared |
| 4–5. Background and return | HOME (obscured), 2 incoming, return | the marker «2 непрочитанных сообщения» above the first message that arrived while away, with the right Russian plural form |
| Badge on the down button | scroll up, then an incoming message | the button carries the counter «1», the marker grew to 19 |

## Tests

MsngrTests green: UnreadMarkerStateTests covers the matrix of rules 1 to 5 plus
the plural forms, ChatFeedTests covers the position of the marker above the first
unread message and the stability of its id.

## Not checked live

The fade animation as the marker leaves was not examined frame by frame; in the
code the animated `performBatchUpdates` runs only for the "marker removed" diff.
The server smoke test fails on the push section because :9871 is taken by the
owner's apns-mock, a stand process, so only the sections before the pushes are
green. MsngrUITests is not part of the test scheme of the generated project
(project.yml, since commit 1375bfa), so the UI smoke test does not run from the
worktree.
