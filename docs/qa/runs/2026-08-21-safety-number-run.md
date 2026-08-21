# The 60-digit safety number, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa`; the independent side is `msngrfixture safety` (added in this change),
which computes the number from charlie's own identity store and alfa's keys
as his database holds them.

- `01-chat-info-code.png` — the chat info of the direct chat shows the code
  under «Код безопасности»: twelve groups of five.
- The headless side printed
  `014170666267324338695802019852130323539336393409106198683050`
  for the same pair; concatenating the twelve groups on the screen gives the
  same 60 digits. The number is symmetric — either side computes it from both
  identities — and the two sides agree.
