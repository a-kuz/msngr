# Chat screen: the owner's review, items 3, 5, 6, 7, 8

Everything below was inherited unverified from a previous agent and re-checked
live, on a build from this working tree. Two of the five items did not work at
all and are fixed here. Screenshots — `2026-08-16-chat-ui/`. Run date: 2026-08-16.

## Stand

Own simulator `chat-ui-agent` (90A36247), iPhone 17, deleted after the run, and
a peer `chat-ui-peer` (B222951F) for the other side of the chat. Own `wrangler
dev` on :8804 with `--persist-to` in the session scratchpad and D1 migrations
applied into it; both apps launched with `MSNGR_SERVER=http://localhost:8804`.
Users `vera_c` and `oleg_p`; the chat holds 104 messages, four written by hand
and 100 from the DEBUG seeding button.

## Run

| Item | Expectation | Fact |
|------|-------------|------|
| 3 | Delete opens selection with that message already ticked, the confirmation at the bottom | selection mode, «1 сообщение», two actions «Удалить у всех» / «Удалить у меня»; the message stays visible (`01`), a second tap makes it «2 сообщения» (`02`) |
| 5 | The status bar tap goes to the beginning of the chat | broken as inherited, see below; fixed and covered by `testF_StatusBarTapGoesToChatStart` |
| 6 | Sending from deep history lands the feed on the new message | sent from «Test message 1 of 100», the feed came to the end with the message in place (`05`, `06`) |
| 7 | A reaction leaves the time and ticks where a plain bubble keeps them | same right and bottom inset as the neighbours (`03`), and `testReactionKeepsStatusInsetsOfPlainBubble` passes on the reworked geometry |
| 8 | Dragging over the lifted text selects it, with no step in between | drag selects, handles and «Скопировать» appear, and the «Выделить текст» row is gone from the menu (`04`) |
| — | Swipe back from the left edge | returns to the chat list (`07`, `08`) |

## What was actually broken

**Item 5 never fired.** The feed answers `scrollViewShouldScrollToTop`, but the
input field is a `UITextView`, that is, a second scroll view with `scrollsToTop`
still on — and while two of them are on screen the system hands the tap to
neither. The field now declines it (`InputBar`), leaving the feed the only
candidate. A synthetic touch never reaches the status bar, so the check lives in
`MsngrUITests` where XCUITest taps the real one.

Its window walk also went page by page over the whole local history. The search
work landed `anchor(floor:capacity:)` in the meantime, so the beginning of the
chat is now one move of the window floor onto the oldest message the device
holds.

**Item 8 was a sketch that could not work.** The lifted bubble is a rendered
`UIImageView`, and images take no touches, so the live text laid over it got
none either. Two more things stood in the way: a non-editable, non-scrolling
`UITextView` returns nil from `hitTest`, so the gesture cannot live on the text;
and the text view's own recognizers swallow the touch if it does receive one.
The drag now lives on the overlay, the snapshot accepts touches, and the text
view is left non-interactive — it only draws the selection it is given.

## Swipe back

The system's interactive pop does not run on this screen. With the header
drawing its own back button and `.navigationBarBackButtonHidden(true)`, clearing
the recognizer's delegate in `viewDidAppear` changes nothing: the probe showed
the navigation controller found, the recognizer enabled and its delegate
cleared, and two edge swipes — quick and slow — still did not pop. The screen
therefore keeps its own edge gesture, which returns to the list with the usual
pop animation but does not follow the finger.

## Not covered

The landing animation of item 6 was not recorded. `simctl` refused every attempt
with «Host recording is already in progress» — another agent held the host
recorder for the length of this run — and a screenshot burst is slower than the
animation, so the stills show only its ends. The landing itself is verified;
its animation is not.
