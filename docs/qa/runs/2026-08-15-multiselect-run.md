# Multiselect, deletion and text selection

Task #44.

## Stand

Two own simulators, `msngr-ms-agent` (Alpha) and `msngr-ms-agent-b` (Beta), with
own `wrangler dev` on :8802 and its own `--persist-to`; both apps launched with
`SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8802`. The chat held three outgoing
messages from Alpha and two incoming from Beta.

## Run

1. The context menu of your own message offers «Выделить текст», «Выбрать», and
   «Удалить» as a single item.
2. Selection mode puts a checkbox on every row, pushes incoming bubbles right,
   places a cross at the left of the header, shows the counter «2 сообщения»,
   and replaces the input field with a «Удалить / Переслать / Копировать» bar.
3. The delete confirmation for two of your own messages offers «Удалить у всех»
   and «Удалить у меня».
4. With one of Beta's messages selected it offers only «Удалить у меня»; there
   is no delete-for-everyone.
5. After «Удалить у всех» both bubbles read «Сообщение удалено» and selection
   mode closed.
6. The same two messages read «Сообщение удалено» on Beta.
7. «Выделить текст» opens a separate screen with the message text selected
   whole, with the system handles.
8. Tapping that selection brings up the system menu with Copy.
9. «Переслать» from the selection bar opens the chat picker, and the forwarded
   message arrives on Beta reading «Переслано от Alpha».

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
