# A push sound of the chat's own, and direct/group defaults

Date: 2026-09-01. Simulator `fable-snd` (created and deleted for the run),
the alfa fixture home, the shared stand.

## The shape

The chat's sound is a flag on the receiver's UserDO (`sound` in ChatFlags,
set through `POST /api/chats/:id/flags`), the user's defaults by chat shape
live next to it (`/api/notify-sounds`), and the object resolves them when it
sends the push: the chat's own sound, then the shape default, then
"default". The aps sound names one of three caf chimes the app bundles
(synthesized sine chimes, ~0.5 s). The sender changes nothing: the sound is
the receiver's.

Pickers: «Звук уведомлений» on the chat info screen (with a preview on
choice via AVAudioPlayer), «Звук: личные чаты» / «Звук: группы» in Settings →
Notifications.

## Checks

- smoke (push receiver on the APNs mock): the group default rides the push,
  the chat's own sound beats it, clearing both returns to "default" — with
  the full suite ALL PASS.
- `tsc --noEmit` clean; the app builds with the three caf files in the
  bundle.
- Live: chat info → «Звук уведомлений» → «Перезвон»; the flag landed on the
  server (`GET /api/chats/:id/flags` → `"sound":"chime1.caf"`). Returned to
  default after the run.
- Not verified: the audible ring of a real push — the shared stand's pushes
  reach no simulator, and the NSE path needs a device; the payload is
  asserted at the APNs mock instead.

## In passing

A `fixture.py install` interrupted by a tool timeout leaves the device
granted but the home not installed; the rerun healed it. Worth a note: the
command takes over a minute (the notification grant reboots the device), so
background it.
