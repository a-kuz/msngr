# Reactions and forwarding, the rest of the block — run

Two fresh simulators (`runreactions-a`, `runreactions-b`, iPhone 17 / iOS 26.5)
as the fixture accounts `alfa` and `bravo` on the shared stand at :8787. Every
message, reaction, edit and forward travelled the whole E2EE path between the
two devices. Screenshots are in `2026-08-21-reactions-forward/`.

The run covered the three behaviours built on this branch (who reacted, a
forward that keeps the quote, edit history) and the five claims of the block
nobody had watched live. Two defects were found and fixed in the same run.

## Reactions

- `01-reaction-set-alfa.png` … `03-reaction-replaced-bravo.png` — alfa put 👍
  on their own message from the context-menu emoji row, tapped the capsule to
  remove it (both sides went clean), set 👍 again and tapped ❤️ in the menu:
  the capsule replaced in place, and bravo saw a single ❤️, not two capsules.
- `04–05-doubletap-heart-*.png` — a double tap on bravo's bubble put ❤️;
  bravo's device shows it on the same message.
- `13-who-reacted-sheet-alfa.png` — the new sheet: in «Design» a message held
  bravo's ❤️ and alfa's 👍; tapping the ❤️ capsule opened the list grouped by
  emoji — «❤️ 1 · Bravo Service», «👍 1 · Alfa Service» — with the tapped
  emoji's section first. In the direct chat the same tap kept its old meaning
  and toggled the reaction (that is what the removal above rode on). Who is
  listed and in what order is unit-covered in `ReactionRosterTests`.

## Forwarding

- `06-forward-text-mark-bravo.png` — alfa forwarded bravo's message from the
  direct chat into «Design»; bravo's device shows the sender «Alfa Service»
  and «Переслано от Bravo Service» over the original text.
- `07-forward-photo-album-marks-bravo.png` — a photo and a three-photo album
  sent and then forwarded the same way; both arrived with the mark. The first
  take caught a defect: the album reached the group with no mark at all — the
  layout pinned full-bleed media to the bubble top and drew the forward line
  underneath it, and a photo had the same hole once nothing else pushed it
  down. Fixed (any header row now pushes the media down; `BubbleLayoutTests`
  forward cases) and re-shot.
- `12-forward-with-quote-bravo.png` — the new payload decision: alfa replied
  to bravo, forwarded the reply into «Design», and the quote preview travelled
  with it — bravo reads «Вы — Say the word when you need a s…» over the
  forwarded text even though the original lives in another chat. Tapping the
  quote there does nothing, by design. Reactions do not travel with a forward
  (Telegram's choice, kept); the decision and the payload shape are in
  docs/protocol.md, the builder in `ForwardPayloadTests`.
- On alfa's own outgoing bubble the forward line was drawn in the incoming
  bubble's gray and could not be read on the dark fill — the second defect of
  the run, fixed by giving the line the outgoing meta color.

## Editing

- `08–09-edited-mark-*.png` — alfa edited their own message twice; both
  devices show the final text with «изм.», and the edit raised no banner and
  no unread on bravo.
- `10-edit-history-sheet-alfa.png`, `11-edit-history-sheet-bravo.png` — the
  new history: the context menu of an edited message grew «История изменений»,
  and the sheet lists every version newest first with the time each text was
  authored — the original keeps its own send time. The peer sees the same
  three versions: the history is built on apply, from the full payloads the
  edit frames already carry. What is kept and how replays and the
  edit-before-original path behave is unit-covered in `EditHistoryTests`.

## Found in passing, out of scope

- A forwarded message deleted for everyone keeps its «Переслано от …» line
  above «Сообщение удалено» — logged in docs/qa/defects.md.

Unit checks around the run: `swift test` (MsngrKit, EditHistoryTests among
them) and MsngrTests (199 green, ForwardPayloadTests, ReactionRosterTests and
the BubbleLayoutTests forward cases included). `make check` runs in the
background after the merge, log in `.claude/gates/run-reactions.log`.
