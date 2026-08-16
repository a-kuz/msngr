import type { Env, ChatState, ChatMember, StoredMsg, ServerFrame } from "../types";
import { ulid, json, err, seqKey, nowSec, shouldArmAlarm } from "../util";

/// Fanout queue. A frame is never delivered on the sender's critical path: it
/// is appended as a job and drained by the alarm loop, so /send answers as soon
/// as the message owns a seq. Jobs are FIFO, which keeps frame order per chat.
///
/// Every job carries its own delivery cursor over the target list and the
/// cursor is written after each batch, so a drain cut short (eviction, crash,
/// alarm retry) resumes from the last persisted position and redelivers at most
/// one batch. Redelivery is safe: clients dedupe messages by msgId, read and
/// delivered marks are monotonic, chat/presence frames are snapshots.
const FANOUT_PREFIX = "fq:";
/// Deliveries issued in parallel per storage write of the cursor.
const FANOUT_BATCH = 32;
/// Subrequests one alarm invocation is allowed to spend before rescheduling
/// itself; the platform ceiling is 1000 per invocation and the next alarm gets
/// a fresh budget, so audience size is not capped by it.
const FANOUT_BUDGET = 800;
/// Delivery passes over a job, including the first one.
const FANOUT_MAX_ATTEMPTS = 3;
/// Backoff before the 2nd and 3rd pass over the recipients that failed.
const FANOUT_RETRY_MS = [200, 1000];
/// A recipient that stops answering must not hold the queue of its chat: the
/// delivery is given up on and retried like any other failure.
const FANOUT_DELIVERY_TIMEOUT_MS = 10_000;
/// A job that waits longer than this before its first delivery pass is reported.
/// Retries and a long burst stay well under it, so a line in the log means the
/// queue was standing still — the one failure a client on a live socket cannot
/// see for itself.
const FANOUT_STALL_MS = 15_000;

/// Journal records one /history page returns. Durable Objects read at most 128
/// keys per batch, so a larger page would be served by several reads anyway.
const HISTORY_PAGE = 128;

interface FanoutJob {
  frame: ServerFrame;
  targets: string[];
  /// when the job entered the queue (ms since epoch)
  queuedAt: number;
  /// how many targets of this pass are already delivered
  pos: number;
  /// 0 for the first pass
  attempt: number;
  /// targets of the current pass that failed
  failed: string[];
  /// backoff deadline before a retry pass (ms since epoch)
  after?: number;
}

function fanoutKey(id: number): string {
  return FANOUT_PREFIX + String(id).padStart(16, "0");
}

/// Retrying typing makes no sense: it is superseded by the next typing frame
/// and stops mattering within seconds. Everything else is worth another pass.
function fanoutRetryable(frame: ServerFrame): boolean {
  return frame.t !== "typing";
}

interface Meta {
  chatId: string;
  kind: "direct" | "group";
  title: string | null;
  avatarId: string | null;
  description: string | null;
  createdBy: string;
  createdAt: number;
  pinnedMsgId: string | null;
  lastSeq: number;
}

export class ConversationDO implements DurableObject {
  private meta: Meta | null = null;
  private members: Map<string, ChatMember> | null = null;
  /// True while alarm() walks the fanout queue.
  private draining = false;
  /// A job was queued while the drain was running and has to be picked up by it.
  private queuedWhileDraining = false;
  /// Which side of a direct pair has blocked the other, as the set of blockers. The
  /// truth lives in the blocks table in D1; this is read lazily and dropped on
  /// /block-changed.
  private blockers: Set<string> | null = null;

  constructor(private state: DurableObjectState, private env: Env) {}

  private async loadMeta(): Promise<Meta | null> {
    if (!this.meta) this.meta = (await this.state.storage.get<Meta>("meta")) ?? null;
    return this.meta;
  }

  private async loadMembers(): Promise<Map<string, ChatMember>> {
    if (!this.members) {
      const listed = await this.state.storage.list<ChatMember>({ prefix: "member:" });
      this.members = new Map();
      for (const [, m] of listed) this.members.set(m.userId, m);
    }
    return this.members;
  }

  private userStub(userId: string) {
    return this.env.USER_DO.get(this.env.USER_DO.idFromName(userId));
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
    const job: FanoutJob = {
      frame, targets, pos: 0, attempt: 0, failed: [], queuedAt: Date.now(),
    };
    await this.state.storage.put({ [fanoutKey(id)]: job, fqNext: id + 1 });
    await this.scheduleFanout(0);
  }

  /// Arms the drain. A job queued while `alarm()` is draining is handed to that
  /// loop instead of to a new alarm: an alarm written for a moment the running
  /// handler has already reached is dropped by the runtime, and the queue would
  /// then hold jobs nobody comes back for.
  private async scheduleFanout(delayMs: number) {
    if (delayMs === 0 && this.draining) {
      this.queuedWhileDraining = true;
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

  /// Walks the job's targets from its cursor. Returns how many deliveries were
  /// spent and, when the job stays queued for another pass, how long to wait.
  private async runFanoutJob(
    key: string,
    job: FanoutJob,
    budget: number
  ): Promise<{ spent: number; retryMs?: number }> {
    const chatId = this.meta?.chatId ?? "";
    // dev: artificial network latency before delivering a job (DEV_WS_LATENCY_MS)
    const latency = Number(this.env.DEV_WS_LATENCY_MS ?? 0);
    if (latency > 0 && job.pos === 0) await new Promise((r) => setTimeout(r, latency));

    const body = JSON.stringify(job.frame);
    let spent = 0;
    while (job.pos < job.targets.length && spent < budget) {
      const batch = job.targets.slice(job.pos, job.pos + FANOUT_BATCH);
      // one failing recipient must not stop the batch or the ones behind it
      const results = await Promise.allSettled(batch.map((u) => this.deliver(u, body)));
      results.forEach((r, i) => {
        if (r.status !== "rejected") return;
        job.failed.push(batch[i]);
        console.warn(
          `fanout: ${job.frame.t} to ${batch[i]} in ${chatId} failed ` +
            `(attempt ${job.attempt + 1}): ${r.reason}`
        );
      });
      job.pos += batch.length;
      spent += batch.length;
      await this.state.storage.put(key, job);
    }
    // budget spent mid-job: the cursor is stored, the next alarm continues
    if (job.pos < job.targets.length) return { spent };

    if (job.failed.length) {
      const attempt = job.attempt + 1;
      if (fanoutRetryable(job.frame) && attempt < FANOUT_MAX_ATTEMPTS) {
        const retryMs = FANOUT_RETRY_MS[Math.min(attempt - 1, FANOUT_RETRY_MS.length - 1)];
        const retry: FanoutJob = {
          frame: job.frame, targets: job.failed, pos: 0, attempt, failed: [],
          queuedAt: job.queuedAt, after: Date.now() + retryMs,
        };
        await this.state.storage.put(key, retry);
        return { spent, retryMs };
      }
      console.error(
        `fanout: dropping ${job.frame.t} in ${chatId} for ${job.failed.join(", ")} ` +
          `after ${attempt} attempt(s)`
      );
    }
    await this.state.storage.delete(key);
    return { spent };
  }

  /// Drains the fanout queue. Kept head-of-line so that frames reach a
  /// recipient in the order the chat produced them.
  async alarm() {
    // marked before the first await: from the moment the runtime consumed the
    // alarm, this drain is what the queue is waiting for
    this.draining = true;
    let budget = FANOUT_BUDGET;
    // delay of the alarm this drain leaves behind, armed once draining is over
    let next: number | undefined;
    try {
      await this.loadMeta();
      for (;;) {
        const listed = await this.state.storage.list<FanoutJob>({
          prefix: FANOUT_PREFIX,
          limit: 1,
        });
        const head = [...listed.entries()][0];
        if (!head) {
          // a job queued during this drain arrived after the listing above:
          // walk the queue once more instead of ending on a stale empty read
          if (this.queuedWhileDraining) {
            this.queuedWhileDraining = false;
            continue;
          }
          return;
        }
        if (budget <= 0) {
          next = 0;
          return;
        }
        const [key, job] = head;
        // a job waiting out its backoff also holds back the ones behind it:
        // recipients must see frames in the order the chat produced them
        const wait = (job.after ?? 0) - Date.now();
        if (wait > 0) {
          next = wait;
          return;
        }
        // the queue standing still is invisible to a client whose socket is
        // healthy, so the delay it caused is said out loud here
        const waited = Date.now() - job.queuedAt;
        if (job.attempt === 0 && job.pos === 0 && waited > FANOUT_STALL_MS) {
          console.error(
            `fanout: ${job.frame.t} in ${this.meta?.chatId} waited ${waited}ms before delivery`
          );
        }
        const { spent, retryMs } = await this.runFanoutJob(key, job, budget);
        budget -= spent;
        if (retryMs !== undefined) {
          next = retryMs;
          return;
        }
      }
    } finally {
      this.draining = false;
      if (this.queuedWhileDraining) {
        this.queuedWhileDraining = false;
        next ??= 0;
      }
      if (next !== undefined) await this.scheduleFanout(next);
    }
  }

  /// Queue depth (counted up to a page), the head job's cursor, how long that
  /// job has been waiting and whether a drain is actually coming for it.
  ///
  /// `armed` is false for a moment between the runtime taking the alarm and
  /// the handler starting, so a queue that stands still is recognised by
  /// `oldestMs` growing instead: nothing being sent to a chat whose sockets are
  /// all healthy is the one failure a member cannot tell from an idle chat.
  private async fanoutState() {
    const listed = await this.state.storage.list<FanoutJob>({
      prefix: FANOUT_PREFIX,
      limit: 128,
    });
    const head = [...listed.values()][0];
    const now = Date.now();
    const pending = await this.state.storage.getAlarm();
    const armed = this.draining || (pending !== null && pending > now);
    const oldestMs = head ? now - head.queuedAt : null;
    if (!armed && oldestMs !== null && oldestMs > FANOUT_STALL_MS) {
      console.error(
        `fanout: ${listed.size} job(s) in ${this.meta?.chatId} waiting ${oldestMs}ms ` +
          `with no drain armed`
      );
    }
    return {
      pending: listed.size,
      cursor: head ? head.pos : 0,
      targets: head ? head.targets.length : 0,
      attempt: head ? head.attempt : 0,
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
    const readMarks =
      (await this.state.storage.get<Record<string, number>>("readMarks")) ?? {};
    const deliveredMarks =
      (await this.state.storage.get<Record<string, number>>("deliveredMarks")) ?? {};
    return {
      chatId: meta.chatId,
      kind: meta.kind,
      title: meta.title,
      avatarId: meta.avatarId,
      description: meta.description,
      createdBy: meta.createdBy,
      createdAt: meta.createdAt,
      members: [...members.values()],
      pinnedMsgId: meta.pinnedMsgId,
      lastSeq: meta.lastSeq,
      readMarks,
      deliveredMarks,
    };
  }

  private async broadcastChat(event: string) {
    const state = await this.chatState();
    await this.fanout({ t: "chat", chatId: state.chatId, event, state });
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
    const url = new URL(req.url);
    const path = url.pathname;

    if (path === "/create" && req.method === "POST") {
      const b = (await req.json()) as {
        chatId: string; kind: "direct" | "group"; title: string | null;
        memberIds: string[]; createdBy: string;
      };
      const existing = await this.loadMeta();
      if (existing) return json({ ok: true, chatId: existing.chatId, existed: true });
      const now = nowSec();
      this.meta = {
        chatId: b.chatId, kind: b.kind, title: b.title ?? null,
        avatarId: null, description: null, createdBy: b.createdBy,
        createdAt: now, pinnedMsgId: null, lastSeq: 0,
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
      case "/state":
        return json({ ok: true, state: await this.chatState() });

      case "/fanout-state":
        return json({ ok: true, ...(await this.fanoutState()) });

      case "/history": {
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
        // tombstones of deleted messages plus the current read and delivered marks,
        // for a client replaying what it missed while offline
        const viewer = url.searchParams.get("userId");
        const deleted: Array<{ msgId: string; by: string }> = [];
        for (const [, m] of await this.state.storage.list<StoredMsg>({ prefix: "msg:" })) {
          if (!m.deleted || m.blockedFor === viewer) continue;
          deleted.push({ msgId: m.msgId, by: m.deletedBy ?? m.from });
        }
        const readMarks =
          (await this.state.storage.get<Record<string, number>>("readMarks")) ?? {};
        const deliveredMarks =
          (await this.state.storage.get<Record<string, number>>("deliveredMarks")) ?? {};
        return json({ ok: true, deleted, readMarks, deliveredMarks });
      }

      case "/unread-count": {
        const userId = url.searchParams.get("userId") ?? "";
        // an unaccepted request stays out of the badge: the number alone would tell the
        // recipient how much has been written to him
        const members = await this.loadMembers();
        if (!members.get(userId)?.accepted) return json({ ok: true, unread: 0 });
        const marks =
          (await this.state.storage.get<Record<string, number>>("readMarks")) ?? {};
        return json({ ok: true, unread: Math.max(0, meta.lastSeq - (marks[userId] ?? 0)) });
      }

      case "/send": {
        const b = (await req.json()) as {
          from: string; fromDevice: string; clientMsgId: string;
          sentAt: number; body: unknown; service?: boolean;
        };
        const members = await this.loadMembers();
        if (!members.has(b.from)) return err("not_member", 403);

        // Blocks in a direct chat cut two ways. Writing to someone the sender himself
        // blocked is refused outright; a message to someone who blocked the sender
        // enters the journal but is neither delivered nor returned in history.
        const block = await this.blockCheck(b.from);
        if (block?.byMe) return err("blocked", 403);
        const blockedFor = block?.byPeer ? block.peer : null;

        const dupeKey = `cmid:${b.from}/${b.clientMsgId}`;
        const dupe = await this.state.storage.get<{ msgId: string; seq: number; ts: number }>(dupeKey);
        if (dupe) return json({ ok: true, ...dupe, dupe: true });

        const seq = meta.lastSeq + 1;
        const msg: StoredMsg = {
          msgId: ulid(), seq, from: b.from, fromDevice: b.fromDevice,
          clientMsgId: b.clientMsgId, sentAt: b.sentAt, ts: nowSec(), body: b.body,
          ...(b.service ? { service: true } : {}),
          ...(blockedFor ? { blockedFor } : {}),
        };
        meta.lastSeq = seq;
        this.meta = meta;
        await this.state.storage.put({
          meta,
          [seqKey(seq)]: msg,
          [dupeKey]: { msgId: msg.msgId, seq, ts: msg.ts },
        });

        const frame: ServerFrame = {
          t: "msg", chatId: meta.chatId, seq, msgId: msg.msgId,
          from: msg.from, fromDevice: msg.fromDevice,
          sentAt: msg.sentAt, ts: msg.ts, body: msg.body,
          ...(msg.service ? { service: true } : {}),
        };
        // Under a block the send still succeeds and the sender sees "sent", but nothing
        // reaches the other side, over the socket or by push. The blocker's read mark
        // moves at once, or his unread would grow on messages he will never see.
        const blocked = await this.blockedPeers(b.from);
        if (blocked.length) {
          const marks =
            (await this.state.storage.get<Record<string, number>>("readMarks")) ?? {};
          for (const u of blocked) marks[u] = Math.max(marks[u] ?? 0, seq);
          await this.state.storage.put("readMarks", marks);
        }
        // ack answers the sender as soon as the message owns a seq; delivery
        // (and the APNs call behind it) runs in the alarm queue afterwards.
        // Author's own devices are targets too: the echo goes through his UserDO.
        await this.fanout(frame, { skip: blocked });
        return json({ ok: true, msgId: msg.msgId, seq, ts: msg.ts });
      }

      case "/recv": {
        const b = (await req.json()) as { userId: string; seqs: number[] };
        const members = await this.loadMembers();
        // until the request is accepted the recipient is invisible to whoever sent it,
        // so no delivered receipt goes out
        if (!members.get(b.userId)?.accepted) return json({ ok: true });
        // under a block the mark is not even stored: it would show up in the chat frame
        if (await this.blockedEitherWay(b.userId)) return json({ ok: true });
        const marks =
          (await this.state.storage.get<Record<string, number>>("deliveredMarks")) ?? {};
        const upTo = Math.max(marks[b.userId] ?? 0, ...b.seqs);
        if (upTo > (marks[b.userId] ?? 0)) {
          marks[b.userId] = upTo;
          await this.state.storage.put("deliveredMarks", marks);
          await this.fanout(
            { t: "receipt", chatId: meta.chatId, kind: "delivered", upToSeq: upTo, by: b.userId },
            { except: b.userId }
          );
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
        const marks =
          (await this.state.storage.get<Record<string, number>>("readMarks")) ?? {};
        if (b.upToSeq > (marks[b.userId] ?? 0)) {
          marks[b.userId] = b.upToSeq;
          await this.state.storage.put("readMarks", marks);
          await this.fanout(
            { t: "receipt", chatId: meta.chatId, kind: "read", upToSeq: b.upToSeq, by: b.userId },
            { except: b.userId }
          );
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
        await this.fanout(
          { t: "typing", chatId: meta.chatId, from: b.userId, kind: b.kind },
          { except: b.userId, skip: await this.blockedPeers(b.userId) }
        );
        return json({ ok: true });
      }

      case "/delete": {
        const b = (await req.json()) as { userId: string; msgIds: string[]; forAll: boolean };
        if (b.forAll) {
          const members = await this.loadMembers();
          const actor = members.get(b.userId);
          if (!actor) return err("not_member", 403);
          // тумбстоуним ciphertext: найти по msgId (скан последних; msgId→seq индекс)
          const idx =
            (await this.state.storage.get<Record<string, number>>("msgIdx")) ?? {};
          const updates: Record<string, StoredMsg> = {};
          const tombstoned: string[] = [];
          for (const [key, m] of await this.state.storage.list<StoredMsg>({ prefix: "msg:" })) {
            if (b.msgIds.includes(m.msgId)) {
              // чужое сообщение сносит только админ группы
              if (m.from !== b.userId && actor.role !== "admin") continue;
              updates[key] = { ...m, body: null, deleted: true, deletedBy: b.userId };
              tombstoned.push(m.msgId);
            }
          }
          void idx;
          if (tombstoned.length) {
            await this.state.storage.put(updates);
            // рассылаем только то, что действительно снесено: иначе участники
            // потеряли бы у себя сообщения, оставшиеся на сервере
            await this.fanout({
              t: "deleted", chatId: meta.chatId, msgIds: tombstoned, forAll: true, by: b.userId,
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
        // viaInvite: не-участник вступает сам по invite-ссылке (только add самого себя)
        const selfJoin =
          b.viaInvite === true && !actor &&
          b.add.length === 1 && b.add[0] === b.actor && b.remove.length === 0;
        if (!actor && !selfJoin) return err("not_member", 403);
        if (meta.kind !== "group") return err("not_group", 400);
        if (actor) {
          // удалять может только админ
          if (b.remove.length && actor.role !== "admin") return err("not_admin", 403);
          // добавлять может админ; не-админ — только самого себя
          if (b.add.length && actor.role !== "admin") {
            const onlySelf = b.add.length === 1 && b.add[0] === b.actor;
            if (!onlySelf) return err("not_admin", 403);
          }
        }
        const now = nowSec();
        for (const uid of b.add) {
          if (members.has(uid)) continue;
          const m: ChatMember = { userId: uid, role: "member", joinedAt: now, accepted: true };
          members.set(uid, m);
          await this.state.storage.put("member:" + uid, m);
        }
        for (const uid of b.remove) {
          if (!members.has(uid)) continue;
          members.delete(uid);
          await this.state.storage.delete("member:" + uid);
        }
        this.members = members;
        if (b.add.length) await this.notifyUserDOsChatList(b.add);
        if (b.remove.length) await this.notifyUserDOsChatList(b.remove, true);
        await this.broadcastChat("members");
        if (b.remove.length) {
          // удалённым тоже сообщаем финальное состояние, чтобы клиент убрал чат
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
        };
        const members = await this.loadMembers();
        const actor = members.get(b.actor);
        if (!actor) return err("not_member", 403);
        if (meta.kind === "group" && actor.role !== "admin") return err("not_admin", 403);
        if (b.title !== undefined) meta.title = b.title;
        if (b.avatarId !== undefined) meta.avatarId = b.avatarId;
        if (b.description !== undefined) meta.description = b.description;
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
        const b = (await req.json()) as { actor: string; msgId: string | null };
        const members = await this.loadMembers();
        if (!members.has(b.actor)) return err("not_member", 403);
        meta.pinnedMsgId = b.msgId;
        this.meta = meta;
        await this.state.storage.put("meta", meta);
        await this.broadcastChat("pinned");
        return json({ ok: true });
      }

      case "/presence": {
        // от UserSessionDO: пользователь сменил online-статус → разослать участникам
        const b = (await req.json()) as { userId: string; online: boolean; lastSeen: number };
        const members = await this.loadMembers();
        // presence не-принявшего получателя не видна автору заявки
        if (!members.get(b.userId)?.accepted) return json({ ok: true });
        if (await this.blockedEitherWay(b.userId)) return json({ ok: true });
        await this.fanout(
          { t: "presence", userId: b.userId, online: b.online, lastSeen: b.lastSeen },
          { except: b.userId, skip: await this.blockedPeers(b.userId) }
        );
        return json({ ok: true });
      }

      default:
        return err("unknown_path", 404);
    }
  }
}
