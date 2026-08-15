import type { Env, ClientFrame, ServerFrame } from "../types";
import { json, err, nowSec } from "../util";
import { sendPush } from "../push/apns";

/// Presence-TTL: клиент пингует каждые ~12с; тишина дольше — офлайн.
const PRESENCE_TTL_MS = 35_000;
const PRESENCE_TTL = PRESENCE_TTL_MS / 1000;

interface ChatFlags {
  pinned: boolean;
  muted: boolean;
  /// момент снятия mute (сек); не задан — mute бессрочный
  mutedUntil?: number;
  archived: boolean;
  joinedAt: number;
}

/// Mute со сроком: истёкший считается снятым.
function muteActive(flags: ChatFlags | undefined, now: number): boolean {
  if (!flags?.muted) return false;
  return !flags.mutedUntil || flags.mutedUntil > now;
}

function muteExpired(flags: ChatFlags | undefined, now: number): boolean {
  return !!flags?.muted && !!flags.mutedUntil && flags.mutedUntil <= now;
}

interface SocketAttachment {
  deviceId: string;
  // время последнего ping (сек); сокет без свежего ping считается подвешенным
  lastPing: number;
}

// Один DO на пользователя: все WS его устройств, чат-лист, presence, пуши.
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
    try { ws.send(JSON.stringify(frame)); } catch { /* сокет умер — hibernation API сам почистит */ }
  }

  private broadcast(frame: ServerFrame) {
    for (const ws of this.sockets()) this.send(ws, frame);
  }

  // есть ли сокет с живым клиентом (ping в пределах TTL);
  // формально открытый, но подвешенный сокет свежим не считается
  private presenceFresh(): boolean {
    const cutoff = nowSec() - PRESENCE_TTL;
    return this.sockets().some((ws) => {
      const att = ws.deserializeAttachment() as SocketAttachment | null;
      return (att?.lastPing ?? 0) > cutoff;
    });
  }

  /// Снимает mute, у которого истёк срок, и отдаёт актуальные флаги чата.
  private async clearExpiredMute(chatId: string): Promise<ChatFlags | undefined> {
    const key = "chat:" + chatId;
    const flags = await this.state.storage.get<ChatFlags>(key);
    if (!muteExpired(flags, nowSec())) return flags;
    flags!.muted = false;
    delete flags!.mutedUntil;
    await this.state.storage.put(key, flags!);
    return flags;
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
      this.send(server, { t: "hello", serverTime: nowSec() });

      await this.state.storage.setAlarm(Date.now() + PRESENCE_TTL_MS);
      if (this.sockets().length === 1) {
        // первое устройство онлайн
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
          // контентное сообщение меняет unread чата → кэш бейджа устарел
          await this.invalidateUnread(frame.chatId);
          const flags = await this.clearExpiredMute(frame.chatId);
          const muted = muteActive(flags, nowSec());
          const userId = await this.getUserId();
          const isOwnEcho = userId !== null && frame.from === userId;
          // APNs уходит всегда и сразу, независимо от live-сокетов:
          // доставка по WS не гарантирована, дубль гасит клиент
          // (willPresent по chatId/msgId).
          // The call is awaited here rather than deferred: waitUntil gives no
          // timing guarantee. The sender is not waiting on it — his ack left
          // ConversationDO before this delivery was queued.
          if (!muted && !isOwnEcho) {
            await this.pushToDevices(frame.chatId, frame.msgId, frame.seq, frame.sentAt);
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
        // срок живёт только вместе со своим включением mute: muted без mutedUntil
        // (или mutedUntil: null) — бессрочно, muted:false — снятие
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
        // userId нужен для /unread-count даже до первого WS-коннекта
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

      // токен устройства отозван: рвём его сокеты и убираем его APNs-токен
      case "/revoke-device": {
        const b = (await req.json()) as { deviceId: string };
        for (const ws of this.sockets()) {
          const att = ws.deserializeAttachment() as SocketAttachment | null;
          if (att?.deviceId !== b.deviceId) continue;
          try { ws.close(4401, "revoked"); } catch { /* уже закрыт */ }
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

  // --- бейдж: суммарный unread по чатам ---
  // Кэш unread в storage ("unreadCache"), инвалидация по входящим msg и
  // собственным read; ленивый пересчёт через ConversationDO /unread-count
  // в момент отправки пуша — N запросов только по инвалидированным чатам.

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

  private async pushToDevices(chatId: string, msgId?: string, seq?: number, sentAt?: number) {
    const tokens =
      (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    const devices = Object.entries(tokens);
    if (!devices.length) return;
    const badge = await this.totalUnread();
    // Every device is handled independently: one failure neither cancels the
    // others nor fails the frame delivery that already went over the socket.
    const results = await Promise.all(
      devices.map(async ([deviceId, t]) => {
        try {
          return {
            deviceId,
            res: await sendPush(this.env, t.token, t.env, { chatId, msgId, seq, sentAt, badge }),
          };
        } catch (e) {
          console.warn(`push to device ${deviceId} for ${chatId} failed: ${String(e)}`);
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
        // presence по пинг-понгу: свежий ping = онлайн; тишина дольше TTL
        // (alarm) или явный "bg" = офлайн. Сам факт живого сокета не значит
        // ничего: iOS держит его минуты после сворачивания.
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
        // собственный read двигает unread чата → кэш бейджа устарел
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

      case "sync": {
        // чаты, о которых клиент ещё не знает (создан/добавлен, пока был офлайн):
        // прислать state и историю с нуля
        const known = new Set(Object.keys(frame.cursors));
        const listed = await this.state.storage.list<unknown>({ prefix: "chat:" });
        for (const key of listed.keys()) {
          const chatId = key.slice(5);
          if (known.has(chatId)) continue;
          const sr = await this.convStub(chatId).fetch("https://do/state");
          const sj = (await sr.json()) as { ok: boolean; state?: unknown };
          if (sj.ok && sj.state) {
            this.send(ws, { t: "chat", chatId, event: "sync", state: sj.state } as ServerFrame);
            frame.cursors[chatId] = 0; // и доиграть историю ниже
          }
        }
        // доигрывание пропущенных сообщений по курсорам клиента — батчами до исчерпания
        const BATCH = 200;
        for (const [chatId, lastSeq] of Object.entries(frame.cursors)) {
          let cursor = lastSeq;
          for (;;) {
            const res = await this.convStub(chatId).fetch(
              `https://do/history?fromSeq=${cursor}&limit=${BATCH}&userId=${userId}`
            );
            const r = (await res.json()) as {
              ok: boolean; msgs?: Array<Record<string, unknown>>;
              scanned?: number; lastScannedSeq?: number | null;
            };
            if (!r.ok || !r.scanned) break;
            for (const m of r.msgs ?? []) {
              // тумбстоуны уходят deleted-фреймами ниже
              if (m.deleted) continue;
              this.send(ws, {
                t: "msg", chatId,
                seq: m.seq as number, msgId: m.msgId as string,
                from: m.from as string, fromDevice: m.fromDevice as string,
                sentAt: m.sentAt as number, ts: m.ts as number, body: m.body,
                ...(m.service ? { service: true } : {}),
              });
            }
            // курсор двигается по просмотренным записям, а не по отданным:
            // страница, целиком отфильтрованная блокировкой, не должна
            // останавливать доигрывание
            cursor = r.lastScannedSeq ?? cursor;
            if (r.scanned < BATCH) break;
          }
          // тумбстоуны и read/delivered-марки, которые случились пока клиент был офлайн
          const er = await this.convStub(chatId).fetch(`https://do/events?userId=${userId}`);
          const e = (await er.json()) as {
            ok: boolean;
            deleted?: Array<{ msgId: string; by: string }>;
            readMarks?: Record<string, number>;
            deliveredMarks?: Record<string, number>;
          };
          if (e.ok) {
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
        }
        return;
      }
    }
  }

  /// Тишина дольше TTL — объявляем офлайн, даже если сокет формально жив.
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
    try { ws.close(); } catch { /* уже закрыт */ }
    if (this.sockets().length === 0) {
      await this.broadcastPresence(false);
    }
  }
}
