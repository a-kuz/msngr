# Sender keys in a group, and the rotation when a member leaves

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803, in the `Standup` group of the
fixture trio. Bravo and charlie ran as headless engines
(`msngrfixture typing`), each syncing and decrypting into its own home.

## Seen

- Alfa sent «Sender key probe one»: both engines' databases held the plaintext
  at seq 13 within five seconds — the group message travelled as one
  sender-key box and opened on both peers.
- Bravo left the group (`POST /api/chats/:id/delete`, the group form of
  delete). No journal frame was written for it; the member set reached alfa
  through the announce path, and alfa's `member` table dropped bravo.
- The leave dropped alfa's `senderKeyOut` row for the chat — the old chain is
  gone, not reused.
- Alfa sent «Sender key probe two»: seq 14 in the journal is the fresh key
  handout (`service: true`), seq 15 the message. A new `senderKeyOut` row
  appeared with a different state and `distributedTo` holding only charlie's
  device; charlie decrypted the text, and bravo's home stayed at seq 13 — the
  departed member got no fanout and no new key.

The unit ground for the same behaviour is CryptoTests and
CoreIntegrationTests `testGroupChatSenderKeys`.
