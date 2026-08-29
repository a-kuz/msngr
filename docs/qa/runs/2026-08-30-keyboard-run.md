# The hardware keyboard drives the app — live run

2026-08-30, simulator `fable-ipad` (iPad Pro 11", 27D0AF17), host keystrokes
through Simulator's connected hardware keyboard, plus real HID events from
the XCUITest daemon.

## What the keys do now

- Chat list: ↓/↑ walk the visible rows of the current tab (the walked row is
  tinted), Enter opens the selection, Cmd+N opens a new chat, Cmd+F moves
  focus into search (iOS 18+), Cmd+1..9 switch folder tabs. The bare keys act
  only while the list itself is what the keyboard addresses — no chat pushed,
  no sheet up, no search in progress.
- Chat: with a hardware keyboard attached the composer takes focus as the
  chat opens (`GCKeyboard`), so the keys work with no tap. Enter sends,
  Shift+Enter breaks the line, Esc walks back out — first the edit, then the
  reply, then the chat.

## What was seen

Down-arrow → Enter opened «Избранное» with the composer focused; Enter on a
filled composer sent the message and cleared the field
(`2026-08-30-keyboard/enter-sends.png` — the bubble delivered at 01:29); Esc
returned to the list with the walked row still tinted
(`esc-back-list-highlight.png`).

## What holds the behaviour

- `KeyboardNavigationTests` (UI, real HID through the test daemon): the
  arrows+Enter open path and Cmd+N — green over clean and relaunched state.
- `KeyboardComposerTests` (units): Enter consumed by a send inserts nothing,
  a declined Enter falls back to a newline, Shift+Enter always breaks the
  line, Esc forwards to the chat screen, and every command claims priority
  over the text view's own handling. The composer keys live at the unit
  level because the simulator's hardware-keyboard pipe drifts between
  XCUITest runs — the StatusBarTapTests situation over again; the full path
  above was watched by hand.
