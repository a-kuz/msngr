import type { Env, ClientFrame, ServerFrame, PublicUser } from "../types";
import { json, err, nowSec, shouldArmAlarm } from "../util";
import { sendPush, envelopeForDevice } from "../push/apns";
import { PROTOCOL_VERSION, MIN_CLIENT_PROTOCOL } from "../version";
import {
  newCounters, snapshot, diff, logPerf, wrapState, wrapDB, wrapStub, type PerfCounters,
} from "../perf";

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

/// Address-book hashes one sync call takes; a longer book arrives in chunks.
const CONTACTS_SYNC_MAX = 5000;

interface ChatFlags {
  pinned: boolean;
  muted: boolean;
  /// when the mute lifts, in seconds; unset means it never does on its own
  mutedUntil?: number;
  archived: boolean;
  joinedAt: number;
  /// APNs sound for this chat's pushes; unset falls back to the user's
  /// direct/group default, then "default"
  sound?: string;
}

/// The user's default push sounds by chat shape, stored under "notifySounds".
interface NotifySounds {
  direct?: string;
  group?: string;
}

/// A per-chat sound or a default: a caf name the app bundles, or "default".
const SOUND_NAME = /^[A-Za-z0-9._-]{1,64}$/;

function chatShape(chatId: string): "direct" | "group" {
  return chatId.startsWith("direct:") || chatId.startsWith("self:") ? "direct" : "group";
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

/// Push queue. A frame's delivery is acknowledged the moment the sockets have
/// it; the APNs call runs from this queue afterwards, so its latency paces no
/// chat and its failure fails no delivery. A job lives until every device has
/// its push or refuses it for good: a transient failure moves the job's
/// deadline out on a growing pause and never gives it up, with the devices
/// already served written down so a retry reaches only the ones still owed.
/// Jobs waiting out a pause hold nothing behind them — banner order and the
/// badge are kept by seq and badgeStamp, not by the queue.
const PUSH_PREFIX = "pq:";
/// Pushes sent per alarm invocation; the queue re-arms for the rest.
const PUSH_DRAIN = 10;
/// Pause before retrying a job whose APNs call failed in transit, by the
/// number of passes already failed; the last value repeats until it lands.
const PUSH_RETRY_MS = [1_000, 5_000, 15_000, 30_000];

function pushKey(id: number): string {
  return PUSH_PREFIX + String(id).padStart(16, "0");
}

/// The E2EE device set: one identity record per device (`ik:<deviceId>`), the
/// one-time prekeys under `otp:<deviceId>:<keyId>`, and `devicesVersion`
/// stamping the set. Reads and writes are serialized by the object, which is
/// what the prekey handout (a read that deletes) actually needs.
const IK_PREFIX = "ik:";

interface IdentityRecord {
  identityKey: string;
  identitySignKey: string;
  identityKeySig: string;
  signedPrekeyId: number;
  signedPrekey: string;
  signedPrekeySig: string;
}

interface PrekeyUpload {
  id: number;
  key: string;
}

function ikKey(deviceId: string): string {
  return IK_PREFIX + deviceId;
}

function otpPrefix(deviceId: string): string {
  return `otp:${deviceId}:`;
}

/// Padded so lexicographic storage order is numeric key-id order: the handout
/// consumes the lowest id first.
function otpKey(deviceId: string, keyId: number): string {
  return otpPrefix(deviceId) + String(keyId).padStart(10, "0");
}

/// storage.put/get take at most 128 keys per call
const STORAGE_BATCH = 128;

interface PushJob {
  chatId: string;
  seq?: number;
  sentAt?: number;
  from?: string;
  fromDevice?: string;
  ts?: number;
  body?: unknown;
  /// passes already failed in transit
  attempt?: number;
  /// not retried before this (ms since epoch)
  nextAt?: number;
  /// devices whose push already landed; a retry skips them
  pushed?: string[];
}

// One object per user: the sockets of all their devices, the chat list, presence, pushes.
export class UserDO implements DurableObject {
  private userId: string | null = null;
  /// Dev test hook (/dev-fault): how many frame deliveries to reject next.
  private devFailEvents = 0;
  /// True while alarm() runs. setAlarm during a running alarm handler cancels
  /// the handler mid-await (workerd), so while it runs, arming requests
  /// collect here and the handler arms the nearest one as it leaves.
  private alarmRunning = false;
  private rearmAt: number | undefined;

  /// dev measurement (PERF_LOG); never installed otherwise
  private perf: PerfCounters | null = null;

  constructor(private state: DurableObjectState, private env: Env) {
    if (env.PERF_LOG) {
      this.perf = newCounters();
      this.state = wrapState(state, this.perf);
      this.env = { ...env, DB: wrapDB(env.DB, this.perf) };
    }
  }

  private async getUserId(): Promise<string | null> {
    if (!this.userId) this.userId = (await this.state.storage.get<string>("userId")) ?? null;
    return this.userId;
  }

  private convStub(chatId: string) {
    const stub = this.env.CONV_DO.get(this.env.CONV_DO.idFromName(chatId));
    return this.perf ? wrapStub(stub, this.perf) : stub;
  }

  private userStub(userId: string) {
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(userId));
    return this.perf ? wrapStub(stub, this.perf) : stub;
  }

  /// Wraps one invocation (a fetch or a client frame) in a PERF line.
  private async measured<T>(op: string, body: () => Promise<T>, extra?: object): Promise<T> {
    if (!this.perf) return body();
    const before = snapshot(this.perf);
    const t0 = Date.now();
    try {
      return await body();
    } finally {
      logPerf("user", op, Date.now() - t0, diff(this.perf, before), snapshot(this.perf),
              { userId: this.userId, ...(extra ?? {}) });
    }
  }

  private sockets(): WebSocket[] {
    return this.state.getWebSockets();
  }

  private send(ws: WebSocket, frame: ServerFrame) {
    const body = JSON.stringify(frame);
    if (this.perf) {
      this.perf.outFrames++;
      this.perf.outBytes += body.length;
    }
    try { ws.send(body); } catch { /* socket is gone; the hibernation API sweeps it */ }
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

  /// Arms the alarm, keeping whichever deadline is nearer. The one alarm is
  /// shared by the push queue and the presence check.
  private async armAlarm(atMs: number) {
    if (this.alarmRunning) {
      this.rearmAt = this.rearmAt === undefined ? atMs : Math.min(this.rearmAt, atMs);
      return;
    }
    const now = Date.now();
    const at = Math.max(atMs, now + 1);
    const pending = await this.state.storage.getAlarm();
    if (!shouldArmAlarm(pending, at, now)) return;
    await this.state.storage.setAlarm(at);
  }

  /// Schedules the freshness check the presence TTL asks for. The deadline is
  /// stored because the alarm is shared: an alarm firing early for a push must
  /// not read as the TTL running out.
  private async armPresenceCheck() {
    const at = Date.now() + PRESENCE_TTL_MS;
    await this.state.storage.put("presenceCheckAt", at);
    await this.armAlarm(at);
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
    return this.measured(new URL(req.url).pathname, () => this.handleFetch(req));
  }

  private async handleFetch(req: Request): Promise<Response> {
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

      await this.armPresenceCheck();
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
        // The delivery is idempotent: the chat's seq orders its msg frames and
        // they arrive per chat in order, so anything at or below the mark has
        // been applied already — a retry of a delivery that in fact succeeded
        // is answered "already have it", and never costs a second push.
        // Receipts and marks are monotonic and chat/presence frames are
        // snapshots, so they need no mark.
        let inboxKey: string | undefined;
        if (frame.t === "msg" && typeof frame.seq === "number") {
          inboxKey = "in:" + frame.chatId;
          const applied = (await this.state.storage.get<number>(inboxKey)) ?? 0;
          if (frame.seq <= applied) return json({ ok: true, dupe: true });
        }
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
          // the push leaves through the object's own queue: this delivery is
          // acknowledged now, and APNs' latency paces no chat
          if (!muted && !isOwnEcho) {
            await this.enqueuePush(frame);
          }
        } else if (frame.t === "msg" && frame.service && frame.notify) {
          // a service frame that still notifies (a missed-call record): the
          // push goes out, but the chat is not relisted and unread stays put
          const flags = await this.clearExpiredMute(frame.chatId);
          const muted = muteActive(flags, nowSec());
          const userId = await this.getUserId();
          const isOwnEcho = userId !== null && frame.from === userId;
          if (!muted && !isOwnEcho) {
            await this.enqueuePush(frame);
          }
        }
        if (inboxKey && frame.t === "msg") {
          await this.state.storage.put(inboxKey, frame.seq);
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

      case "/flags-read": {
        const b = (await req.json()) as { chatId: string };
        const flags = await this.state.storage.get<ChatFlags>("chat:" + b.chatId);
        if (!flags) return err("chat_not_found", 404);
        return json({ ok: true, flags });
      }

      case "/flags": {
        const b = (await req.json()) as {
          chatId: string; pinned?: boolean; muted?: boolean;
          mutedUntil?: number | null; archived?: boolean; sound?: string | null;
        };
        const key = "chat:" + b.chatId;
        const flags = await this.state.storage.get<ChatFlags>(key);
        if (!flags) return err("chat_not_found", 404);
        if (b.sound !== undefined) {
          if (b.sound === null || b.sound === "default") delete flags.sound;
          else if (SOUND_NAME.test(b.sound)) flags.sound = b.sound;
          else return err("bad_sound");
        }
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

      case "/person-sound": {
        const b = (await req.json()) as { userId?: string; sound?: string | null; read?: boolean };
        if (!b.userId) return err("bad_request");
        if (b.read) {
          const sound = await this.state.storage.get<string>(`usnd:${b.userId}`);
          return json({ ok: true, sound: sound ?? null });
        }
        if (b.sound === null || b.sound === undefined || b.sound === "default") {
          await this.state.storage.delete(`usnd:${b.userId}`);
        } else if (SOUND_NAME.test(b.sound)) {
          await this.state.storage.put(`usnd:${b.userId}`, b.sound);
        } else {
          return err("bad_sound");
        }
        return json({ ok: true });
      }

      case "/notify-sounds": {
        if (req.method === "GET" || url.searchParams.get("read") === "1") {
          const sounds = (await this.state.storage.get<NotifySounds>("notifySounds")) ?? {};
          return json({ ok: true, sounds });
        }
        const b = (await req.json()) as { direct?: string | null; group?: string | null };
        const sounds = (await this.state.storage.get<NotifySounds>("notifySounds")) ?? {};
        for (const shape of ["direct", "group"] as const) {
          const v = b[shape];
          if (v === undefined) continue;
          if (v === null || v === "default") delete sounds[shape];
          else if (SOUND_NAME.test(v)) sounds[shape] = v;
          else return err("bad_sound");
        }
        await this.state.storage.put("notifySounds", sounds);
        return json({ ok: true, sounds });
      }

      case "/account-wipe": {
        // the account is being deleted: close every socket and erase the
        // object whole — keys, chat flags, sounds, the address book, tokens
        for (const ws of this.sockets()) {
          try { ws.close(1000, "account_deleted"); } catch { /* already gone */ }
        }
        await this.state.storage.deleteAlarm();
        await this.state.storage.deleteAll();
        this.userId = null;
        return json({ ok: true });
      }

      case "/sound-exceptions": {
        const chats: { chatId: string; sound: string }[] = [];
        for (const [k, v] of await this.state.storage.list<ChatFlags>({ prefix: "chat:" })) {
          if (v.sound) chats.push({ chatId: k.slice("chat:".length), sound: v.sound });
        }
        const people: { userId: string; sound: string }[] = [];
        for (const [k, v] of await this.state.storage.list<string>({ prefix: "usnd:" })) {
          people.push({ userId: k.slice("usnd:".length), sound: v });
        }
        return json({ ok: true, chats, people });
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

      case "/notify-plain": {
        // A push that is not a chat message: it carries a ready alert, no
        // envelope, and leaves the badge at the current unread total.
        const b = (await req.json()) as {
          chatId: string; title: string; body: string; userId?: string;
        };
        if (b.userId) {
          await this.state.storage.put("userId", b.userId);
          this.userId = b.userId;
        }
        await this.pushPlain(b.chatId, { title: b.title, body: b.body });
        return json({ ok: true });
      }

      case "/revoke-device": {
        const b = (await req.json()) as { deviceId: string; userId?: string };
        if (b.userId) {
          await this.state.storage.put("userId", b.userId);
          this.userId = b.userId;
        }
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
        // the device's keys go with it: the next send builds no box for it and
        // its prekeys stop being handed out
        const otps = await this.state.storage.list({ prefix: otpPrefix(b.deviceId) });
        const gone = [ikKey(b.deviceId), ...otps.keys()];
        for (let i = 0; i < gone.length; i += STORAGE_BATCH) {
          await this.state.storage.delete(gone.slice(i, i + STORAGE_BATCH));
        }
        const version = ((await this.state.storage.get<number>("devicesVersion")) ?? 1) + 1;
        await this.state.storage.put("devicesVersion", version);
        await this.broadcastDevicesChanged(version);
        if (this.sockets().length === 0) await this.broadcastPresence(false);
        return json({ ok: true });
      }

      // --- the E2EE device set: identity keys, prekeys, the set's version ---

      case "/keys-register": {
        const b = (await req.json()) as {
          userId: string; deviceId: string;
          identityKey: string; identitySignKey: string; identityKeySig: string;
          signedPrekey: { id: number; key: string; sig: string };
          oneTimePrekeys?: PrekeyUpload[];
          /// a linked device changes the set an existing account's peers hold;
          /// the first registration starts it and nobody holds a copy yet
          bump?: boolean;
        };
        await this.state.storage.put("userId", b.userId);
        this.userId = b.userId;
        let version = (await this.state.storage.get<number>("devicesVersion")) ?? 1;
        if (b.bump) version++;
        const puts: Record<string, unknown> = {
          [ikKey(b.deviceId)]: {
            identityKey: b.identityKey,
            identitySignKey: b.identitySignKey,
            identityKeySig: b.identityKeySig,
            signedPrekeyId: b.signedPrekey.id,
            signedPrekey: b.signedPrekey.key,
            signedPrekeySig: b.signedPrekey.sig,
          } satisfies IdentityRecord,
          // The identity belongs to the account, not to any device row:
          // revoking the last device drops its keys, and this record is what
          // a backup restore still has to verify its signature against.
          accountIdentity: {
            identityKey: b.identityKey,
            identitySignKey: b.identitySignKey,
          },
          devicesVersion: version,
        };
        for (const k of (b.oneTimePrekeys ?? []).slice(0, 200)) {
          puts[otpKey(b.deviceId, k.id)] = k.key;
        }
        await this.putBatched(puts);
        if (b.bump) await this.broadcastDevicesChanged(version);
        return json({ ok: true, version });
      }

      case "/keys-topup": {
        const b = (await req.json()) as { deviceId: string; oneTimePrekeys?: PrekeyUpload[] };
        const wanted = (b.oneTimePrekeys ?? []).slice(0, 200);
        const names = wanted.map((k) => otpKey(b.deviceId, k.id));
        const existing = new Set<string>();
        for (let i = 0; i < names.length; i += STORAGE_BATCH) {
          const got = await this.state.storage.get(names.slice(i, i + STORAGE_BATCH));
          for (const k of got.keys()) existing.add(k);
        }
        // a key id already uploaded keeps its first value: a retry of the same
        // top-up must not replace a key a bundle may have handed out meanwhile
        const puts: Record<string, unknown> = {};
        wanted.forEach((k, i) => {
          if (!existing.has(names[i])) puts[names[i]] = k.key;
        });
        if (Object.keys(puts).length) await this.putBatched(puts);
        return json({ ok: true });
      }

      case "/keys-count": {
        const deviceId = url.searchParams.get("deviceId") ?? "";
        const listed = await this.state.storage.list({ prefix: otpPrefix(deviceId) });
        return json({ ok: true, count: listed.size });
      }

      case "/keys-prekeys": {
        // X3DH bundles for every device; the one-time prekey with the lowest id
        // is consumed here, inside the object, so two senders never draw the same one
        const iks = await this.state.storage.list<IdentityRecord>({ prefix: IK_PREFIX });
        const bundles = [];
        for (const [key, d] of iks) {
          const deviceId = key.slice(IK_PREFIX.length);
          const prefix = otpPrefix(deviceId);
          const otps = await this.state.storage.list<string>({ prefix, limit: 1 });
          let oneTimePrekey: { id: number; key: string } | null = null;
          for (const [otpName, otpVal] of otps) {
            oneTimePrekey = { id: Number(otpName.slice(prefix.length)), key: otpVal };
            await this.state.storage.delete(otpName);
          }
          bundles.push({
            deviceId,
            identityKey: d.identityKey,
            identitySignKey: d.identitySignKey,
            identityKeySig: d.identityKeySig,
            signedPrekey: { id: d.signedPrekeyId, key: d.signedPrekey, sig: d.signedPrekeySig },
            oneTimePrekey,
          });
        }
        return json({ ok: true, bundles });
      }

      case "/keys-devices": {
        const iks = await this.state.storage.list<IdentityRecord>({ prefix: IK_PREFIX });
        const version = (await this.state.storage.get<number>("devicesVersion")) ?? null;
        const devices = [...iks].map(([key, d]) => ({
          deviceId: key.slice(IK_PREFIX.length),
          identityKey: d.identityKey,
          identitySignKey: d.identitySignKey,
          identityKeySig: d.identityKeySig,
        }));
        const account = (await this.state.storage.get<{
          identityKey: string; identitySignKey: string;
        }>("accountIdentity")) ?? null;
        return json({ ok: true, devices, account, version });
      }

      case "/keys-version": {
        // null: no device ever registered here, so the user is unknown
        const version = (await this.state.storage.get<number>("devicesVersion")) ?? null;
        return json({ ok: true, version });
      }

      case "/keys-update": {
        const b = (await req.json()) as {
          deviceId: string; identityKey: string; identitySignKey: string; identityKeySig: string;
        };
        const rec = await this.state.storage.get<IdentityRecord>(ikKey(b.deviceId));
        if (!rec) return err("not_found", 404);
        rec.identityKey = b.identityKey;
        rec.identitySignKey = b.identitySignKey;
        rec.identityKeySig = b.identityKeySig;
        await this.state.storage.put(ikKey(b.deviceId), rec);
        await this.state.storage.put("accountIdentity", {
          identityKey: b.identityKey,
          identitySignKey: b.identitySignKey,
        });
        // a rotated identity is a changed device set: peers holding the old
        // key by version must drop the cache, or per-send TOFU keeps trusting
        // the key this update just replaced
        const version = ((await this.state.storage.get<number>("devicesVersion")) ?? 1) + 1;
        await this.state.storage.put("devicesVersion", version);
        await this.broadcastDevicesChanged(version);
        return json({ ok: true, version });
      }

      case "/keys-republish": {
        // The device found out its published bundle is stale: peers build
        // X3DH sessions it cannot open (its own prekey private halves are
        // missing). It hands in a fresh signed prekey and a fresh set of
        // one-time prekeys; the old one-times are dropped whole — every one
        // of them is from the generation that does not open.
        const b = (await req.json()) as {
          deviceId: string;
          signedPrekey: { id: number; key: string; sig: string };
          oneTimePrekeys?: PrekeyUpload[];
        };
        const rec = await this.state.storage.get<IdentityRecord>(ikKey(b.deviceId));
        if (!rec) return err("not_found", 404);
        rec.signedPrekeyId = b.signedPrekey.id;
        rec.signedPrekey = b.signedPrekey.key;
        rec.signedPrekeySig = b.signedPrekey.sig;
        const stale = [...(await this.state.storage.list({ prefix: otpPrefix(b.deviceId) })).keys()];
        for (let i = 0; i < stale.length; i += STORAGE_BATCH) {
          await this.state.storage.delete(stale.slice(i, i + STORAGE_BATCH));
        }
        const puts: Record<string, unknown> = { [ikKey(b.deviceId)]: rec };
        for (const k of (b.oneTimePrekeys ?? []).slice(0, 200)) {
          puts[otpKey(b.deviceId, k.id)] = k.key;
        }
        await this.putBatched(puts);
        // peers holding a cached device set would keep building sessions on
        // the stale bundle; the bump makes them refetch
        const version = ((await this.state.storage.get<number>("devicesVersion")) ?? 1) + 1;
        await this.state.storage.put("devicesVersion", version);
        await this.broadcastDevicesChanged(version);
        return json({ ok: true, version });
      }

      // --- the address book: a set of phone hashes under `ct:<hash>`.
      // Contact-ness is answered against the peer's current hash at the
      // moment of the question, so a number registering or changing hands
      // needs no propagation into anyone's book.

      case "/contacts-sync": {
        const b = (await req.json()) as { hashes?: string[]; remove?: string[] };
        const hashes = [...new Set(b.hashes ?? [])].slice(0, CONTACTS_SYNC_MAX);
        const remove = [...new Set(b.remove ?? [])].slice(0, CONTACTS_SYNC_MAX);
        for (let i = 0; i < hashes.length; i += STORAGE_BATCH) {
          const batch: Record<string, number> = {};
          for (const hash of hashes.slice(i, i + STORAGE_BATCH)) batch[`ct:${hash}`] = 1;
          await this.state.storage.put(batch);
        }
        for (let i = 0; i < remove.length; i += STORAGE_BATCH) {
          await this.state.storage.delete(remove.slice(i, i + STORAGE_BATCH).map((h) => `ct:${h}`));
        }
        return json({ ok: true });
      }

      case "/contact-of": {
        const hash = url.searchParams.get("hash") ?? "";
        const held = hash !== "" &&
          (await this.state.storage.get(`ct:${hash}`)) !== undefined;
        return json({ ok: true, contact: held });
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

      case "/profile-changed": {
        // the card travels the same road as presence: out through every chat
        // this user is in, and to their own other devices
        // `peerUser` is the card as other users may see it: the worker blanks a
        // hidden photo and bio there, while the user's own devices get it whole
        const b = (await req.json()) as { user: PublicUser; peerUser?: PublicUser };
        const peerUser = b.peerUser ?? b.user;
        this.broadcast({ t: "profile", user: b.user });
        const ids = await this.chatIds();
        const results = await Promise.allSettled(
          ids.map(async (chatId) => {
            const res = await this.convStub(chatId).fetch("https://do/profile", {
              method: "POST",
              body: JSON.stringify({ userId: b.user.id, user: peerUser }),
            });
            if (!res.ok) throw new Error(`status ${res.status}`);
          })
        );
        results.forEach((r, i) => {
          if (r.status === "rejected") {
            console.warn(`profile of ${b.user.id} in ${ids[i]} failed: ${r.reason}`);
          }
        });
        return json({ ok: true });
      }

      default:
        return err("unknown_path", 404);
    }
  }

  /// A device was linked or revoked: whoever encrypts to this user must drop
  /// its cached device list. Out to this user's own other devices and through
  /// every chat they are in, the same road as the profile.
  private async broadcastDevicesChanged(version: number) {
    const userId = await this.getUserId();
    if (!userId) return;
    this.broadcast({ t: "devices", userId, version });
    const ids = await this.chatIds();
    const results = await Promise.allSettled(
      ids.map(async (chatId) => {
        const res = await this.convStub(chatId).fetch("https://do/devices", {
          method: "POST",
          body: JSON.stringify({ userId, version }),
        });
        if (!res.ok) throw new Error(`status ${res.status}`);
      })
    );
    results.forEach((r, i) => {
      if (r.status === "rejected") {
        console.warn(`devices of ${userId} in ${ids[i]} failed: ${r.reason}`);
      }
    });
  }

  /// storage.put in chunks of the 128-key batch limit.
  private async putBatched(entries: Record<string, unknown>) {
    const keys = Object.keys(entries);
    for (let i = 0; i < keys.length; i += STORAGE_BATCH) {
      const chunk: Record<string, unknown> = {};
      for (const k of keys.slice(i, i + STORAGE_BATCH)) chunk[k] = entries[k];
      await this.state.storage.put(chunk);
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

  /// Queues a push for the alarm loop and wakes it.
  private async enqueuePush(frame: PushJob) {
    const id = (await this.state.storage.get<number>("pqNext")) ?? 1;
    const job: PushJob = {
      chatId: frame.chatId, seq: frame.seq, sentAt: frame.sentAt,
      from: frame.from, fromDevice: frame.fromDevice, ts: frame.ts, body: frame.body,
    };
    await this.state.storage.put({ [pushKey(id)]: job, pqNext: id + 1 });
    await this.armAlarm(Date.now());
  }

  /// Sends the queued pushes oldest first, a bounded number per invocation,
  /// and asks to be woken again for the rest: at once when ready jobs remain,
  /// at the nearest deadline when the head of the queue is waiting one out.
  private async drainPushes() {
    const listed = await this.state.storage.list<PushJob>({
      prefix: PUSH_PREFIX,
      limit: PUSH_DRAIN + 1,
    });
    let sent = 0;
    let skippedReady = false;
    let nextWake: number | undefined;
    for (const [key, job] of listed) {
      if (sent >= PUSH_DRAIN) {
        skippedReady = true;
        break;
      }
      const wait = (job.nextAt ?? 0) - Date.now();
      if (wait > 0) {
        nextWake = nextWake === undefined ? job.nextAt! : Math.min(nextWake, job.nextAt!);
        continue;
      }
      const owed = await this.pushToDevices(job, job.pushed ?? []);
      sent++;
      if (!owed.length) {
        await this.state.storage.delete(key);
        continue;
      }
      const attempt = (job.attempt ?? 0) + 1;
      const retryMs = PUSH_RETRY_MS[Math.min(attempt - 1, PUSH_RETRY_MS.length - 1)];
      const nextAt = Date.now() + retryMs;
      const tokens =
        (await this.state.storage.get<Record<string, unknown>>("apns")) ?? {};
      const pushed = Object.keys(tokens).filter((d) => !owed.includes(d));
      await this.state.storage.put(key, { ...job, attempt, nextAt, pushed });
      nextWake = nextWake === undefined ? nextAt : Math.min(nextWake, nextAt);
    }
    if (skippedReady) await this.armAlarm(Date.now());
    else if (nextWake !== undefined) await this.armAlarm(nextWake);
  }

  /// The push carries the message itself, addressed to the device it goes to:
  /// the extension decrypts it and writes it, so the chat holds what the banner
  /// showed even if the socket never comes up. Returns the devices still owed
  /// their push — the ones that failed in transit and are worth another try. A
  /// refusal APNs actually pronounced is final: retrying the same payload buys
  /// nothing, and a dead token is dropped here.
  /// A single informational push to every device of this user (added to a
  /// group, and the like). No envelope, no seq; the badge stays at the current
  /// unread total. A dead token is dropped the same way the message path does.
  private async pushPlain(chatId: string, alert: { title: string; body: string }): Promise<void> {
    const tokens =
      (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    const devices = Object.entries(tokens);
    if (!devices.length) return;
    const badge = await this.totalUnread();
    const badgeStamp = await this.nextBadgeStamp();
    const results = await Promise.all(
      devices.map(async ([deviceId, t]) => {
        try {
          return { deviceId, res: await sendPush(this.env, t.token, t.env, {
            chatId, badge, badgeStamp, alert,
          }) };
        } catch (e) {
          console.warn(`plain push to device ${deviceId} for ${chatId} failed: ${String(e)}`);
          return { deviceId, res: null };
        }
      })
    );
    const dead = results.filter((r) => r.res?.dead).map((r) => r.deviceId);
    if (dead.length) await this.dropPushTokens(dead);
  }

  private async pushToDevices(frame: PushJob, skip: string[] = []): Promise<string[]> {
    const tokens =
      (await this.state.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    const devices = Object.entries(tokens).filter(([d]) => !skip.includes(d));
    if (!devices.length) return [];
    const badge = await this.totalUnread();
    const badgeStamp = await this.nextBadgeStamp();
    const userId = await this.getUserId();
    // the chat's own sound wins; then the sender's personal sound wherever
    // they write; then the user's default for the chat's shape
    const flags = await this.state.storage.get<ChatFlags>("chat:" + frame.chatId);
    const personal = frame.from
      ? await this.state.storage.get<string>(`usnd:${frame.from}`) : undefined;
    const defaults = (await this.state.storage.get<NotifySounds>("notifySounds")) ?? {};
    const sound = flags?.sound ?? personal ?? defaults[chatShape(frame.chatId)];
    // Every device is handled independently: one failure neither cancels the
    // others nor fails the frame delivery that already went over the socket.
    const results = await Promise.all(
      devices.map(async ([deviceId, t]) => {
        try {
          return {
            deviceId,
            res: await sendPush(this.env, t.token, t.env, {
              chatId: frame.chatId, seq: frame.seq, sound,
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
    // no response at all — the endpoint, not the push, was the problem
    return results
      .filter((r) => r.res === null || (!r.res.ok && r.res.status === 0))
      .map((r) => r.deviceId);
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
        scanned?: number; lastScannedSeq?: number | null; error?: string;
      };
      if (!r.ok) {
        // removed from the chat while the client was offline: it missed the live chat
        // frame and the journal is no longer served to it, so say so outright, otherwise
        // the chat would stay with it forever
        if (r.error === "not_member") this.send(ws, { t: "chat", chatId, event: "removed" });
        // the chat is gone: nothing to catch up on, and the cursor stays where it was
        this.send(ws, { t: "syncState", chatId, cursor: from, more: false });
        continue;
      }
      for (const m of r.msgs ?? []) {
        // tombstones travel as deleted frames in the tail below
        if (m.deleted) continue;
        this.send(ws, {
          t: "msg", chatId,
          seq: m.seq as number,
          from: m.from as string, fromDevice: m.fromDevice as string,
          // the author's own devices close their outbox row from the echo
          ...(m.clientMsgId ? { clientMsgId: m.clientMsgId as string } : {}),
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

  /// Roster, tombstones and read/delivered marks of a chat the client has caught
  /// up with: what happened to the chat itself and to already delivered messages
  /// while it was offline.
  private async sendChatTail(ws: WebSocket, userId: string, chatId: string) {
    const er = await this.convStub(chatId).fetch(`https://do/events?userId=${userId}`);
    const e = (await er.json()) as {
      ok: boolean;
      deleted?: Array<{ seq: number; by: string }>;
      readMarks?: Record<string, number>;
      deliveredMarks?: Record<string, number>;
      state?: unknown;
      users?: unknown[];
    };
    if (!e.ok) return;
    if (e.state) {
      this.send(ws, { t: "chat", chatId, event: "sync", state: e.state, users: e.users } as ServerFrame);
    }
    for (const d of e.deleted ?? []) {
      this.send(ws, { t: "deleted", chatId, seqs: [d.seq], forAll: true, by: d.by });
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
    if (!this.perf) return this.handleFrame(ws, raw);
    const t = (() => {
      try {
        return JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw)).t;
      } catch {
        return "?";
      }
    })();
    return this.measured(`ws:${t}`, () => this.handleFrame(ws, raw),
                         { inBytes: typeof raw === "string" ? raw.length : raw.byteLength });
  }

  private async handleFrame(ws: WebSocket, raw: string | ArrayBuffer) {
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
        await this.armPresenceCheck();
        if (!wasFresh) await this.broadcastPresence(true);
        return;
      }

      case "bg":
        ws.serializeAttachment({ ...att, lastPing: 0 } satisfies SocketAttachment);
        await this.broadcastPresence(false);
        return;

      case "fg": {
        ws.serializeAttachment({ ...att, lastPing: nowSec() } satisfies SocketAttachment);
        await this.armPresenceCheck();
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
            ...(frame.notify ? { notify: true } : {}),
          }),
        });
        const r = (await res.json()) as { ok: boolean; seq?: number; ts?: number; error?: string };
        if (r.ok && r.seq) {
          this.send(ws, {
            t: "sent", chatId: frame.chatId, clientMsgId: frame.clientMsgId,
            seq: r.seq, ts: r.ts!,
          });
        } else {
          this.send(ws, {
            t: "error", error: r.error ?? "send_failed",
            chatId: frame.chatId, clientMsgId: frame.clientMsgId,
          });
        }
        return;
      }

      case "defer": {
        const res = await this.convStub(frame.chatId).fetch("https://do/defer", {
          method: "POST",
          body: JSON.stringify({
            from: userId, fromDevice: att.deviceId,
            clientMsgId: frame.clientMsgId, sentAt: frame.sentAt,
            body: frame.body, dueAt: frame.dueAt,
          }),
        });
        const r = (await res.json()) as {
          ok: boolean; dueAt?: number; seq?: number; ts?: number; error?: string;
        };
        if (r.ok && r.seq) {
          // the journal already holds this clientMsgId: answer the way a resend is answered
          this.send(ws, {
            t: "sent", chatId: frame.chatId, clientMsgId: frame.clientMsgId,
            seq: r.seq, ts: r.ts!,
          });
        } else if (r.ok) {
          this.send(ws, {
            t: "deferred", chatId: frame.chatId, clientMsgId: frame.clientMsgId,
            dueAt: r.dueAt!,
          });
        } else {
          this.send(ws, {
            t: "error", error: r.error ?? "defer_failed",
            chatId: frame.chatId, clientMsgId: frame.clientMsgId,
          });
        }
        return;
      }

      case "deferCancel":
        await this.convStub(frame.chatId).fetch("https://do/defer-cancel", {
          method: "POST",
          body: JSON.stringify({ from: userId, clientMsgId: frame.clientMsgId }),
        });
        return;

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

      case "callRelay":
        await this.convStub(frame.chatId).fetch("https://do/call-relay", {
          method: "POST",
          body: JSON.stringify({ userId, deviceId: att.deviceId,
                                 sentAt: frame.sentAt, body: frame.body }),
        });
        return;

      case "delete":
        await this.convStub(frame.chatId).fetch("https://do/delete", {
          method: "POST",
          body: JSON.stringify({ userId, seqs: frame.seqs, forAll: frame.forAll }),
        });
        return;

      case "sync":
      case "catchup": {
        const cursors: Record<string, number> = { ...frame.cursors };
        if (frame.t === "sync" && frame.deviceVersions) {
          // the client's device cache survived the socket, its versions did
          // not: answer with the current ones before the catch-up, so the
          // entries still current are trusted again as early as possible.
          // Each version lives in its user's own object; a user no object
          // knows is left out of the answer, which reads as stale.
          const ids = Object.keys(frame.deviceVersions).slice(0, 200);
          if (ids.length) {
            const versions: Record<string, number> = {};
            await Promise.all(ids.map(async (id) => {
              try {
                let v: number | null;
                if (id === userId) {
                  // own object: read storage directly, a self-fetch has no answer
                  v = (await this.state.storage.get<number>("devicesVersion")) ?? null;
                } else {
                  const r = await this.userStub(id).fetch("https://do/keys-version");
                  v = ((await r.json()) as { version: number | null }).version;
                }
                if (v !== null) versions[id] = v;
              } catch (e) {
                console.warn(`devices version of ${id} unavailable: ${String(e)}`);
              }
            }));
            this.send(ws, { t: "deviceVersions", versions });
          }
        }
        if (frame.t === "sync") {
          // chats the client does not know yet, created or joined while it was offline:
          // send the state and replay the history from zero
          const known = new Set(Object.keys(frame.cursors));
          const listed = await this.state.storage.list<unknown>({ prefix: "chat:" });
          for (const key of listed.keys()) {
            const chatId = key.slice(5);
            if (known.has(chatId)) continue;
            const sr = await this.convStub(chatId).fetch("https://do/state");
            const sj = (await sr.json()) as { ok: boolean; state?: unknown; users?: unknown[] };
            if (sj.ok && sj.state) {
              this.send(ws, { t: "chat", chatId, event: "sync", state: sj.state, users: sj.users } as ServerFrame);
              cursors[chatId] = 0; // history replayed below
            }
          }
        }
        await this.serveCatchup(ws, userId, cursors);
        return;
      }
    }
  }

  /// One alarm serves two queues: pushes owed, and the presence TTL — silence
  /// past it means offline, however open the socket still looks. The stored
  /// deadline tells the check apart from a push wake-up, so a push arriving
  /// while the user is offline does not re-broadcast the offline.
  async alarm() {
    this.alarmRunning = true;
    this.rearmAt = undefined;
    try {
      await this.drainPushes();
      const checkAt = await this.state.storage.get<number>("presenceCheckAt");
      if (checkAt !== undefined) {
        if (Date.now() >= checkAt) {
          if (this.presenceFresh()) {
            await this.armPresenceCheck();
          } else {
            await this.state.storage.delete("presenceCheckAt");
            await this.broadcastPresence(false);
          }
        } else {
          await this.armAlarm(checkAt);
        }
      }
    } finally {
      this.alarmRunning = false;
      if (this.rearmAt !== undefined) {
        const at = this.rearmAt;
        this.rearmAt = undefined;
        await this.armAlarm(at);
      }
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
