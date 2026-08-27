# Notification actions: quick reply and mute from the banner

Date: 2026-08-27. Simulator: solo-live (165449DB-8D23-4128-B3B0-63D26B8B00C2),
shared stand :8787, fixture alfa3; sender bravo3 via `msngrfixture send`.

## What was delivered

- A `message` notification category with two actions: quick reply
  (`UNTextInputNotificationAction`) and mute. Registered at launch
  (`NotificationCoordinator.setup`).
- The category identifier is stamped on both banner producers: the app's local
  notification (`CommunicationNotification.content`) and the NSE's push banner
  (`PushAnswer.answer`). The constant lives in MsngrCore (`NotificationCategory`).
- Response routing is pure (`NotificationActions.route`): default tap opens the
  chat, reply enqueues the trimmed text through the regular outbox (offline-safe,
  retried), mute writes `chat.muted` locally and sets the server flag. A response
  can launch the app ahead of bootstrap, so handlers wait for the engine.

## Verified

- `MsngrTests/NotificationActionRouteTests` — 7/7 green on gate-runner: default
  tap, trimmed reply, empty reply, mute, missing chatId, dismiss/unknown actions,
  category composition.
- Live: with the app backgrounded, a message from bravo raised the local banner
  («Bravo Service — Проверка быстрого ответа»), visible in the shade.

## Not verified, and why

- The expanded banner with the visible «Ответить»/«Без звука» buttons: the
  SpringBoard context-menu press cannot be produced by idb HID on the simulator
  (tap with `--duration` up to 2 s and a zero-length swipe both land as a plain
  tap) — the same class of limitation as the documented status-bar tap. The
  push-driven banner also needs the NSE, which does not run on the simulator.
  Both belong to the device pass that is blocked on the K2 development
  certificate.

## Seen in passing

- On the simulator one message shows two shade entries: the app's local
  notification (decrypted) and the raw APNs-mock push («Новое сообщение»).
  Expected there — the NSE that claims the push never runs on the simulator;
  on a device the claim leaves one banner.
