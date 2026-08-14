import type { Env, ChatState, ChatMember, StoredMsg, ServerFrame } from "../types";
import { ulid, json, err, seqKey, nowSec } from "../util";

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

  private async fanout(frame: ServerFrame, opts?: { except?: string; only?: string[] }) {
    const members = await this.loadMembers();
    const targets = opts?.only ?? [...members.keys()];
    const body = JSON.stringify(frame);
    await Promise.all(
      targets
        .filter((u) => u !== opts?.except && members.has(u))
        .map((u) =>
          this.userStub(u)
            .fetch("https://do/event", { method: "POST", body })
            .catch(() => {})
        )
    );
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
    await Promise.all(
      userIds.map((u) =>
        this.userStub(u)
          .fetch(`https://do/${removed ? "chat-removed" : "chat-added"}`, {
            method: "POST",
            body: JSON.stringify({ chatId: meta.chatId }),
          })
          .catch(() => {})
      )
    );
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
          // message request: в direct получатель должен явно принять переписку
          accepted: uid === b.createdBy || b.kind === "group",
        };
        this.members.set(uid, m);
        await this.state.storage.put("member:" + uid, m);
      }
      await this.notifyUserDOsChatList([...this.members.keys()]);
      await this.broadcastChat("created");
      return json({ ok: true, chatId: b.chatId });
    }

    const meta = await this.loadMeta();
    if (!meta) return err("chat_not_found", 404);

    switch (path) {
      case "/state":
        return json({ ok: true, state: await this.chatState() });

      case "/history": {
        const fromSeq = Number(url.searchParams.get("fromSeq") ?? "0");
        const toSeq = Number(url.searchParams.get("toSeq") ?? String(meta.lastSeq));
        const limit = Math.min(Number(url.searchParams.get("limit") ?? "100"), 200);
        const reverse = url.searchParams.get("dir") === "back";
        const listed = await this.state.storage.list<StoredMsg>({
          start: seqKey(fromSeq + 1),
          end: seqKey(toSeq + 1),
          limit,
          reverse,
        });
        return json({ ok: true, msgs: [...listed.values()] });
      }

      case "/events": {
        // тумбстоуны удалённых сообщений и текущие read/delivered-марки —
        // для доигрывания при sync после офлайна
        const deleted: Array<{ msgId: string; by: string }> = [];
        for (const [, m] of await this.state.storage.list<StoredMsg>({ prefix: "msg:" })) {
          if (m.deleted) deleted.push({ msgId: m.msgId, by: m.deletedBy ?? m.from });
        }
        const readMarks =
          (await this.state.storage.get<Record<string, number>>("readMarks")) ?? {};
        const deliveredMarks =
          (await this.state.storage.get<Record<string, number>>("deliveredMarks")) ?? {};
        return json({ ok: true, deleted, readMarks, deliveredMarks });
      }

      case "/unread-count": {
        // компактный счётчик для бейджа: lastSeq минус read-марка юзера
        const userId = url.searchParams.get("userId") ?? "";
        // заявка до принятия в бейдж не идёт: число выдало бы, сколько уже написали
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

        // идемпотентность
        const dupeKey = `cmid:${b.from}/${b.clientMsgId}`;
        const dupe = await this.state.storage.get<{ msgId: string; seq: number; ts: number }>(dupeKey);
        if (dupe) return json({ ok: true, ...dupe, dupe: true });

        const seq = meta.lastSeq + 1;
        const msg: StoredMsg = {
          msgId: ulid(), seq, from: b.from, fromDevice: b.fromDevice,
          clientMsgId: b.clientMsgId, sentAt: b.sentAt, ts: nowSec(), body: b.body,
          ...(b.service ? { service: true } : {}),
        };
        meta.lastSeq = seq;
        this.meta = meta;
        await this.state.storage.put({
          meta,
          [seqKey(seq)]: msg,
          [dupeKey]: { msgId: msg.msgId, seq, ts: msg.ts },
        });

        // dev: искусственная сетевая задержка перед fanout (DEV_WS_LATENCY_MS)
        const latency = Number(this.env.DEV_WS_LATENCY_MS ?? 0);
        if (latency > 0) await new Promise((r) => setTimeout(r, latency));

        const frame: ServerFrame = {
          t: "msg", chatId: meta.chatId, seq, msgId: msg.msgId,
          from: msg.from, fromDevice: msg.fromDevice,
          sentAt: msg.sentAt, ts: msg.ts, body: msg.body,
          ...(msg.service ? { service: true } : {}),
        };
        await this.fanout(frame, { except: b.from });
        // эхо на другие устройства автора идёт через его же UserDO
        await this.fanout(frame, { only: [b.from] });
        return json({ ok: true, msgId: msg.msgId, seq, ts: msg.ts });
      }

      case "/recv": {
        const b = (await req.json()) as { userId: string; seqs: number[] };
        const members = await this.loadMembers();
        // до accept получатель заявки невидим автору — delivered-квитанции не шлём
        if (!members.get(b.userId)?.accepted) return json({ ok: true });
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
        // до accept read-receipts автору не уходят (message request)
        if (!members.get(b.userId)?.accepted) return json({ ok: true });
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
        // до accept получатель невидим для автора заявки
        if (!members.get(b.userId)!.accepted) return json({ ok: true });
        await this.fanout(
          { t: "typing", chatId: meta.chatId, from: b.userId, kind: b.kind },
          { except: b.userId }
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
          for (const [key, m] of await this.state.storage.list<StoredMsg>({ prefix: "msg:" })) {
            if (b.msgIds.includes(m.msgId)) {
              if (m.from !== b.userId && actor.role !== "admin") continue;
              updates[key] = { ...m, body: null, deleted: true, deletedBy: b.userId };
            }
          }
          void idx;
          if (Object.keys(updates).length) await this.state.storage.put(updates);
          await this.fanout({
            t: "deleted", chatId: meta.chatId, msgIds: b.msgIds, forAll: true, by: b.userId,
          });
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
          await Promise.all(
            b.remove.map((u) =>
              this.userStub(u).fetch("https://do/event", {
                method: "POST",
                body: JSON.stringify({ t: "chat", chatId: meta.chatId, event: "members", state }),
              }).catch(() => {})
            )
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
        await this.fanout(
          { t: "presence", userId: b.userId, online: b.online, lastSeen: b.lastSeen },
          { except: b.userId }
        );
        return json({ ok: true });
      }

      default:
        return err("unknown_path", 404);
    }
  }
}
