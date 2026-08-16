import type { Env, ClientFrame, ServerFrame } from "../types";
import { json, err, nowSec } from "../util";
import { sendPush, envelopeForDevice } from "../push/apns";
import { PROTOCOL_VERSION, MIN_CLIENT_PROTOCOL } from "../version";

/// Presence TTL: the client pings every ~12s, so silence longer than this reads as offline.
const PRESENCE_TTL_MS = 35_000;
const PRESENCE_TTL = PRESENCE_TTL_MS / 1000;

/// Journal records one chat is read for in a single catch-up portion. Equals
/// the Durable Objects batch read limit: one storage page, one subrequest.
const SYNC_PAGE = 128;
/// Records a whole portion reads across every chat it touches, so a long chat
/// list cannot turn one portion into a pass over the user's whole history.
const SYNC_BUDGET = 128;
/// Chats a portion touches, whatever their backlog: the object returns to the
/// event loop after this many, and the client asks for the rest.
const SYNC_CHATS = 32;

interface ChatFlags {
  pinned: boolean;
  muted: boolean;
  /// when the mute lifts, in seconds; unset means it never does on its own
  mutedUntil?: number;
  archived: boolean;
  joinedAt: number;
}

/// A mute with a deadline counts as lifted once that deadline has passed.
function muteActive(flags: ChatFlags | undefined, now: number): boolean {
  if (!flags?.muted) return false;
  return !flags.mutedUntil || flags.mutedUntil > now;
}

function muteExpired(flags: ChatFlags | undefined, now: number): boolean {
  return !!flags?.muted && !!flags.mutedUntil && flags.mutedUntil <= now;
}

interface SocketAttachment {
  deviceId: string;
  // time of the last ping, in seconds; a socket without a fresh one counts as hung
  lastPing: number;
}

// One object per user: the sockets of all their devices, the chat list, presence, pushes.
export class UserSessionDO implements DurableObject {
  private userId: string | null = null;
  /// Dev test hook (/dev-fault): how many frame deliveries to reject next.
  private devFailEvents = 0;

  constructor(private state: DurableObjectState, private env: Env) {}

  private async getUserId(): Promise<string | null> {
    if (!this.userId) this.userId = (await this.state.storage.get<string>("userId")) ?? null;
    return this.userId;
  }

  private convStub(chatId: string) {
    return this.env.CONV_DO.get(this.env.CONV_DO.idFromName(chatId));
  }

  private sockets(): WebSocket[] {
    return this.state.getWebSockets();
  }

  private send(ws: WebSocket, frame: ServerFrame) {
    try { ws.send(JSON.stringify(frame)); } catch { /* socket is gone; the hibernation API sweeps it */ }
  }

  private broadcast(frame: ServerFrame) {
    for (const ws of this.sockets()) this.send(ws, frame);
  }

  // whether any socket has a live client behind it, meaning a ping within the TTL;
  // a socket that is open but hung does not count
  private presenceFresh(): boolean {
    const cutoff = nowSec() - PRESENCE_TTL;
    return this.sockets().some((ws) => {
      const att = ws.deserializeAttachment() as SocketAttachment | null;
      return (att?.lastPing ?? 0) > cutoff;
    });
  }

  /// Lifts a mute whose deadline has passed and returns the chat's current flags.
  private async clearExpiredMute(chatId: string): Promise<ChatFlags | undefined> {
    const key = "chat:" + chatId;
    const flags = await this.state.storage.get<ChatFlags>(key);
    if (!muteExpired(flags, nowSec())) return flags;
    flags!.muted = false;
    delete flags!.mutedUntil;
    await this.state.storage.put(key, flags!);
    return flags;
  }

  /// Puts a chat back on the list with default flags when it is not there.
  private async relistChat(chatId: string) {
    const key = "chat:" + chatId;
    if (await this.state.storage.get<ChatFlags>(key)) return;
    await this.state.storage.put(key, {
      pinned: false, muted: false, archived: false, joinedAt: nowSec(),
    } satisfies ChatFlags);
  }

  private async chatIds(): Promise<string[]> {
    const listed = await this.state.storage.list<ChatFlags>({ prefix: "chat:" });
    return [...listed.keys()].map((k) => k.slice(5));
  }

  private async broadcastPresence(online: boolean) {
    const userId = await this.getUserId();
    if (!userId) return;
    const lastSeen = nowSec();
    await this.state.storage.put("lastSeen", lastSeen);
    const ids = await this.chatIds();
    const results = await Promise.allSettled(
      ids.map(async (chatId) => {
        const res = await this.convStub(chatId).fetch("https://do/presence", {
          method: "POST",
          body: JSON.stringify({ userId, online, lastSeen }),
        });
        if (!res.ok) throw new Error(`status ${res.status}`);
      })
    );
    results.forEach((r, i) => {
      if (r.status === "rejected") {
        console.warn(`presence of ${userId} in ${ids[i]} failed: ${r.reason}`);
      }
    });
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    if (path === "/ws") {
      const userId = req.headers.get("x-user-id")!;
      const deviceId = req.headers.get("x-device-id")!;
      await this.state.storage.put("userId", userId);
      this.userId = userId;

      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.state.acceptWebSocket(server);
      server.serializeAttachment({ deviceId, lastPing: nowSec() } satisfies SocketAttachment);
      // the handshake names both bounds: what this server speaks and how far
      // down it still serves
      this.send(server, {
        t: "hello", serverTime: nowSec(),
        protocol: PROTOCOL_VERSION, minProtocol: MIN_CLIENT_PROTOCOL,
      });

      await this.state.storage.setAlarm(Date.now() + PRESENCE_TTL_MS);
      if (this.sockets().length === 1) {
        await this.broadcastPresence(true);
      }
      return new Response(null, { status: 101, webSocket: client });
    }

    switch (path) {
      case "/event": {
        if (this.devFailEvents > 0) {
          this.devFailEvents--;
          return err("dev_fault", 500);
        }
        const frame = (await req.json()) as ServerFrame;
        for (const ws of this.sockets()) this.send(ws, frame);
        if (frame.t === "msg" && !frame.service) {
          // a chat this user deleted comes back on the next message written to
          // it; a service frame does not bring it back, having nothing to show
          await this.relistChat(frame.chatId);
          // a content message moves the chat's unread, so the cached badge is stale
          await this.invalidateUnread(frame.chatId);
          const flags = await this.clearExpiredMute(frame.chatId);
          const muted = muteActive(flags, nowSec());
          const userId = await this.getUserId();
          const isOwnEcho = userId !== null && frame.from === userId;
          // The call is awaited here rather than deferred: waitUntil gives no
          // timing guarantee. The sender is not waiting on it — his ack left
          // ConversationDO before this delivery was queued.
          if (!muted && !isOwnEcho) {
            await this.pushToDevices(frame);
          }
        }
        return json({ ok: true });
      }

      case "/chat-added": {
        const b = (await req.json()) as { chatId: string };
        const existing = await this.state.storage.get<ChatFlags>("chat:" + b.chatId);
        if (!existing) {
          await this.state.storage.put("chat:" + b.chatId, {
            pinned: false, muted: false, archived: false, joinedAt: nowSec(),
          } satisfies ChatFlags);
        }
        return json({ ok: true });
      }

      case "/chat-removed": {
        const b = (await req.json()) as { chatId: string };
        await this.state.storage.delete("chat:" + b.chatId);
        // the badge sums the listed chats, and a count left in the cache would
        // be counted again the day the chat comes back
        await this.invalidateUnread(b.chatId);
        return json({ ok: true });
      }

      case "/chats": {
        const listed = await this.state.storage.list<ChatFlags>({ prefix: "chat:" });
        const now = nowSec();
        const out: Record<string, ChatFlags> = {};
        for (const [k, v] of listed) {
          const chatId = k.slice(5);
          out[chatId] = muteExpired(v, now)
            ? (await this.clearExpiredMute(chatId)) ?? v
            : v;
        }
        return json({ ok: true, chats: out });
      }

      case "/flags": {
        const b = (await req.json()) as {
          chatId: string; pinned?: boolean; muted?: boolean;
          mutedUntil?: number | null; archived?: boolean;
        };
        const key = "chat:" + b.chatId;
        const flags = await this.state.storage.get<ChatFlags>(key);
        if (!flags) return err("chat_not_found", 404);
        if (b.pinned !== undefined) flags.pinned = b.pinned;
        // a deadline lives only with the mute that set it: muted with no mutedUntil
        // (or a null one) is indefinite, muted:false lifts it
        if (b.muted !== undefined) {
          flags.muted = b.muted;
          delete flags.mutedUntil;
        }
        if (b.mutedUntil != null && flags.muted) flags.mutedUntil = b.mutedUntil;
        if (b.archived !== undefined) flags.archived = b.archived;
        await this.state.storage.put(key, flags);
        return json({ ok: true });
      }

      case "/push-token": {
        const b = (await req.json()) as {
          deviceId: string; apnsToken: string; env: string; userId?: string;
        };
        // /unread-count needs the userId even before the first WS connection
        if (b.userId) {
          await this.state.storage.put("userId", b.userId);
          this.userId = b.userId;
        }
        const tokens =
          (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
        tokens[b.deviceId] = { token: b.apnsToken, env: b.env };
        await this.state.storage.put("apns", tokens);
        return json({ ok: true });
      }

      case "/revoke-device": {
        const b = (await req.json()) as { deviceId: string };
        for (const ws of this.sockets()) {
          const att = ws.deserializeAttachment() as SocketAttachment | null;
          if (att?.deviceId !== b.deviceId) continue;
          try { ws.close(4401, "revoked"); } catch { /* already closed */ }
        }
        const tokens =
          (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
        if (b.deviceId in tokens) {
          delete tokens[b.deviceId];
          await this.state.storage.put("apns", tokens);
        }
        if (this.sockets().length === 0) await this.broadcastPresence(false);
        return json({ ok: true });
      }

      case "/dev-fault": {
        const b = (await req.json()) as { failEvents?: number };
        this.devFailEvents = Math.max(0, Math.floor(b.failEvents ?? 0));
        return json({ ok: true, failEvents: this.devFailEvents });
      }

      case "/presence-info": {
        const lastSeen = (await this.state.storage.get<number>("lastSeen")) ?? 0;
        const online = this.presenceFresh();
        return json({ ok: true, online, lastSeen });
      }

      default:
        return err("unknown_path", 404);
    }
  }

  // --- badge: unread summed over the chats ---
  // Per-chat unread is cached in storage ("unreadCache") and invalidated by an incoming
  // msg or by this user's own read. Recount is lazy, through ConversationDO
  // /unread-count at push time, and only for the chats whose entry was dropped.

  private async invalidateUnread(chatId: string) {
    const cache =
      (await this.state.storage.get<Record<string, number>>("unreadCache")) ?? {};
    if (chatId in cache) {
      delete cache[chatId];
      await this.state.storage.put("unreadCache", cache);
    }
  }

  private async totalUnread(): Promise<number> {
    const userId = await this.getUserId();
    const cache =
      (await this.state.storage.get<Record<string, number>>("unreadCache")) ?? {};
    let changed = false;
    let total = 0;
    for (const chatId of await this.chatIds()) {
      let n = cache[chatId];
      if (n === undefined) {
        try {
          const r = await this.convStub(chatId).fetch(
            `https://do/unread-count?userId=${userId ?? ""}`
          );
          const j = (await r.json()) as { ok: boolean; unread?: number };
          n = j.ok ? j.unread ?? 0 : 0;
        } catch {
          n = 0;
        }
        cache[chatId] = n;
        changed = true;
      }
      total += n;
    }
    if (changed) await this.state.storage.put("unreadCache", cache);
    return total;
  }

  /// Orders the badge numbers this object hands out. The object is the only
  /// writer of the user's unread total and runs single-threaded, so a counter
  /// it bumps per push round says exactly which of two counts is the newer one
  /// — which is all a device needs to ignore a push that overtook another.
  private async nextBadgeStamp(): Promise<number> {
    const next = ((await this.state.storage.get<number>("badgeStamp")) ?? 0) + 1;
    await this.state.storage.put("badgeStamp", next);
    return next;
  }

  /// The push carries the message itself, addressed to the device it goes to:
  /// the extension decrypts it and writes it, so the chat holds what the banner
  /// showed even if the socket never comes up.
  private async pushToDevices(frame: {
    chatId: string; msgId?: string; seq?: number; sentAt?: number;
    from?: string; fromDevice?: string; ts?: number; body?: unknown;
  }) {
    const tokens =
      (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    const devices = Object.entries(tokens);
    if (!devices.length) return;
    const badge = await this.totalUnread();
    const badgeStamp = await this.nextBadgeStamp();
    const userId = await this.getUserId();
    // Every device is handled independently: one failure neither cancels the
    // others nor fails the frame delivery that already went over the socket.
    const results = await Promise.all(
      devices.map(async ([deviceId, t]) => {
        try {
          return {
            deviceId,
            res: await sendPush(this.env, t.token, t.env, {
              chatId: frame.chatId, msgId: frame.msgId, seq: frame.seq,
              sentAt: frame.sentAt, badge, badgeStamp,
              from: frame.from, fromDevice: frame.fromDevice, ts: frame.ts,
              env: envelopeForDevice(frame.body, `${userId ?? ""}/${deviceId}`),
            }),
          };
        } catch (e) {
          console.warn(`push to device ${deviceId} for ${frame.chatId} failed: ${String(e)}`);
          return { deviceId, res: null };
        }
      })
    );
    const dead = results.filter((r) => r.res?.dead).map((r) => r.deviceId);
    if (dead.length) await this.dropPushTokens(dead);
  }

  /// A token APNs answered 410 for is removed from both the DO and D1.
  private async dropPushTokens(deviceIds: string[]) {
    const tokens =
      (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    let changed = false;
    for (const id of deviceIds) {
      if (id in tokens) {
        delete tokens[id];
        changed = true;
      }
    }
    if (changed) await this.state.storage.put("apns", tokens);
    await Promise.all(
      deviceIds.map((id) =>
        this.env.DB.prepare(
          "UPDATE devices SET apns_token = NULL, apns_env = NULL WHERE id = ?"
        ).bind(id).run().catch((e: unknown) =>
          console.warn(`clearing apns token of ${id} failed: ${String(e)}`))
      )
    );
  }

  // --- Catch-up after a reconnect ---

  /// Serves one catch-up portion and closes it with `syncDone`.
  ///
  /// The client owns the cursors: the object answers with a single portion,
  /// tells where each chat now stands, and returns to the event loop. Live
  /// traffic waits for one portion, not for the whole backlog, and a client
  /// that drops in the middle resumes from the cursor it last confirmed.
  private async serveCatchup(ws: WebSocket, userId: string, cursors: Record<string, number>) {
    let budget = SYNC_BUDGET;
    let chats = SYNC_CHATS;
    // a chat left untouched keeps its cursor and gets no syncState: the client
    // sees it stayed behind and asks for it in the next portion
    let pending = false;
    for (const [chatId, from] of Object.entries(cursors)) {
      if (budget <= 0 || chats <= 0) {
        pending = true;
        continue;
      }
      chats--;
      const limit = Math.min(SYNC_PAGE, budget);
      const res = await this.convStub(chatId).fetch(
        `https://do/history?fromSeq=${from}&limit=${limit}&userId=${userId}`
      );
      const r = (await res.json()) as {
        ok: boolean; msgs?: Array<Record<string, unknown>>;
        scanned?: number; lastScannedSeq?: number | null;
      };
      if (!r.ok) {
        // the chat is gone: nothing to catch up on, and the cursor stays where it was
        this.send(ws, { t: "syncState", chatId, cursor: from, more: false });
        continue;
      }
      for (const m of r.msgs ?? []) {
        // tombstones travel as deleted frames in the tail below
        if (m.deleted) continue;
        this.send(ws, {
          t: "msg", chatId,
          seq: m.seq as number, msgId: m.msgId as string,
          from: m.from as string, fromDevice: m.fromDevice as string,
          sentAt: m.sentAt as number, ts: m.ts as number, body: m.body,
          ...(m.service ? { service: true } : {}),
        });
      }
      const scanned = r.scanned ?? 0;
      budget -= scanned;
      // the cursor moves over the records scanned, not the ones sent: a page filtered
      // out entirely by a block must not stall the replay
      const cursor = scanned ? r.lastScannedSeq ?? from : from;
      // a full page means the journal may hold more; a short one means the
      // range ended, so the chat is caught up and gets its tail
      const more = scanned >= limit;
      this.send(ws, { t: "syncState", chatId, cursor, more });
      if (more) {
        pending = true;
        continue;
      }
      await this.sendChatTail(ws, userId, chatId);
    }
    this.send(ws, { t: "syncDone", more: pending });
  }

  /// Tombstones and read/delivered marks of a chat the client has caught up
  /// with: what happened to already delivered messages while it was offline.
  private async sendChatTail(ws: WebSocket, userId: string, chatId: string) {
    const er = await this.convStub(chatId).fetch(`https://do/events?userId=${userId}`);
    const e = (await er.json()) as {
      ok: boolean;
      deleted?: Array<{ msgId: string; by: string }>;
      readMarks?: Record<string, number>;
      deliveredMarks?: Record<string, number>;
    };
    if (!e.ok) return;
    for (const d of e.deleted ?? []) {
      this.send(ws, { t: "deleted", chatId, msgIds: [d.msgId], forAll: true, by: d.by });
    }
    for (const [by, upToSeq] of Object.entries(e.deliveredMarks ?? {})) {
      if (by !== userId) this.send(ws, { t: "receipt", chatId, kind: "delivered", upToSeq, by });
    }
    for (const [by, upToSeq] of Object.entries(e.readMarks ?? {})) {
      if (by !== userId) this.send(ws, { t: "receipt", chatId, kind: "read", upToSeq, by });
    }
  }

  // --- WebSocket hibernation handlers ---

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    const userId = await this.getUserId();
    if (!userId) return;
    let frame: ClientFrame;
    try {
      frame = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
    } catch {
      return;
    }
    const att = ws.deserializeAttachment() as SocketAttachment;

    switch (frame.t) {
      case "ping": {
        // presence rides on ping-pong: a fresh ping means online, silence past the TTL
        // (the alarm) or an explicit "bg" means offline. An open socket says nothing on
        // its own, since iOS holds it for minutes after the app is backgrounded.
        const wasFresh = this.presenceFresh();
        ws.serializeAttachment({ ...att, lastPing: nowSec() } satisfies SocketAttachment);
        this.send(ws, { t: "pong" });
        await this.state.storage.setAlarm(Date.now() + PRESENCE_TTL_MS);
        if (!wasFresh) await this.broadcastPresence(true);
        return;
      }

      case "bg":
        ws.serializeAttachment({ ...att, lastPing: 0 } satisfies SocketAttachment);
        await this.broadcastPresence(false);
        return;

      case "fg": {
        ws.serializeAttachment({ ...att, lastPing: nowSec() } satisfies SocketAttachment);
        await this.state.storage.setAlarm(Date.now() + PRESENCE_TTL_MS);
        await this.broadcastPresence(true);
        return;
      }

      case "send": {
        const res = await this.convStub(frame.chatId).fetch("https://do/send", {
          method: "POST",
          body: JSON.stringify({
            from: userId, fromDevice: att.deviceId,
            clientMsgId: frame.clientMsgId, sentAt: frame.sentAt, body: frame.body,
            service: frame.service ?? false,
          }),
        });
        const r = (await res.json()) as { ok: boolean; msgId?: string; seq?: number; ts?: number; error?: string };
        if (r.ok && r.msgId) {
          this.send(ws, {
            t: "sent", chatId: frame.chatId, clientMsgId: frame.clientMsgId,
            msgId: r.msgId, seq: r.seq!, ts: r.ts!,
          });
        } else {
          this.send(ws, {
            t: "error", error: r.error ?? "send_failed",
            chatId: frame.chatId, clientMsgId: frame.clientMsgId,
          });
        }
        return;
      }

      case "recv":
        await this.convStub(frame.chatId).fetch("https://do/recv", {
          method: "POST",
          body: JSON.stringify({ userId, seqs: frame.seqs }),
        });
        return;

      case "read":
        await this.convStub(frame.chatId).fetch("https://do/read", {
          method: "POST",
          body: JSON.stringify({ userId, upToSeq: frame.upToSeq }),
        });
        // this user's own read moves the chat's unread, so the cached badge is stale
        await this.invalidateUnread(frame.chatId);
        return;

      case "typing":
        await this.convStub(frame.chatId).fetch("https://do/typing", {
          method: "POST",
          body: JSON.stringify({ userId, kind: frame.kind }),
        });
        return;

      case "delete":
        await this.convStub(frame.chatId).fetch("https://do/delete", {
          method: "POST",
          body: JSON.stringify({ userId, msgIds: frame.msgIds, forAll: frame.forAll }),
        });
        return;

      case "sync":
      case "catchup": {
        const cursors: Record<string, number> = { ...frame.cursors };
        if (frame.t === "sync") {
          // chats the client does not know yet, created or joined while it was offline:
          // send the state and replay the history from zero
          const known = new Set(Object.keys(frame.cursors));
          const listed = await this.state.storage.list<unknown>({ prefix: "chat:" });
          for (const key of listed.keys()) {
            const chatId = key.slice(5);
            if (known.has(chatId)) continue;
            const sr = await this.convStub(chatId).fetch("https://do/state");
            const sj = (await sr.json()) as { ok: boolean; state?: unknown };
            if (sj.ok && sj.state) {
              this.send(ws, { t: "chat", chatId, event: "sync", state: sj.state } as ServerFrame);
              cursors[chatId] = 0; // history replayed below
            }
          }
        }
        await this.serveCatchup(ws, userId, cursors);
        return;
      }
    }
  }

  /// Silence past the TTL means offline, however open the socket still looks.
  async alarm() {
    if (!this.presenceFresh()) {
      await this.broadcastPresence(false);
    } else {
      await this.state.storage.setAlarm(Date.now() + PRESENCE_TTL_MS);
    }
  }

  async webSocketClose(ws: WebSocket) {
    ws.close();
    if (this.sockets().length === 0) {
      await this.broadcastPresence(false);
    }
  }

  async webSocketError(ws: WebSocket) {
    try { ws.close(); } catch { /* already closed */ }
    if (this.sockets().length === 0) {
      await this.broadcastPresence(false);
    }
  }
}
