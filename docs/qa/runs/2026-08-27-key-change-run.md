# A key change blocks the send until it is accepted

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803.

## How

Charlie's identity changed for real: a fresh X25519+Ed25519 pair with the
`MsngrIdentityDH/1` binding signature was published through
`POST /api/identity` under charlie's token, so the stand hands out an
identity that no longer matches what alfa's `trustedIdentity` holds.

## Seen

- Alfa's send dropped into the block: the outbox row moved to `blocked`, the
  bubble stood with the clock, the system row «Код безопасности собеседника
  изменился» was inserted, and the banner over the composer read «Код
  безопасности изменился / Сообщения не отправляются, пока вы не примете
  новый ключ» with «Принять».
- The tap on «Принять» let it go: the outbox drained, the message got its
  seq and the tick, the banner left; the system row stays in the feed.
