# A delete arriving before its original — live run, and the hole it found

2026-08-29, headless over the real engine (`msngrfixture`, the same
`MsngrCore` the app runs) against a throwaway stand (`wrangler dev --port
8807`, own persist dir, migrations applied), a fresh trio seeded into
`.claude/scratch/fable-del/fixtures`. `msngrfixture` gained a `delete`
subcommand for the scenario: deletes the account's own latest message for
everyone, in a direct chat or a group by title.

## Staging

The ROADMAP note names the live trigger: a content frame stuck in
`pendingDecrypt` behind a missing group sender key. Staged exactly so:

1. alfa's copy of bravo's sender key for the group «Random» was deleted from
   alfa's device database.
2. alfa's engine was brought up and kept running.
3. bravo sent «doomed message» into the group and deleted it for everyone,
   then went offline.

Mid-run state on alfa, as designed: the envelope in `pendingDecrypt`
(seq 13, `no_sender_key`), the delete buffered in `pendingApply`
(`targetSeq 13, deleted`), no message row.

## The hole

The scenario then stopped resolving: over two joint online windows (up to
100 s, both engines up) alfa burned repair attempts against silence —
`repairAttempts` grew, `sentServiceFrame` on bravo stayed empty, the key
never returned. The cause is in `answerRepairRequest`: a row with
`deletedForAll` is excluded from answering with content, and the
service-frame fallback finds nothing for a content seq, because a delete is
a plain server act (`{t:"delete"}` → journal tombstone → `{t:"deleted"}`
fanout), not a service frame. Nobody can ever answer that repair: the asker
would spend all 5 attempts, keep the envelope for its 7-day TTL and hold the
buffered delete forever, showing a feed placeholder for a message that is
deleted for everyone. Logged in `docs/qa/defects.md` (closed the same day).

## The fix, verified

A deleted message needs no decryption. Both orders settle the seq with a
tombstone now:

- a `deleted` frame covering a seq held in `pendingDecrypt` writes the
  tombstone right in the handler;
- an envelope whose delete was buffered first is buried by the sweep, ahead
  of the retry gate (`tombstoneDeferred`).

Units: `testDeleteSettlesEnvelopeHeldInPendingDecrypt`,
`testBufferedDeleteBuriesEnvelopeOnReplay`; the full core suite is green
(444 tests, 0 failures). Live: the stand still held the stuck state from
before the fix — the first engine pass of the fixed build healed it, no
human involved:

```
pendingDecrypt 0, pendingApply 0, historyGap(seq 13) 0
message seq 13: deletedForAll=1, text NULL, from bravo
```

The throwaway stand and homes were discarded after the run; the shared trio
was not touched.
