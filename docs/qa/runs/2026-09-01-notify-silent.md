# A silent notification sound — live run

2026-09-01, simulator fable-a (carduser), the shared stand.

## Scenario

1. The chat's card → «Звук уведомлений» now lists «Стандартный», the three
   bundled chimes and «Без звука» (`2026-09-01-sound-silent-picker.png`).
2. Picked «Без звука». The row shows the choice and the stand answered
   `POST /api/chats/<id>/flags 200` (`2026-09-01-sound-silent-set.png`).

## Verified

- The smoke's sound block: a chat set to `none` pushes with no `sound` field
  in `aps` at all, while the chime and default cases keep riding the push
  (`node test/smoke.mjs`, ALL PASS).
- The choice reaches the device through the push itself, so the system plays
  it — or stays quiet — whether the notification extension ran or not.

A mention's own sound is not part of this: the server cannot see a mention
in an encrypted message, so that choice belongs to the extension and needs a
device to be seen at all.
