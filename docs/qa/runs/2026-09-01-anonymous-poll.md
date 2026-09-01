# Anonymous poll: the vote carries a pseudonym, not the voter

2026-09-01, two simulators on the shared stand. `charlie` (fixture) on
fable-a, a throwaway account registered with `msngrfixture` on fable-b, in
their direct chat.

## What was checked

1. On charlie: «+» → «Опрос», a question and two options, «Анонимное
   голосование» on. The footer under the switch reads «Голоса идут со
   сквозным шифрованием и несут псевдоним вместо имени, так что ничьё
   приложение не узнает, кто что выбрал» (`2026-09-01-anonymous-poll-compose.png`).
   «Создать» puts the poll in the feed as «Анонимный опрос».
2. On the throwaway: the poll arrives; a tap on the first option votes. The
   pick mark and 100% appear on the voter's copy, «Проголосовало — 1» and
   the shares on the author's (`…-voter.png`, `…-author.png`).
3. The poll row in both databases after the vote:

   ```
   charlie:   {"anon:5003328ddcd5ba065a5a169d060fec36":[0]}
   throwaway: {"anon:5003328ddcd5ba065a5a169d060fec36":[0]}
   ```

   The key is the voter's per-poll pseudonym; neither copy holds the voter's
   user id anywhere in `pollVotes`.
4. A second tap on the same option retracts: the author's row goes to `{}`.
   A tap on the other option lands as `{"anon:5003…":[1]}` — the same
   pseudonym, replaced whole, so one person stays one vote.

## Units

`PollTests` in MsngrKit: an anonymous poll keys by the pseudonym and never by
the sender, a named poll ignores a pseudonym, a vote buffered ahead of its
poll keeps the pseudonym when it lands, and `PollPseudonym` is stable per
account and poll and differs across polls and accounts.

## Driving note

A SwiftUI `Toggle` on the simulator did not flip on an instantaneous
`idb ui tap`; the same tap with `--duration 0.15` flips it.
