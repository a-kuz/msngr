# A jump to a date, run

The simulator `fable-solo` (iPhone 17 / iOS 26.5) as the fixture account
`alfa` (the reseeded trio), in the direct chat with `charlie`.

- Tapping a date separator in the feed — and the floating day capsule, which
  shares the same handler — opens the calendar as a half-height sheet.
- `01-calendar.png` — the sheet: the month title with chevrons, the weekday
  row led by the system's first weekday, only days that hold messages answer
  (today, ringed, is the only one — the reseeded fixture's history is a
  single day), the rest are dimmed and dead, and the chevrons are disabled
  where the history does not reach.
- `02-landed-on-day.png` — picking the day closes the sheet and the feed
  lands on the day's first message: «История начинается здесь», the
  «Сегодня» separator and «Hi, Charlie.» at the top of the screen. The jump
  rides the same `ensureLoaded` the pinned bar uses, which the pin-depth run
  took a thousand messages deep.
- `03-capsule-entry-point.png` — the floating capsule mid-scroll over a
  hundred-message history: the second way in. Its 0.9 s fade window did not
  survive the synthesized-tap latency of this session, so the capsule entry
  is exercised by the shared code path rather than a recorded tap; the
  separator entry above is the recorded one.
- The sheet takes an explicit opaque background: the first take showed the
  bubbles underneath reading through the system material.
