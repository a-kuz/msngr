# Run: the Notifications settings screen, 2026-09-01

Settings gained a «Уведомления» screen gathering what used to sit inline and
what had no surface at all: the banner preview toggle, the default sounds by
chat shape, and the list of every chat and person that overrides them.

Server: `/sound-exceptions` on UserDO walks the `chat:` and `usnd:` prefixes
and returns the overrides; `GET /api/notify-sounds/exceptions` exposes it.
The smoke sound block covers the listing with both kinds set and the empty
list after both are cleared.

The live run (an own simulator, a fresh user against an own stand):

- The screen renders the toggle with its footnote, the two default pickers,
  and — once a chat sound and a person sound were set through the API — the
  «Чаты со своим звуком» section naming «Избранное» with «Перезвон» and the
  «Люди со своим звуком» section with «Трезвучие»
  (`2026-09-01-notifications-screen-2.png`; the empty state earlier hid both
  sections — `2026-09-01-notifications-screen.png`).
- A person the local database does not know is listed by the raw id: the real
  flow sets a person's sound from their chat, so the name is normally there.
- The sound picker opens with all four chimes in place (seen mid-run).
- Row removal calls the same `setChatFlags`/`setPersonSound` "default" the
  smoke clears the list with; the swipe itself kept reading as a tap under
  the simulator driver, so the UI removal gesture is not in this run's
  frames.

The old Settings section is now a single row leading to this screen.
