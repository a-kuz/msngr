# Jumping to a quoted message, viewing files, copying and pasting media

Tasks #42 and #45.

## Stand

One throwaway iPhone 17 simulator, created and deleted within the run, as user
`agent_rf1`. The peer `bobby11` was registered through `POST /api/register` and
the chat created with `POST /api/chats` using the token from the container's
`session.json`. Own `wrangler dev` on :8796 with `--persist-to`; the shared
:8787 was left alone.

## Run

| Scenario | Action | Result |
|---|---|---|
| quote → original | 20 messages, a reply to «Сообщение 1», feed at the bottom so the original is off screen, tap the quote | the feed jumped to «Сообщение 1» |
| highlighting the original | the same tap | the original's bubble flashed the accent background for about 0.6 s |
| viewing a PDF | attach → file → dogovor.pdf, tap the file bubble | `QLPreviewController` with the page rendered, «1 of 1», a share button |
| viewing text | zametka.txt, tap the bubble | QuickLook showed the contents with the Cyrillic intact |
| copying a photo | long press a photo message | «Копировать» is in the menu, where it used to be text-only |
| the paste item | attachment menu after that copy | «Вставить» shown, with an image on the pasteboard and an empty field |
| attachment preview | tap «Вставить» | thumbnail with a cross above the input bar, send button enabled |
| sending what was pasted | tap send | went out as a photo message at 00:44 |
| the system paste gesture | long press the empty field → Paste | the image went to the attachment rather than into the text |

## Tests

MsngrTests: `ReplyJumpTests` covers finding the original by the server `msgId`
and by the local `clientMsgId`; `FilePreviewNameTests` covers the file name
handed to QuickLook. MsngrKit `swift test` green.

## Not covered

Loading more history when the original lies beyond the loaded page: the whole
chat fitted in the first page here, so the jump was never asked to page. The
share sheet for types QuickLook will not open was not exercised either.
