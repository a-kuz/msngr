# Tab, the feed walk and Cmd+B/I/K — the owner's keyboard defects

2026-08-30, simulator `fable-ipad` (iPad Pro 11", 27D0AF17). The owner drove
the app from a real keyboard and reported: Tab prints a tab character, ↑/↓ do
not move over the messages, Cmd+B/I/K do nothing.

## What the keys do now

- Tab is consumed whole: the composer holds focus for the chat and the key
  has nowhere to move it, so it must not fill the field with tab characters.
- ↑ over an empty composer starts a walk over the feed: each step scrolls to
  the message and flashes it, ↑ goes toward history, ↓ back toward the
  newest, ↓ past the newest ends the walk. Enter on the walked message starts
  a reply to it; Esc ends the walk first, then walks out of the edit, the
  reply and the chat as before. With text in the field the arrows move the
  caret as in any text view.
- Cmd+B wraps the selection in `**`, Cmd+I in `*`; the same key on a wrapped
  selection takes the marker off, and with no selection the pair is inserted
  around the caret. Cmd+K turns the selection into `[text](url)`, taking the
  URL off the clipboard when one is there, otherwise leaving the caret
  between the parentheses. `[text](url)` is new markup: the parser draws the
  text and sends a tap to the URL, same as an autolink (MarkdownTests).

## What holds the behaviour

- `KeyboardComposerTests` (units, 11): Tab inserts nothing, the arrow
  commands exist only over an empty field, bold wraps and unwraps, italic
  inserts the pair at the caret, Cmd+K with and without a clipboard URL,
  plus the Enter/Shift+Enter/Esc set from the first delivery.
- `FeedKeyWalkTests` (units, 5): the walk enters at the newest message,
  steps toward history, stops at the oldest, ends walking off the bottom,
  and Esc clears it.
- `MarkdownTests` (units, 40 incl. 4 new): the explicit link, its http(s)
  requirement, the unclosed bracket staying plain, `links(in:)` listing it.
- `KeyboardNavigationTests` (UI, real HID): the list arrows+Enter and Cmd+N
  stay green — after their first red of the day turned out to be the
  simulator's ConnectHardwareKeyboard toggle having drifted off (flipped
  back per-device via DevicePreferences).

## What could not be watched live from here

A UI-test attempt at the walk failed honestly: on a drifted keyboard pipe a
typeKey Return into the focused composer lands as an inserted newline, so
even the send step cannot be asserted — the case was removed with the
rationale written next to the others in KeyboardNavigationTests. Host
keystrokes through System Events do not reach the simulator on this machine
either. The composer-level keys therefore stand on the units above; the
walk's first live run is the owner's own keyboard.
