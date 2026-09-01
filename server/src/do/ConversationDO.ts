import type { Env, ChatState, ChatMember, ChatPolicy, StoredMsg, ServerFrame, PublicUser } from "../types";
import { json, err, seqKey, SEQ_PAD, nowSec, shouldArmAlarm, readPrivacy, privacyAllows } from "../util";
import {
  newCounters, snapshot, diff, logPerf, wrapState, wrapDB, wrapStub, type PerfCounters,
} from "../perf";

/// Fanout queue. A frame is never delivered on the sender's critical path: it
/// is appended as delivery records and pumped by per-recipient chains, so
/// /send answers as soon as the message owns a seq.
///
/// The queue is an outbox, one record per recipient per frame, keyed
/// `fr:<userId>/<jobId>`. A record lives until the recipient's session object
/// acknowledges the delivery: a failure moves its retry deadline out on a
/// growing pause and never gives the record up. Order is kept per recipient —
/// each has one chain, delivering their records oldest first — and the chains
/// are independent, so one recipient timing out delays nobody else, and a
/// receipt never waits behind another member's messages. The alarm is a
/// watchdog: a chain cut short (eviction, crash) is re-run from storage and
/// redelivers whatever was in flight; the recipient's session dedupes a repeat
/// by the chat's seq and answers "already have it".
const FANOUT_PREFIX = "fr:";
/// A scheduled send waiting for its moment: an encrypted envelope, keyed by
/// sender and clientMsgId so a reschedule or an edit replaces it in place.
const DEFER_PREFIX = "defer:";

interface DeferredSend {
  from: string;
  fromDevice: string;
  clientMsgId: string;
  sentAt: number;
  body: unknown;
  dueAt: number; // ms since epoch
}
/// Subrequests one alarm invocation is allowed to spend before rescheduling
/// itself; the platform ceiling is 1000 per invocation and the next alarm gets
/// a fresh budget, so audience size is not capped by it.
const FANOUT_BUDGET = 800;
/// Pause before the next pass over a failed record, by the number of passes
/// already failed; the last value repeats until the recipient answers. The
/// ceiling is what a recovered recipient waits for their backlog at worst,
/// and what a dead one costs per chat: one delivery call per pause.
const FANOUT_RETRY_MS = [200, 1_000, 2_000, 5_000, 10_000];
/// A recipient that stops answering fails its own delivery after this and is
/// retried on the growing pause; the rest of the chat does not wait for it.
const FANOUT_DELIVERY_TIMEOUT_MS = 10_000;
/// A record that waits longer than this before its first delivery pass is
/// reported. Retries and a long burst stay well under it, so a line in the log
/// means the queue was standing still — the one failure a client on a live
/// socket cannot see for itself.
const FANOUT_STALL_MS = 15_000;
/// Records one drain step lists. Bounds the listing, not the queue: records
/// past it wait for the ones in front of them to clear.
const FANOUT_SCAN = 512;
/// How far behind the watchdog alarm runs. Deliveries are pumped by the
/// requests that queue them; the alarm only picks up what a dead isolate or a
/// cut listing left behind, so records survive anything by at most this.
const FANOUT_WATCHDOG_MS = 2_000;

/// Journal records one /history page returns. Durable Objects read at most 128
/// keys per batch, so a larger page would be served by several reads anyway.
const HISTORY_PAGE = 128;

/// One record per message removed for everyone, keyed by the padded seq so the
/// chat tail is read without walking the journal: a client that reconnects asks
/// for the tombstones of a chat, and there are as many of those as messages
/// were actually deleted.
const TOMB_PREFIX = "tomb:";

function tombKey(seq: number): string {
  return TOMB_PREFIX + String(seq).padStart(SEQ_PAD, "0");
}

/// A member's marks live one small key each (`mark:<kind>:<userId>`), so a
/// receipt writes that member's pair instead of rewriting every member's
/// numbers in one record: `read` is what read receipts were sent for, `dlvr`
/// is delivery, `seen` is the counting mark unread is measured against.
const MARK_PREFIX = "mark:";

/// An idempotency record has done its work once the sender stopped retrying
/// its clientMsgId, which happens when the ack or the echo reaches them. Swept
/// when the sender's delivered mark has passed the record's seq and the record
/// has aged out — the age guards a second device of the same account that was
/// still offline with the retry while the first one acknowledged.
const CMID_PREFIX = "cmid:";
const CMID_MIN_AGE_SEC = 72 * 3600;
const CMID_SWEEP_EVERY_SEC = 3600;

interface Tombstone {
  seq: number;
  /// who removed it
  by: string;
  /// the member the message was withheld from: it never reached them, so its
  /// tombstone is not theirs either
  blockedFor?: string;
}

interface DeliveryRecord {
  frame: ServerFrame;
  /// when the record entered the queue (ms since epoch)
  queuedAt: number;
  /// delivery passes already failed
  attempt: number;
  /// not delivered before this (ms since epoch)
  nextAt: number;
}

function deliveryKey(userId: string, id: number): string {
  return FANOUT_PREFIX + userId + "/" + String(id).padStart(16, "0");
}

function deliveryUser(key: string): string {
  return key.slice(FANOUT_PREFIX.length, key.lastIndexOf("/"));
}

/// Retrying typing or a call relay makes no sense: each is superseded by the
/// next frame of its kind and stops mattering within seconds. Everything else
/// is worth another pass.
function fanoutRetryable(frame: ServerFrame): boolean {
  return frame.t !== "typing" && frame.t !== "callRelay";
}

interface Meta {
  chatId: string;
  kind: "direct" | "group" | "self";
  title: string | null;
  avatarId: string | null;
  description: string | null;
  sendPolicy?: ChatPolicy;
  invitePolicy?: ChatPolicy;
  createdBy: string;
  createdAt: number;
  /// Pinned messages by seq, in the order they were pinned; the newest pin is
  /// the last element and the one the bar shows first.
  pinnedSeqs?: number[];
  lastSeq: number;
  /// How many messages of the chat are content. A seq is spent on every frame,
  /// including the ones a client never shows — an edit, a reaction, a sender key
  /// handed out after the roster changed — so the badge is counted in these and
  /// not in seqs. Each message stores the count as of itself, which is what a
  /// member's mark is measured against.
  contentCount: number;
  /// When idempotency records were last swept (seconds since epoch).
  cmidSweptAt?: number;
}

/// A policy an older chat has no value for is the permissive one.
function policy(value: ChatPolicy | undefined): ChatPolicy {
  return value === "admins" ? "admins" : "all";
}

export class ConversationDO implements DurableObject {
  private meta: Meta | null = null;
  private members: Map<string, ChatMember> | null = null;
  /// Recipients whose delivery chain is running (in-memory; the persisted
  /// records are the truth). Checked and set synchronously, so a recipient
  /// never has two chains at once — which is what keeps their frames in order.
  private pumping = new Set<string>();
  /// Recipients whose queue grew while their chain was ending: the chain takes
  /// one more look instead of leaving the record to the watchdog.
  private kicked = new Set<string>();
  /// True while alarm() runs. setAlarm during a running alarm handler cancels
  /// the handler mid-await (workerd: "canceled with requestScheduledAlarm"),
  /// which kills the chains it is awaiting — so while the handler runs, arming
  /// requests collect here and the handler arms the nearest one as it leaves.
  private alarmRunning = false;
  private rearmDelay: number | undefined;
  /// Which side of a direct pair has blocked the other, as the set of blockers. The
  /// truth lives in the blocks table in D1; this is read lazily and dropped on
  /// /block-changed.
  private blockers: Set<string> | null = null;

  /// dev measurement (PERF_LOG); never installed otherwise
  private perf: PerfCounters | null = null;

  constructor(private state: DurableObjectState, private env: Env) {
    if (env.PERF_LOG) {
      this.perf = newCounters();
      this.state = wrapState(state, this.perf);
      this.env = { ...env, DB: wrapDB(env.DB, this.perf) };
    }
  }

  private async loadMeta(): Promise<Meta | null> {
    if (!this.meta) this.meta = (await this.state.storage.get<Meta>("meta")) ?? null;
    return this.meta;
  }

  /// The three whole-map mark records a chat may have been created with are
  /// split into per-member keys once; set after the check so it runs one time
  /// per object life.
  private marksMigrated = false;

  private markKey(kind: "read" | "dlvr" | "seen", userId: string): string {
    return `${MARK_PREFIX}${kind}:${userId}`;
  }

  /// One member's mark; zero when it was never set.
  private async markOf(kind: "read" | "dlvr" | "seen", userId: string): Promise<number> {
    await this.migrateMarks();
    return (await this.state.storage.get<number>(this.markKey(kind, userId))) ?? 0;
  }

  /// Every member's marks of one kind, for the frames that carry the whole map.
  private async markMap(kind: "read" | "dlvr" | "seen"): Promise<Record<string, number>> {
    await this.migrateMarks();
    const prefix = `${MARK_PREFIX}${kind}:`;
    const out: Record<string, number> = {};
    for (const [k, v] of await this.state.storage.list<number>({ prefix }))
      out[k.slice(prefix.length)] = v;
    return out;
  }

  private async migrateMarks(): Promise<void> {
    if (this.marksMigrated) return;
    this.marksMigrated = true;
    const legacy: Array<["read" | "dlvr" | "seen", string]> = [
      ["read", "readMarks"], ["dlvr", "deliveredMarks"], ["seen", "seenMarks"],
    ];
    for (const [kind, record] of legacy) {
      const map = await this.state.storage.get<Record<string, number>>(record);
      if (!map) continue;
      const entries = Object.entries(map);
      // storage writes take at most 128 keys per batch
      for (let i = 0; i < entries.length; i += 100) {
        const batch: Record<string, number> = {};
        for (const [userId, seq] of entries.slice(i, i + 100))
          batch[this.markKey(kind, userId)] = seq;
        await this.state.storage.put(batch);
      }
      await this.state.storage.delete(record);
    }
  }

  /// Drops idempotency records nothing will ask for again. Runs from /send at
  /// most once per CMID_SWEEP_EVERY_SEC, capped per pass so a backlog is eaten
  /// over several sends rather than in one long stall.
  private async sweepCmids(meta: Meta, now: number): Promise<void> {
    const every = Number(this.env.CMID_SWEEP_EVERY ?? CMID_SWEEP_EVERY_SEC);
    const minAge = Number(this.env.CMID_MIN_AGE ?? CMID_MIN_AGE_SEC);
    if (now - (meta.cmidSweptAt ?? 0) < every) return;
    meta.cmidSweptAt = now;
    await this.state.storage.put("meta", meta);
    const dlvr = await this.markMap("dlvr");
    const doomed: string[] = [];
    const listed = await this.state.storage.list<{ seq: number; ts: number }>(
      { prefix: CMID_PREFIX });
    for (const [key, rec] of listed) {
      const from = key.slice(CMID_PREFIX.length).split("/", 1)[0];
      if (rec.seq <= (dlvr[from] ?? 0) && now - rec.ts >= minAge) doomed.push(key);
      if (doomed.length >= 512) break;
    }
    for (let i = 0; i < doomed.length; i += 128)
      await this.state.storage.delete(doomed.slice(i, i + 128));
  }

  private async loadMembers(): Promise<Map<string, ChatMember>> {
    if (!this.members) {
      const listed = await this.state.storage.list<ChatMember>({ prefix: "member:" });
      this.members = new Map();
      for (const [, m] of listed) this.members.set(m.userId, m);
    }
    return this.members;
  }

  /// Content messages written after the one a mark stands on.
  ///
  /// Both ends of the subtraction are counts of content, so the frames a client
  /// never shows fall out of it: whatever seqs an edit, a reaction or a sender
  /// key spent between the mark and the end of the chat, the number is what the
  /// reader will actually be handed. A mark at zero has the whole chat ahead
  /// of it.
  private async unreadFrom(mark: number): Promise<number> {
    const meta = await this.loadMeta();
    if (!meta) return 0;
    const total = meta.contentCount ?? 0;
    if (mark <= 0) return total;
    const at = (await this.state.storage.get<StoredMsg>(seqKey(mark)))?.contentAt;
    return Math.max(0, total - (at ?? total));
  }

  private userStub(userId: string) {
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(userId));
    return this.perf ? wrapStub(stub, this.perf) : stub;
  }

  /// Block state of a direct chat as seen from member `me`. Null for groups and for
  /// chats `me` is not a member of.
  private async blockCheck(
    me: string
  ): Promise<{ peer: string; byMe: boolean; byPeer: boolean } | null> {
    const meta = await this.loadMeta();
    if (meta?.kind !== "direct") return null;
    const members = await this.loadMembers();
    if (!members.has(me)) return null;
    const peer = [...members.keys()].find((u) => u !== me);
    if (!peer) return null;
    if (!this.blockers) {
      const rows = await this.env.DB.prepare(
        "SELECT user_id FROM blocks WHERE (user_id = ? AND blocked_id = ?) OR (user_id = ? AND blocked_id = ?)"
      ).bind(me, peer, peer, me).all<{ user_id: string }>();
      this.blockers = new Set(rows.results.map((r) => r.user_id));
    }
    return { peer, byMe: this.blockers.has(me), byPeer: this.blockers.has(peer) };
  }

  /// Whether a block exists in either direction. Under one, receipts, typing and
  /// presence stop travelling both ways.
  private async blockedEitherWay(userId: string): Promise<boolean> {
    const b = await this.blockCheck(userId);
    return !!b && (b.byMe || b.byPeer);
  }

  /// Members of `userIds` who turned a privacy flag off themselves. Read receipts
  /// and typing are reciprocal: turning one off both stops sending it and stops
  /// receiving it, so a member with the flag off belongs on the fanout skip list
  /// the same as a blocked one.
  private async membersWithFlagOff(
    userIds: string[], flag: "readReceipts" | "typing"
  ): Promise<string[]> {
    const settings = await Promise.all(
      userIds.map((u) => readPrivacy(this.env.DB, u).then((p) => ({ u, on: p[flag] })))
    );
    return settings.filter((s) => !s.on).map((s) => s.u);
  }

  private async fanout(
    frame: ServerFrame,
    opts?: { except?: string; only?: string[]; skip?: string[] }
  ) {
    const members = await this.loadMembers();
    const targets = (opts?.only ?? [...members.keys()]).filter(
      (u) => u !== opts?.except && !opts?.skip?.includes(u) && members.has(u)
    );
    await this.enqueueFanout(frame, targets);
  }

  private async enqueueFanout(frame: ServerFrame, targets: string[]) {
    if (!targets.length) return;
    const id = (await this.state.storage.get<number>("fqNext")) ?? 1;
    const now = Date.now();
    const record: DeliveryRecord = { frame, queuedAt: now, attempt: 0, nextAt: now };
    const entries: Record<string, DeliveryRecord | number> = { fqNext: id + 1 };
    for (const u of targets) entries[deliveryKey(u, id)] = record;
    // one storage write takes at most 128 pairs
    const keys = Object.keys(entries);
    for (let i = 0; i < keys.length; i += 128) {
      const chunk: Record<string, DeliveryRecord | number> = {};
      for (const k of keys.slice(i, i + 128)) chunk[k] = entries[k];
      await this.state.storage.put(chunk);
    }
    // the watchdog alarm re-pumps from storage if the isolate dies mid-delivery
    await this.scheduleFanout(FANOUT_WATCHDOG_MS);
    this.kickPumps(targets);
  }

  /// Starts a delivery chain per recipient, off the caller's critical path: the
  /// enqueueing request answers while the chains run. A chain that ends on a
  /// backoff arms the alarm for its deadline; a chain that dies with the
  /// isolate is re-run from storage by the watchdog.
  private kickPumps(users: string[]) {
    for (const u of users) {
      void this.pumpUser(u, { left: FANOUT_BUDGET })
        .then((at) =>
          at !== undefined ? this.scheduleFanout(at - Date.now()) : undefined
        )
        .catch((e) => console.error(`fanout: pump for ${u} died: ${e}`));
    }
  }

  /// Arms the alarm, keeping whichever deadline is nearer.
  private async scheduleFanout(delayMs: number) {
    if (this.alarmRunning) {
      this.rearmDelay =
        this.rearmDelay === undefined ? delayMs : Math.min(this.rearmDelay, delayMs);
      return;
    }
    // strictly in the future, so the write is never mistaken for the alarm that
    // is running right now
    const now = Date.now();
    const at = now + Math.max(delayMs, 1);
    const pending = await this.state.storage.getAlarm();
    if (!shouldArmAlarm(pending, at, now)) return;
    await this.state.storage.setAlarm(at);
  }

  /// The deadline is dropped as soon as the delivery answers: a timer per
  /// delivery that outlives it piles up at burst rate, and once the runtime's
  /// timer budget is gone every delivery in the chat fails at once.
  private async deliver(userId: string, body: string) {
    const abort = new AbortController();
    const deadline = setTimeout(() => abort.abort(), FANOUT_DELIVERY_TIMEOUT_MS);
    try {
      const res = await this.userStub(userId).fetch("https://do/event", {
        method: "POST",
        body,
        signal: abort.signal,
      });
      if (!res.ok) throw new Error(`status ${res.status}`);
    } finally {
      clearTimeout(deadline);
    }
  }

  /// Delivers one recipient's records in the order the chat produced them,
  /// until their queue is empty, a backoff pushes their head into the future,
  /// or the budget runs out. Returns when to come back (ms since epoch), or
  /// undefined when nothing of theirs is left waiting on this chain.
  private async pumpUser(
    user: string,
    budget: { left: number }
  ): Promise<number | undefined> {
    if (this.pumping.has(user)) {
      // a chain is already on it; make sure it looks again before it ends
      this.kicked.add(user);
      return undefined;
    }
    this.pumping.add(user);
    const chatId = this.meta?.chatId ?? "";
    const latency = Number(this.env.DEV_WS_LATENCY_MS ?? 0);
    try {
      for (;;) {
        this.kicked.delete(user);
        const listed = await this.state.storage.list<DeliveryRecord>({
          prefix: FANOUT_PREFIX + user + "/",
          limit: 32,
        });
        if (!listed.size) {
          // a record queued during this chain arrived after the listing above:
          // look once more instead of ending on a stale empty read
          if (this.kicked.has(user)) continue;
          return undefined;
        }
        for (const [key, rec] of listed) {
          if (budget.left <= 0) return Date.now();
          if (rec.nextAt > Date.now()) return rec.nextAt;
          budget.left--;
          // the queue standing still is invisible to a client whose socket is
          // healthy, so the delay it caused is said out loud here
          const waited = Date.now() - rec.queuedAt;
          if (rec.attempt === 0 && waited > FANOUT_STALL_MS) {
            console.error(
              `fanout: ${rec.frame.t} in ${chatId} waited ${waited}ms before delivery`
            );
          }
          // dev: artificial network latency per delivery (DEV_WS_LATENCY_MS)
          if (latency > 0 && rec.attempt === 0) {
            await new Promise((r) => setTimeout(r, latency));
          }
          try {
            await this.deliver(user, JSON.stringify(rec.frame));
            await this.state.storage.delete(key);
          } catch (e) {
            console.warn(
              `fanout: ${rec.frame.t} to ${user} in ${chatId} failed ` +
                `(attempt ${rec.attempt + 1}): ${e}`
            );
            if (!fanoutRetryable(rec.frame)) {
              // superseded within seconds: drop it and keep the chain going
              await this.state.storage.delete(key);
              continue;
            }
            const attempt = rec.attempt + 1;
            const retryMs =
              FANOUT_RETRY_MS[Math.min(attempt - 1, FANOUT_RETRY_MS.length - 1)];
            const nextAt = Date.now() + retryMs;
            await this.state.storage.put(key, { ...rec, attempt, nextAt });
            return nextAt;
          }
        }
      }
    } finally {
      this.pumping.delete(user);
    }
  }

  /// Writes one message into the journal and fans it out: the shared tail of
  /// /send and of a deferred envelope coming due. The caller has already
  /// checked membership, policy and the sender's own block.
  /// ackToSender queues a `sent` frame to the author ahead of the message
  /// echo: a deferred envelope has no request to answer, so the ack that a
  /// live send gets on its socket travels the delivery queue instead.
  private async journal(
    meta: Meta,
    b: { from: string; fromDevice: string; clientMsgId: string; sentAt: number;
         body: unknown; service?: boolean; notify?: boolean },
    blockedFor: string | null,
    ackToSender = false
  ): Promise<{ seq: number; ts: number }> {
    const seq = meta.lastSeq + 1;
    // the counter moves only on what a client will show, and every message
    // keeps where it stood: one number written here answers every later
    // question about how much of the chat a member has not seen
    const contentAt = (meta.contentCount ?? 0) + (b.service ? 0 : 1);
    const msg: StoredMsg = {
      seq, from: b.from, fromDevice: b.fromDevice,
      clientMsgId: b.clientMsgId, sentAt: b.sentAt, ts: nowSec(), body: b.body,
      contentAt,
      ...(b.service ? { service: true } : {}),
      ...(blockedFor ? { blockedFor } : {}),
    };
    meta.lastSeq = seq;
    meta.contentCount = contentAt;
    this.meta = meta;
    await this.state.storage.put({
      meta,
      [seqKey(seq)]: msg,
      [`cmid:${b.from}/${b.clientMsgId}`]: { seq, ts: msg.ts },
    });

    const frame: ServerFrame = {
      t: "msg", chatId: meta.chatId, seq,
      from: msg.from, fromDevice: msg.fromDevice,
      // the author's own devices close their outbox row from the echo alone:
      // the `sent` ack rides the live socket and does not survive one being down
      clientMsgId: msg.clientMsgId,
      sentAt: msg.sentAt, ts: msg.ts, body: msg.body,
      ...(msg.service ? { service: true } : {}),
      // a service frame that still raises a push (a missed-call record):
      // live delivery only, the journal replays it silent
      ...(b.service && b.notify ? { notify: true } : {}),
    };
    // Under a block the send still succeeds and the sender sees "sent", but nothing
    // reaches the other side, over the socket or by push. The blocker's read mark
    // moves at once, or his unread would grow on messages he will never see.
    // The seen mark is the counting one unread is measured against: an
    // author does not count their own message, and neither does someone the
    // message was withheld from. Kept apart from the read marks because
    // read receipts are sent for those alone: sending a message is not a
    // claim that others were read. seq is the new head of the journal, so
    // it is ahead of any mark by construction.
    await this.migrateMarks();
    const blocked = await this.blockedPeers(b.from);
    const markBatch: Record<string, number> = { [this.markKey("seen", b.from)]: seq };
    for (const u of blocked) {
      markBatch[this.markKey("read", u)] = seq;
      markBatch[this.markKey("seen", u)] = seq;
    }
    await this.state.storage.put(markBatch);
    await this.sweepCmids(meta, msg.ts);
    // ack answers the sender as soon as the message owns a seq; delivery
    // (and the APNs call behind it) runs in the alarm queue afterwards.
    // Author's own devices are targets too: the echo goes through his UserDO.
    if (ackToSender) {
      await this.fanout(
        { t: "sent", chatId: meta.chatId, clientMsgId: b.clientMsgId, seq, ts: msg.ts },
        { only: [b.from] });
    }
    await this.fanout(frame, { skip: blocked });
    return { seq, ts: msg.ts };
  }

  /// Journals every deferred envelope whose time has come. A sender who has
  /// since left the chat or blocked the peer loses the envelope silently — the
  /// send would have been refused; one who is blocked by the peer is journaled
  /// withheld, the way /send stores it. Returns the nearest future deadline.
  private async drainDeferred(): Promise<number | undefined> {
    const meta = await this.loadMeta();
    if (!meta) return undefined;
    const listed = await this.state.storage.list<DeferredSend>({ prefix: DEFER_PREFIX });
    let next: number | undefined;
    // due envelopes go out in the order they were meant to leave
    const due = [...listed]
      .filter(([, d]) => d.dueAt <= Date.now())
      .sort((a, b) => a[1].dueAt - b[1].dueAt);
    for (const [, d] of listed.entries()) {
      if (d.dueAt > Date.now())
        next = next === undefined ? d.dueAt : Math.min(next, d.dueAt);
    }
    for (const [key, d] of due) {
      const members = await this.loadMembers();
      const block = await this.blockCheck(d.from);
      if (!members.has(d.from) || block?.byMe) {
        await this.state.storage.delete(key);
        continue;
      }
      const dupe = await this.state.storage.get(`cmid:${d.from}/${d.clientMsgId}`);
      if (!dupe) {
        await this.journal(meta, d, block?.byPeer ? block.peer : null, true);
      }
      await this.state.storage.delete(key);
    }
    return next;
  }

  /// The recovery path. Deliveries are pumped by the requests that queue them;
  /// the alarm walks whatever storage still holds — backoffs come due, records
  /// whose chain died with the isolate — and re-arms for the nearest deadline.
  async alarm() {
    if (!this.perf) return this.drainAlarm();
    const before = snapshot(this.perf);
    const t0 = Date.now();
    try {
      return await this.drainAlarm();
    } finally {
      logPerf("conv", "alarm", Date.now() - t0, diff(this.perf, before), snapshot(this.perf),
              { chatId: this.meta?.chatId });
    }
  }

  private async drainAlarm() {
    this.alarmRunning = true;
    this.rearmDelay = undefined;
    try {
      await this.loadMeta();
      // scheduled sends whose time has come enter the journal first: their
      // fanout records are then drained by the very pumps below
      const nextDeferred = await this.drainDeferred();
      if (nextDeferred !== undefined) {
        this.rearmDelay = nextDeferred - Date.now();
      }
      const budget = { left: FANOUT_BUDGET };
      const listed = await this.state.storage.list<DeliveryRecord>({
        prefix: FANOUT_PREFIX,
        limit: FANOUT_SCAN,
      });
      const users = new Set<string>();
      for (const key of listed.keys()) users.add(deliveryUser(key));
      const wakes = await Promise.all([...users].map((u) => this.pumpUser(u, budget)));
      let next: number | undefined;
      for (const at of wakes) {
        if (at !== undefined) next = next === undefined ? at : Math.min(next, at);
      }
      // records can be left with no wake asked for: a chain that was already
      // running took the guard, or the listing was cut by FANOUT_SCAN. The
      // watchdog covers both.
      const remaining = await this.state.storage.list({ prefix: FANOUT_PREFIX, limit: 1 });
      if (remaining.size) {
        const watchdog = Date.now() + FANOUT_WATCHDOG_MS;
        next = next === undefined ? watchdog : Math.min(next, watchdog);
      }
      if (next !== undefined) {
        this.rearmDelay = this.rearmDelay === undefined
          ? next - Date.now()
          : Math.min(this.rearmDelay, next - Date.now());
      }
    } finally {
      this.alarmRunning = false;
      if (this.rearmDelay !== undefined) {
        const delay = this.rearmDelay;
        this.rearmDelay = undefined;
        await this.scheduleFanout(delay);
      }
    }
  }

  /// Queue depth in delivery records (counted up to a page), how many
  /// recipients they wait on, how long the oldest has been waiting and whether
  /// a drain is actually coming for it.
  ///
  /// `armed` is false for a moment between the runtime taking the alarm and
  /// the handler starting, so a queue that stands still is recognised by
  /// `oldestMs` growing instead: nothing being sent to a chat whose sockets are
  /// all healthy is the one failure a member cannot tell from an idle chat.
  private async fanoutState() {
    const listed = await this.state.storage.list<DeliveryRecord>({
      prefix: FANOUT_PREFIX,
      limit: 128,
    });
    const now = Date.now();
    const users = new Set<string>();
    let oldestMs: number | null = null;
    let attempt = 0;
    for (const [key, rec] of listed) {
      users.add(deliveryUser(key));
      oldestMs = Math.max(oldestMs ?? 0, now - rec.queuedAt);
      attempt = Math.max(attempt, rec.attempt);
    }
    const pending = await this.state.storage.getAlarm();
    const armed =
      this.pumping.size > 0 || this.alarmRunning || (pending !== null && pending > now);
    if (!armed && oldestMs !== null && oldestMs > FANOUT_STALL_MS) {
      console.error(
        `fanout: ${listed.size} record(s) in ${this.meta?.chatId} waiting ${oldestMs}ms ` +
          `with no drain armed`
      );
    }
    return {
      pending: listed.size,
      recipients: users.size,
      attempt,
      oldestMs,
      armed,
    };
  }

  /// Members of a direct chat a message is not delivered to because of a block,
  /// whichever side set it.
  private async blockedPeers(from: string): Promise<string[]> {
    const meta = (await this.loadMeta())!;
    if (meta.kind !== "direct") return [];
    const members = await this.loadMembers();
    const peers = [...members.keys()].filter((u) => u !== from);
    const out: string[] = [];
    for (const peer of peers) {
      const row = await this.env.DB.prepare(
        "SELECT 1 FROM blocks WHERE (user_id = ? AND blocked_id = ?) OR (user_id = ? AND blocked_id = ?)"
      ).bind(from, peer, peer, from).first();
      if (row) out.push(peer);
    }
    return out;
  }

  private async chatState(): Promise<ChatState> {
    const meta = (await this.loadMeta())!;
    const members = await this.loadMembers();
    const readMarks = await this.markMap("read");
    const deliveredMarks = await this.markMap("dlvr");
    return {
      chatId: meta.chatId,
      kind: meta.kind,
      title: meta.title,
      avatarId: meta.avatarId,
      description: meta.description,
      sendPolicy: policy(meta.sendPolicy),
      invitePolicy: policy(meta.invitePolicy),
      createdBy: meta.createdBy,
      createdAt: meta.createdAt,
      members: [...members.values()],
      pinnedSeqs: meta.pinnedSeqs ?? [],
      lastSeq: meta.lastSeq,
      readMarks,
      deliveredMarks,
    };
  }

  private async broadcastChat(event: string, only?: string[]) {
    const state = await this.chatState();
    await this.fanout(
      { t: "chat", chatId: state.chatId, event, state, users: await this.memberCards(state) },
      only ? { only } : undefined);
  }

  /// The public names of the roster: id, username and display name only. Bio
  /// and avatar are per-viewer private, and this frame goes to every member.
  private async memberCards(state: { members: Array<{ userId: string }> }) {
    const ids = state.members.map((m) => m.userId);
    if (!ids.length) return [];
    const placeholders = ids.map(() => "?").join(",");
    const rows = await this.env.DB.prepare(
      `SELECT id, username, display_name FROM users WHERE id IN (${placeholders})`
    ).bind(...ids).all<{ id: string; username: string; display_name: string }>();
    return rows.results.map((u) => ({ ...u, bio: null, avatar_id: null }));
  }

  private async notifyUserDOsChatList(userIds: string[], removed = false) {
    const meta = (await this.loadMeta())!;
    const path = removed ? "chat-removed" : "chat-added";
    const results = await Promise.allSettled(
      userIds.map(async (u) => {
        const res = await this.userStub(u).fetch(`https://do/${path}`, {
          method: "POST",
          body: JSON.stringify({ chatId: meta.chatId }),
        });
        if (!res.ok) throw new Error(`status ${res.status}`);
      })
    );
    results.forEach((r, i) => {
      if (r.status === "rejected") {
        console.warn(`${path} for ${userIds[i]} in ${meta.chatId} failed: ${r.reason}`);
      }
    });
  }

  async fetch(req: Request): Promise<Response> {
    if (!this.perf) return this.handle(req);
    const before = snapshot(this.perf);
    const t0 = Date.now();
    try {
      return await this.handle(req);
    } finally {
      logPerf("conv", new URL(req.url).pathname, Date.now() - t0, diff(this.perf, before),
              snapshot(this.perf), { chatId: this.meta?.chatId, lastSeq: this.meta?.lastSeq });
    }
  }

  private async handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    if (path === "/create" && req.method === "POST") {
      const b = (await req.json()) as {
        chatId: string; kind: "direct" | "group" | "self"; title: string | null;
        memberIds: string[]; createdBy: string;
      };
      const existing = await this.loadMeta();
      if (existing) {
        // The chat is here, and whoever asks for it wants it in their list: a
        // direct chat one side deleted keeps its membership, so opening it again
        // has to put the row back into that side's own list. Without this the id
        // comes back and the chat does not, and only a message from the peer
        // brings it around.
        if ((await this.loadMembers()).has(b.createdBy)) {
          await this.notifyUserDOsChatList([b.createdBy]);
          await this.broadcastChat("created", [b.createdBy]);
        }
        return json({ ok: true, chatId: existing.chatId, existed: true });
      }
      const now = nowSec();
      this.meta = {
        chatId: b.chatId, kind: b.kind, title: b.title ?? null,
        avatarId: null, description: null,
        sendPolicy: "all", invitePolicy: "all", createdBy: b.createdBy,
        createdAt: now, pinnedSeqs: [], lastSeq: 0, contentCount: 0,
      };
      await this.state.storage.put("meta", this.meta);
      this.members = new Map();
      for (const uid of new Set([b.createdBy, ...b.memberIds])) {
        const m: ChatMember = {
          userId: uid,
          role: b.kind === "group" && uid === b.createdBy ? "admin" : "member",
          joinedAt: now,
          // message request: in a direct chat the recipient has to accept the conversation
          accepted: uid === b.createdBy || b.kind === "group",
        };
        this.members.set(uid, m);
        await this.state.storage.put("member:" + uid, m);
      }
      await this.notifyUserDOsChatList([...this.members.keys()]);
      await this.broadcastChat("created");
      return json({ ok: true, chatId: b.chatId });
    }

    // The blocks in D1 changed, so reread them on the next check. This sits above the
    // meta check because someone can be blocked before the chat is ever created.
    if (path === "/block-changed") {
      this.blockers = null;
      return json({ ok: true });
    }

    const meta = await this.loadMeta();
    if (!meta) return err("chat_not_found", 404);

    switch (path) {
      case "/state": {
        const state = await this.chatState();
        return json({ ok: true, state, users: await this.memberCards(state) });
      }

      case "/fanout-state":
        return json({ ok: true, ...(await this.fanoutState()) });

      case "/history": {
        // userId is whose view this is read as: the log is handed to members only.
        // Otherwise the chat id (in a direct chat it is derived from the two user
        // ids) would be enough to read someone else's conversation as envelopes
        if (!(await this.loadMembers()).has(url.searchParams.get("userId") ?? ""))
          return err("not_member", 403);
        const fromSeq = Number(url.searchParams.get("fromSeq") ?? "0");
        const toSeq = Number(url.searchParams.get("toSeq") ?? String(meta.lastSeq));
        // one page is one storage batch read: 128 keys is the platform limit
        const limit = Math.min(Number(url.searchParams.get("limit") ?? "100"), HISTORY_PAGE);
        const reverse = url.searchParams.get("dir") === "back";
        // userId is whose view this is read as: messages sent to him while he held the
        // sender blocked drop out of the page
        const viewer = url.searchParams.get("userId");
        const listed = await this.state.storage.list<StoredMsg>({
          start: seqKey(fromSeq + 1),
          end: seqKey(toSeq + 1),
          limit,
          reverse,
        });
        const page = [...listed.values()];
        const msgs = viewer ? page.filter((m) => m.blockedFor !== viewer) : page;
        // scanned and lastScannedSeq count what was read, not what is returned, so
        // pagination does not stop on a page the filter emptied
        return json({
          ok: true,
          msgs,
          scanned: page.length,
          lastScannedSeq: page.length ? page[page.length - 1].seq : null,
        });
      }

      case "/events": {
        // tombstones of deleted messages, the current read and delivered marks and the
        // roster, for a client replaying what it missed while offline. The roster is here
        // because the chat frame carrying it is sent to live sockets alone: whoever missed
        // a member leaving would otherwise keep encrypting into a chain that member holds
        const viewer = url.searchParams.get("userId");
        if (!(await this.loadMembers()).has(viewer ?? "")) return err("not_member", 403);
        const deleted: Array<{ seq: number; by: string }> = [];
        for (const [, t] of await this.state.storage.list<Tombstone>({ prefix: TOMB_PREFIX })) {
          if (t.blockedFor === viewer) continue;
          deleted.push({ seq: t.seq, by: t.by });
        }
        const readMarks = await this.markMap("read");
        const deliveredMarks = await this.markMap("dlvr");
        const state = await this.chatState();
        return json({ ok: true, deleted, readMarks, deliveredMarks, state,
                      users: await this.memberCards(state) });
      }

      case "/unread-count": {
        // a compact count for the badge: how many content messages the chat has
        // had since the one the member's mark stands on
        const userId = url.searchParams.get("userId") ?? "";
        // an unaccepted request stays out of the badge: the number alone would tell the
        // recipient how much has been written to him
        const members = await this.loadMembers();
        if (!members.get(userId)?.accepted) return json({ ok: true, unread: 0 });
        const from = Math.max(await this.markOf("read", userId),
                              await this.markOf("seen", userId));
        return json({ ok: true, unread: await this.unreadFrom(from) });
      }

      case "/send": {
        const b = (await req.json()) as {
          from: string; fromDevice: string; clientMsgId: string;
          sentAt: number; body: unknown; service?: boolean; notify?: boolean;
        };
        const members = await this.loadMembers();
        const sender = members.get(b.from);
        if (!sender) return err("not_member", 403);
        // A read-only group holds back content only. Key handouts, receipts of
        // them, repairs, edits and reactions travel service-flagged and keep
        // working for everyone: without them the member could not read the chat.
        if (meta.kind === "group" && !b.service &&
            policy(meta.sendPolicy) === "admins" && sender.role !== "admin")
          return err("not_allowed", 403);

        // Blocks in a direct chat cut two ways. Writing to someone the sender himself
        // blocked is refused outright; a message to someone who blocked the sender
        // enters the journal but is neither delivered nor returned in history.
        const block = await this.blockCheck(b.from);
        if (block?.byMe) return err("blocked", 403);
        const blockedFor = block?.byPeer ? block.peer : null;

        const dupeKey = `cmid:${b.from}/${b.clientMsgId}`;
        const dupe = await this.state.storage.get<{ seq: number; ts: number }>(dupeKey);
        if (dupe) return json({ ok: true, ...dupe, dupe: true });

        const r = await this.journal(meta, b, blockedFor);
        return json({ ok: true, seq: r.seq, ts: r.ts });
      }

      // A scheduled send: the envelope arrives encrypted now and enters the
      // journal at dueAt. The same clientMsgId before the deadline replaces
      // the stored envelope and its deadline (a reschedule or an edit); a
      // clientMsgId the journal already holds answers as the dupe it is.
      case "/defer": {
        const b = (await req.json()) as {
          from: string; fromDevice: string; clientMsgId: string;
          sentAt: number; body: unknown; dueAt: number;
        };
        const members = await this.loadMembers();
        const sender = members.get(b.from);
        if (!sender) return err("not_member", 403);
        if (meta.kind === "group" &&
            policy(meta.sendPolicy) === "admins" && sender.role !== "admin")
          return err("not_allowed", 403);
        const block = await this.blockCheck(b.from);
        if (block?.byMe) return err("blocked", 403);

        const dupe = await this.state.storage.get<{ seq: number; ts: number }>(
          `cmid:${b.from}/${b.clientMsgId}`);
        if (dupe) return json({ ok: true, ...dupe, dupe: true });

        await this.state.storage.put(DEFER_PREFIX + b.from + "/" + b.clientMsgId, {
          from: b.from, fromDevice: b.fromDevice, clientMsgId: b.clientMsgId,
          sentAt: b.sentAt, body: b.body, dueAt: b.dueAt,
        } satisfies DeferredSend);
        await this.scheduleFanout(b.dueAt - Date.now());
        return json({ ok: true, dueAt: b.dueAt });
      }

      case "/defer-cancel": {
        const b = (await req.json()) as { from: string; clientMsgId: string };
        await this.state.storage.delete(DEFER_PREFIX + b.from + "/" + b.clientMsgId);
        return json({ ok: true });
      }

      case "/recv": {
        const b = (await req.json()) as { userId: string; seqs: number[] };
        const members = await this.loadMembers();
        // until the request is accepted the recipient is invisible to whoever sent it,
        // so no delivered receipt goes out
        if (!members.get(b.userId)?.accepted) return json({ ok: true });
        // under a block the mark is not even stored: it would show up in the chat frame
        if (await this.blockedEitherWay(b.userId)) return json({ ok: true });
        const current = await this.markOf("dlvr", b.userId);
        const upTo = Math.max(current, ...b.seqs);
        if (upTo > current) {
          await this.state.storage.put(this.markKey("dlvr", b.userId), upTo);
          // the mark above is the reader's own cursor and always moves; whether the
          // peer learns about it is the readReceipts setting, reciprocal on both sides
          if ((await readPrivacy(this.env.DB, b.userId)).readReceipts) {
            const skip = await this.membersWithFlagOff([...members.keys()], "readReceipts");
            await this.fanout(
              { t: "receipt", chatId: meta.chatId, kind: "delivered", upToSeq: upTo, by: b.userId },
              { except: b.userId, skip }
            );
          }
        }
        return json({ ok: true });
      }

      case "/accept": {
        const b = (await req.json()) as { userId: string };
        const members = await this.loadMembers();
        const m = members.get(b.userId);
        if (!m) return err("not_member", 403);
        if (!m.accepted) {
          m.accepted = true;
          await this.state.storage.put("member:" + b.userId, m);
          await this.broadcastChat("members");
        }
        return json({ ok: true });
      }

      case "/read": {
        const b = (await req.json()) as { userId: string; upToSeq: number };
        const members = await this.loadMembers();
        // read receipts wait for the message request to be accepted
        if (!members.get(b.userId)?.accepted) return json({ ok: true });
        if (await this.blockedEitherWay(b.userId)) return json({ ok: true });
        const current = await this.markOf("read", b.userId);
        if (b.upToSeq > current) {
          const seen = await this.markOf("seen", b.userId);
          await this.state.storage.put({
            [this.markKey("read", b.userId)]: b.upToSeq,
            [this.markKey("seen", b.userId)]: Math.max(seen, b.upToSeq),
          });
          // the marks above are the reader's own cursor and always move; whether the
          // peer sees the receipt is the readReceipts setting, reciprocal on both sides
          if ((await readPrivacy(this.env.DB, b.userId)).readReceipts) {
            const skip = await this.membersWithFlagOff([...members.keys()], "readReceipts");
            await this.fanout(
              { t: "receipt", chatId: meta.chatId, kind: "read", upToSeq: b.upToSeq, by: b.userId },
              { except: b.userId, skip }
            );
          }
        }
        return json({ ok: true });
      }

      case "/typing": {
        const b = (await req.json()) as { userId: string; kind: string | null };
        const members = await this.loadMembers();
        if (!members.has(b.userId)) return err("not_member", 403);
        // until acceptance the recipient is invisible to whoever sent the request
        if (!members.get(b.userId)!.accepted) return json({ ok: true });
        if (await this.blockedEitherWay(b.userId)) return json({ ok: true });
        // the typing setting is reciprocal: off means neither sending nor receiving it
        if (!(await readPrivacy(this.env.DB, b.userId)).typing) return json({ ok: true });
        const typingOff = await this.membersWithFlagOff([...members.keys()], "typing");
        await this.fanout(
          { t: "typing", chatId: meta.chatId, from: b.userId, kind: b.kind },
          { except: b.userId, skip: [...await this.blockedPeers(b.userId), ...typingOff] }
        );
        return json({ ok: true });
      }

      case "/call-relay": {
        // an ephemeral envelope for a call's ICE candidates: fanned out to
        // live sockets and forgotten — no seq, no journal row, no push
        const b = (await req.json()) as {
          userId: string; deviceId: string; sentAt: number; body: unknown;
        };
        const members = await this.loadMembers();
        if (!members.has(b.userId)) return err("not_member", 403);
        if (await this.blockedEitherWay(b.userId)) return json({ ok: true });
        await this.fanout(
          { t: "callRelay", chatId: meta.chatId, from: b.userId,
            fromDevice: b.deviceId, sentAt: b.sentAt, body: b.body },
          { except: b.userId, skip: await this.blockedPeers(b.userId) }
        );
        return json({ ok: true });
      }

      case "/delete": {
        const b = (await req.json()) as { userId: string; seqs: number[]; forAll: boolean };
        if (b.forAll) {
          const members = await this.loadMembers();
          const actor = members.get(b.userId);
          if (!actor) return err("not_member", 403);
          // tombstone the ciphertext: a seq is the storage key, one read each
          const updates: Record<string, StoredMsg> = {};
          const marks: Record<string, Tombstone> = {};
          const tombstoned: number[] = [];
          for (const seq of b.seqs) {
            const m = await this.state.storage.get<StoredMsg>(seqKey(seq));
            if (!m) continue;
            // only a group admin can remove someone else's message
            if (m.from !== b.userId && actor.role !== "admin") continue;
            updates[seqKey(seq)] = { ...m, body: null, deleted: true, deletedBy: b.userId };
            marks[tombKey(seq)] = {
              seq, by: b.userId,
              ...(m.blockedFor ? { blockedFor: m.blockedFor } : {}),
            };
            tombstoned.push(seq);
          }
          if (tombstoned.length) {
            await this.state.storage.put(updates);
            await this.state.storage.put(marks);
            // fan out only what was really removed: otherwise members would lose
            // messages locally that are still on the server
            await this.fanout({
              t: "deleted", chatId: meta.chatId, seqs: tombstoned, forAll: true, by: b.userId,
            });
          }
        }
        return json({ ok: true });
      }

      case "/members": {
        const b = (await req.json()) as {
          actor: string; add: string[]; remove: string[]; viaInvite?: boolean;
        };
        const members = await this.loadMembers();
        const actor = members.get(b.actor);
        // viaInvite: a non-member joins through an invite link, adding only themselves
        const selfJoin =
          b.viaInvite === true && !actor &&
          b.add.length === 1 && b.add[0] === b.actor && b.remove.length === 0;
        if (!actor && !selfJoin) return err("not_member", 403);
        if (meta.kind !== "group") return err("not_group", 400);
        if (actor) {
          // only an admin can remove a member
          if (b.remove.length && actor.role !== "admin") return err("not_admin", 403);
          // an admin adds anyone; a member adds others while invitePolicy
          // allows it, and themselves in any case
          if (b.add.length && actor.role !== "admin") {
            const onlySelf = b.add.length === 1 && b.add[0] === b.actor;
            if (!onlySelf && policy(meta.invitePolicy) === "admins")
              return err("not_allowed", 403);
          }
        }
        const now = nowSec();
        const added: string[] = [];
        for (const uid of b.add) {
          if (members.has(uid)) continue;
          const m: ChatMember = { userId: uid, role: "member", joinedAt: now, accepted: true };
          members.set(uid, m);
          await this.state.storage.put("member:" + uid, m);
          added.push(uid);
        }
        for (const uid of b.remove) {
          if (!members.has(uid)) continue;
          members.delete(uid);
          await this.state.storage.delete("member:" + uid);
        }
        this.members = members;
        if (b.add.length) await this.notifyUserDOsChatList(b.add);
        // someone who was actually added, and did not add themselves, gets a
        // push about it; the group's title is stored here in the clear
        const invited = added.filter((uid) => uid !== b.actor);
        if (invited.length) {
          const body = meta.title
            ? `Вас добавили в «${meta.title}»`
            : "Вас добавили в группу";
          await Promise.allSettled(invited.map((uid) =>
            this.userStub(uid).fetch("https://do/notify-plain", {
              method: "POST",
              body: JSON.stringify({ chatId: meta.chatId, title: "Msngr", body, userId: uid }),
            })));
        }
        if (b.remove.length) await this.notifyUserDOsChatList(b.remove, true);
        await this.broadcastChat("members");
        if (b.remove.length) {
          // the removed member is told the final state too, so their client drops the chat
          const state = await this.chatState();
          await this.enqueueFanout(
            { t: "chat", chatId: meta.chatId, event: "members", state },
            b.remove
          );
        }
        return json({ ok: true });
      }

      case "/leave": {
        const b = (await req.json()) as { userId: string };
        const members = await this.loadMembers();
        if (!members.delete(b.userId)) return err("not_member", 403);
        await this.state.storage.delete("member:" + b.userId);
        await this.notifyUserDOsChatList([b.userId], true);
        await this.broadcastChat("members");
        return json({ ok: true });
      }

      case "/settings": {
        const b = (await req.json()) as {
          actor: string; title?: string; avatarId?: string; description?: string;
          sendPolicy?: ChatPolicy; invitePolicy?: ChatPolicy;
        };
        const members = await this.loadMembers();
        const actor = members.get(b.actor);
        if (!actor) return err("not_member", 403);
        if (meta.kind === "group" && actor.role !== "admin") return err("not_admin", 403);
        if (b.title !== undefined) meta.title = b.title;
        if (b.avatarId !== undefined) meta.avatarId = b.avatarId;
        if (b.description !== undefined) meta.description = b.description;
        // rights belong to a group; a direct chat has two equal sides
        if (meta.kind === "group") {
          if (b.sendPolicy !== undefined) meta.sendPolicy = policy(b.sendPolicy);
          if (b.invitePolicy !== undefined) meta.invitePolicy = policy(b.invitePolicy);
        }
        this.meta = meta;
        await this.state.storage.put("meta", meta);
        await this.broadcastChat("settings");
        return json({ ok: true });
      }

      case "/admins": {
        const b = (await req.json()) as { actor: string; userId: string; admin: boolean };
        const members = await this.loadMembers();
        const actor = members.get(b.actor);
        const target = members.get(b.userId);
        if (!actor || actor.role !== "admin") return err("not_admin", 403);
        if (!target) return err("not_member", 400);
        target.role = b.admin ? "admin" : "member";
        await this.state.storage.put("member:" + b.userId, target);
        await this.broadcastChat("members");
        return json({ ok: true });
      }

      case "/pin-message": {
        const b = (await req.json()) as { actor: string; seq?: number | null; pinned?: boolean };
        const members = await this.loadMembers();
        if (!members.has(b.actor)) return err("not_member", 403);
        const pins = meta.pinnedSeqs ?? [];
        if (b.seq == null) {
          // an absent seq clears the whole set: JSON encoders drop null fields
          meta.pinnedSeqs = [];
        } else if (b.pinned === false) {
          meta.pinnedSeqs = pins.filter((s) => s !== b.seq);
        } else {
          // re-pinning moves the seq to the end: the newest pin leads the bar
          meta.pinnedSeqs = [...pins.filter((s) => s !== b.seq), b.seq];
        }
        this.meta = meta;
        await this.state.storage.put("meta", meta);
        await this.broadcastChat("pinned");
        return json({ ok: true });
      }

      case "/profile": {
        // from UserDO: a member's card changed. Unlike presence this is
        // public, so an unaccepted request sees it too — the request screen
        // already shows the sender's name and avatar.
        const b = (await req.json()) as { userId: string; user: PublicUser };
        const members = await this.loadMembers();
        if (!members.has(b.userId)) return json({ ok: true });
        await this.fanout(
          { t: "profile", user: b.user },
          { except: b.userId, skip: await this.blockedPeers(b.userId) }
        );
        return json({ ok: true });
      }

      case "/devices": {
        // from UserDO: a member's device set changed. Anyone who may
        // address an envelope to them holds a device cache to drop, so the
        // frame travels like the profile — an unaccepted request included.
        const b = (await req.json()) as { userId: string; version: number };
        const members = await this.loadMembers();
        if (!members.has(b.userId)) return json({ ok: true });
        await this.fanout(
          { t: "devices", userId: b.userId, version: b.version },
          { except: b.userId, skip: await this.blockedPeers(b.userId) }
        );
        return json({ ok: true });
      }

      case "/presence": {
        // from UserDO: a user's online status changed, so tell the members
        const b = (await req.json()) as { userId: string; online: boolean; lastSeen: number };
        const members = await this.loadMembers();
        // the presence of a recipient who has not accepted stays hidden from the requester
        if (!members.get(b.userId)?.accepted) return json({ ok: true });
        if (await this.blockedEitherWay(b.userId)) return json({ ok: true });
        // whether each member may see this presence is the owner's tier and
        // their named exceptions; a member who hid their own last seen is
        // blinded to everyone else's the same as a blocked one
        const ownTier = (await readPrivacy(this.env.DB, b.userId)).lastSeen;
        const hidden = await Promise.all(
          [...members.keys()].map(async (u) => {
            if (u === b.userId) return { u, hidden: false };
            if ((await readPrivacy(this.env.DB, u)).lastSeen === "nobody") return { u, hidden: true };
            return { u, hidden: !(await privacyAllows(this.env, b.userId, u, "last_seen", ownTier)) };
          })
        );
        const skip = [...await this.blockedPeers(b.userId), ...hidden.filter((h) => h.hidden).map((h) => h.u)];
        await this.fanout(
          { t: "presence", userId: b.userId, online: b.online, lastSeen: b.lastSeen },
          { except: b.userId, skip }
        );
        return json({ ok: true });
      }

      default:
        return err("unknown_path", 404);
    }
  }
}
