import type { Env, ClientFrame, ServerFrame } from "../types";
import { json, err, nowSec } from "../util";
import { sendPush } from "../push/apns";

/// Presence-TTL: клиент пингует каждые ~12с; тишина дольше — офлайн.
const PRESENCE_TTL_MS = 35_000;

interface ChatFlags {
  pinned: boolean;
  muted: boolean;
  archived: boolean;
  joinedAt: number;
}

interface SocketAttachment {
  deviceId: string;
}

// Один DO на пользователя: все WS его устройств, чат-лист, presence, пуши.
export class UserSessionDO implements DurableObject {
  private userId: string | null = null;

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
    await Promise.all(
      ids.map((chatId) =>
        this.convStub(chatId)
          .fetch("https://do/presence", {
            method: "POST",
            body: JSON.stringify({ userId, online, lastSeen }),
          })
          .catch(() => {})
      )
    );
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
      server.serializeAttachment({ deviceId } satisfies SocketAttachment);
      this.send(server, { t: "hello", serverTime: nowSec() });

      await this.state.storage.put("lastPing", nowSec());
      await this.state.storage.setAlarm(Date.now() + PRESENCE_TTL_MS);
      if (this.sockets().length === 1) {
        // первое устройство онлайн
        this.state.waitUntil(this.broadcastPresence(true));
      }
      return new Response(null, { status: 101, webSocket: client });
    }

    switch (path) {
      case "/event": {
        const frame = (await req.json()) as ServerFrame;
        const live = this.sockets();
        if (live.length > 0) {
          for (const ws of live) this.send(ws, frame);
        }
        if (frame.t === "msg") {
          // непрочитанное/оффлайн → APNs (клиенты в fg сами погасят по chatId)
          const flags = await this.state.storage.get<ChatFlags>("chat:" + frame.chatId);
          const muted = flags?.muted ?? false;
          const userId = await this.getUserId();
          const isOwnEcho = userId !== null && frame.from === userId;
          if (live.length === 0 && !muted && !isOwnEcho) {
            this.state.waitUntil(this.pushToDevices(frame.chatId, frame.msgId));
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
        const out: Record<string, ChatFlags> = {};
        for (const [k, v] of listed) out[k.slice(5)] = v;
        return json({ ok: true, chats: out });
      }

      case "/flags": {
        const b = (await req.json()) as {
          chatId: string; pinned?: boolean; muted?: boolean; archived?: boolean;
        };
        const key = "chat:" + b.chatId;
        const flags = await this.state.storage.get<ChatFlags>(key);
        if (!flags) return err("chat_not_found", 404);
        if (b.pinned !== undefined) flags.pinned = b.pinned;
        if (b.muted !== undefined) flags.muted = b.muted;
        if (b.archived !== undefined) flags.archived = b.archived;
        await this.state.storage.put(key, flags);
        return json({ ok: true });
      }

      case "/push-token": {
        const b = (await req.json()) as { deviceId: string; apnsToken: string; env: string };
        const tokens =
          (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
        tokens[b.deviceId] = { token: b.apnsToken, env: b.env };
        await this.state.storage.put("apns", tokens);
        return json({ ok: true });
      }

      case "/presence-info": {
        const lastSeen = (await this.state.storage.get<number>("lastSeen")) ?? 0;
        const online = this.sockets().length > 0 && (await this.presenceFresh());
        return json({ ok: true, online, lastSeen });
      }

      default:
        return err("unknown_path", 404);
    }
  }

  private async pushToDevices(chatId: string, msgId?: string) {
    const tokens =
      (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    await Promise.all(
      Object.values(tokens).map((t) =>
        sendPush(this.env, t.token, t.env, { chatId, msgId, kind: "msg" }).catch(() => {})
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
        this.send(ws, { t: "pong" });
        // presence по пинг-понгу: свежий ping = онлайн; тишина дольше TTL
        // (alarm) или явный "bg" = офлайн. Сам факт живого сокета не значит
        // ничего: iOS держит его минуты после сворачивания.
        const wasFresh = await this.presenceFresh();
        await this.state.storage.put("lastPing", nowSec());
        await this.state.storage.setAlarm(Date.now() + PRESENCE_TTL_MS);
        if (!wasFresh) this.state.waitUntil(this.broadcastPresence(true));
        return;
      }

      case "bg":
        await this.state.storage.put("lastPing", 0);
        this.state.waitUntil(this.broadcastPresence(false));
        return;

      case "fg": {
        await this.state.storage.put("lastPing", nowSec());
        await this.state.storage.setAlarm(Date.now() + PRESENCE_TTL_MS);
        this.state.waitUntil(this.broadcastPresence(true));
        return;
      }

      case "send": {
        const res = await this.convStub(frame.chatId).fetch("https://do/send", {
          method: "POST",
          body: JSON.stringify({
            from: userId, fromDevice: att.deviceId,
            clientMsgId: frame.clientMsgId, sentAt: frame.sentAt, body: frame.body,
          }),
        });
        const r = (await res.json()) as { ok: boolean; msgId?: string; seq?: number; ts?: number; error?: string };
        if (r.ok && r.msgId) {
          this.send(ws, {
            t: "sent", chatId: frame.chatId, clientMsgId: frame.clientMsgId,
            msgId: r.msgId, seq: r.seq!, ts: r.ts!,
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
        // доигрывание пропущенных сообщений по курсорам клиента
        for (const [chatId, lastSeq] of Object.entries(frame.cursors)) {
          const res = await this.convStub(chatId).fetch(
            `https://do/history?fromSeq=${lastSeq}&limit=200`
          );
          const r = (await res.json()) as { ok: boolean; msgs?: Array<Record<string, unknown>> };
          if (r.ok && r.msgs) {
            for (const m of r.msgs) {
              this.send(ws, {
                t: "msg", chatId,
                seq: m.seq as number, msgId: m.msgId as string,
                from: m.from as string, fromDevice: m.fromDevice as string,
                sentAt: m.sentAt as number, ts: m.ts as number, body: m.body,
              });
            }
          }
        }
        return;
      }
    }
  }

  /// Онлайн = ping был свежее TTL.
  private async presenceFresh(): Promise<boolean> {
    const last = (await this.state.storage.get<number>("lastPing")) ?? 0;
    return nowSec() - last < PRESENCE_TTL_MS / 1000;
  }

  /// Тишина дольше TTL — объявляем офлайн, даже если сокет формально жив.
  async alarm() {
    if (!(await this.presenceFresh())) {
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
