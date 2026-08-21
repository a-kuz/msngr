# The header presence and group author names, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`; `charlie` is put online by running his engine headlessly
(`msngrfixture answer`, which holds a live socket while it waits).

- `01-header-online.png` — with charlie's engine up, the direct chat's header
  reads «в сети» and the avatar carries the online dot.
- `02-header-last-seen.png` — the engine gone (a 25 s run, shot ~55 s after it
  started): «был(а) только что», the dot gone. The flip needed no reopening of
  the chat.
- `03-group-author-names.png` — the «Standup» feed: «Bravo Service» and
  «Charlie Service» stand over their runs in per-name colours with sender
  avatars on the run's last bubble; own messages carry no name. The
  «Сообщение удалено» tombstone in the same shot is the forward deleted for
  everyone earlier this session.

Typing, driven by `msngrfixture typing` (added in this change: the engine
holds the indicator up for a given number of seconds):

- `04-list-typing.png` — the chat list row shows «печатает…» in the accent
  italic in place of the preview.
- `05-header-typing.png` — the chat header's subtitle shows «печатает…» in
  place of the presence line.
