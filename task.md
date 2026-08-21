# A message is (chatId, seq): the second ULID goes away

The tail of step 2 of the backend rework in
`docs/research/2026-08-19-per-user-do.md` — read it first. The first two shapes
of the step are already on main (`01d12ff`): per-member mark keys and the swept
cmid window.

Today every message carries two identities: `seq`, which orders the journal and
the storage keys, and `msgId`, a 26-byte ULID minted by `ConversationDO` on
`/send`. The ULID costs its bytes in every row and every reference to one —
pins, replies, reactions, edits, delete-for-all — and buys nothing: before a
seq exists the client already has `clientMsgId` for idempotency, and after one
exists it names the message better than the ULID does. Worst of it is
`/delete`, which lists the whole journal to match ids where a seq is a single
key read.

What remains: the message's identity becomes `(chatId, seq)` end to end. The
server stops minting `msgId`; every reference that carried one — the pin, the
reply preview, the reaction and edit targets, delete-for-all — carries a seq;
the client's rows and its `pendingApply`/`pendingDecrypt` keys follow. Watch
the places where the client uses the absence of a server id as a state ("not
acknowledged yet, nothing to pin"): that meaning moves to the absence of a seq.
No compatibility, as always: frames and REST change freely, the stand's
accounts re-register, the fixture trio is re-seeded on your own stand with
`msngrfixture seed`.

Closed when: `node test/smoke.mjs` green on your own stand
(`wrangler dev --port 8803`, `PUSH_PORT=9873`, ports per CLAUDE.md);
`swift test` in MsngrKit and MsngrTests green; and a live run over two fixture
simulators that exercises exactly the references that changed — pin a message
and jump to it, reply and open the quote, react, edit, delete-for-all and see
the tombstone on both sides. Report in `docs/qa/runs/`, `make check` in the
background afterwards, log to `.claude/gates/run-msgid.log`.

Do not restart or wipe the shared stand on :8787; run your own. Create your
own simulators, name them after yourself, delete them after.
