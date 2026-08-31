# Named exceptions over the privacy tiers

Date: 2026-08-31. Simulator `fable-exc` (created and deleted for the run),
the alfa fixture home, the shared stand (migration 0013 applied).

## The shape

`privacy_exceptions (user_id, setting, peer_id, allow)`: an allow row shows
the setting to that person whatever the tier says, a deny row hides it the
same way. Every tier check — last seen (the REST card and the presence
fanout), avatar and bio (cards, search, chat lists, the bytes), phone
discovery, group adds — routes through one `privacyAllows`, which reads the
exception first and only then the tier. The exceptions API lists rows with
names and writes or clears one row per call.

The client: an «Исключения» link under every tier on the Privacy screen —
always/never lists, people added through the user search, removed with a
swipe.

## Checks

- smoke: a deny beats the contacts tier (a contact loses the bio), clearing
  returns to the tier, an allow beats nobody (a stranger finds the hidden
  number) — with the full suite ALL PASS.
- `tsc --noEmit` clean; `swift test` 531 tests, 0 failures.
- Live on the simulator: Privacy → Последнее посещение → Исключения →
  «Никогда не показывать» → user search → pick; the row appeared on the
  screen and `GET /api/privacy/exceptions` returned it
  (`last_seen deny @excpeer100`). Removed after the run.

## In passing

The simulator's hardware keyboard layout (Russian) survives respring, reboot
and an `AppleKeyboards` defaults write; `idb ui text` types Cyrillic for
Latin keystrokes. The run searched by a Cyrillic display name registered for
the purpose. Two levers worth building: a grid.py flag for text entry via
pasteboard, and lowercase-insensitive search for Cyrillic (SQLite LOWER folds
ASCII only — a user typing «Икфм» does not find «икфмц»; the server should
fold case in JS before matching). The search defect is logged in
docs/qa/defects.md.
