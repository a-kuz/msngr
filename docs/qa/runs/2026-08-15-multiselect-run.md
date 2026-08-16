# Multiselect, deletion and text selection

Task #44.

## Stand

Two own simulators, `msngr-ms-agent` (Alpha) and `msngr-ms-agent-b` (Beta), with
own `wrangler dev` on :8802 and its own `--persist-to`; both apps launched with
`SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8802`. The chat held three outgoing
messages from Alpha and two incoming from Beta.

## Run

1. `01-context-menu.png` — the context menu of your own message: «Выделить
   текст», «Выбрать», and «Удалить» as a single item.
2. `02-selection-mode.png` — selection mode: a checkbox on every row, incoming
   bubbles pushed right, a cross at the left of the header, the counter
   «2 сообщения», and a «Удалить / Переслать / Копировать» bar in place of the
   input field.
3. `03-delete-confirm-own.png` — the confirmation for two of your own messages
   offers «Удалить у всех» and «Удалить у меня».
4. `04-delete-confirm-foreign.png` — the same with one of Beta's messages
   selected offers only «Удалить у меня»; there is no delete-for-everyone.
5. `05-deleted-result-sender.png` — after «Удалить у всех» both bubbles read
   «Сообщение удалено» and selection mode closed.
6. `06-deleted-result-peer.png` — the same two messages read «Сообщение
   удалено» on Beta.
7. `07-text-selection.png` — «Выделить текст» opens a separate screen with the
   message text selected whole, with the system handles.
8. `08-text-selection-copy.png` — tapping the selection brings up the system
   menu with Copy.
9. `09-forward-picker.png`, `10-forward-result.png` — «Переслать» from the
   selection bar: the chat picker, and the result on Beta reading «Переслано от
   Alpha».

## The server-side access check

`ConversationDO /delete` tombstones only the messages the requester wrote, plus
anything at all for a group admin. It used to fan the `deleted` frame out over
the whole requested list, so someone else's message vanished on the clients
while surviving on the server; the frame now carries only what was really
removed. `server/test/smoke.mjs` covers this with `no fanout deleting someone
else's message` and `someone else's message survives delete for all`; the first
of those fails against the old code.

## Units

`ios/MsngrTests/MessageSelectionTests.swift` — toggling selection, the order of
the selected by feed position, when delete-for-everyone is available (only when
every selected message is your own), and the plural form of the counter.
