import { DurableObject } from "cloudflare:workers";
import type {
  Env, ClientFrame, ServerFrame, PublicUser, PrivacySettings, LastSeenVisibility, StoryItem,
} from "../types";
import type { StoryDelivery } from "./StoriesDO";
import { DELETE_SEQS_PER_CALL } from "./ConversationDO";
import {
  DOError, nowSec, shouldArmAlarm, ulid, PRIVACY_DEFAULTS, type PrivacySetting,
} from "../util";
import { sendPush, envelopeForDevice } from "../push/apns";
import { PROTOCOL_VERSION, MIN_CLIENT_PROTOCOL } from "../version";
import {
  newCounters, snapshot, diff, logPerf, wrapState, wrapStub, type PerfCounters,
} from "../perf";

/// Presence travels by subscription between user objects. Every chat a user is
/// in makes them and each other member watch one another: `sub:<S>` holds the
/// chats through which S watches this user, `watch:<T>` the chats through which
/// this user watches T, and `peer:<T>` this user's copy of T's presence, as T
/// lets them see it. The source decides what a subscriber may see — whether it
/// has accepted the chat (`acc:<chatId>` marks a direct request still open),
/// blocks, its last-seen tier and exceptions — and pushes a snapshot when the
/// relation starts and a delta on every change; the subscriber holds the copy
/// and answers its client from it, so a peer's presence costs the client's
/// request no call to anyone else's object.
const SUB_PREFIX = "sub:";
const WATCH_PREFIX = "watch:";
const PEER_PREFIX = "peer:";
/// `story:<storyId>`: a live story delivered to this user, as their list shows it.
const STORY_PREFIX = "story:";
/// `name:<userId>`: the public display name of somebody this user shares a
/// chat with, as the roster frame carried it; a push names its author by it.
/// Every chat fills it, however large the roster.
const NAME_PREFIX = "name:";
/// `pcard:<T>`: this user's copy of T's card, as T decided this one subscriber
/// may see it — the photo and the bio are in it only while T's avatar rule
/// says so. A chat list is answered out of these copies and calls nobody.
const PCARD_PREFIX = "pcard:";
const ACC_PREFIX = "acc:";
/// Chats through which one user watches another, keyed by chat id.
type Reasons = Record<string, true>;
interface PeerPresence {
  online: boolean;
  lastSeen: number;
  /// The source's flip counter (`presenceStamp`). Two flips in one second
  /// travel as two pushes that can land in either order; the subscriber keeps
  /// the higher stamp and drops the rest.
  stamp: number;
}
/// Presence pushes in flight at once from one object.
const PRESENCE_FAN = 20;

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
  // the app behind this socket said it went to the background: its pings keep
  // the socket alive but do not read as online until it says `fg`
  bg?: boolean;
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

/// The person, as opposed to their keys and their chats: the card everyone
/// else reads, the sessions that may speak for the account, who they will not
/// hear from, and what they let anyone see.
///
/// `dev:<deviceId>` is a session; `tok:<sha256(token)>` points at the session
/// a bearer token belongs to, which is the whole of authentication — a token
/// names its own account, so the lookup is inside the object that owns the
/// answer. A revoked device loses both records at once.
const DEV_PREFIX = "dev:";
const TOKEN_PREFIX = "tok:";
/// `blk:<peerId>`: this user blocked them. `blkby:<peerId>`: they blocked this
/// user — written by the blocker's object, so either side answers for the pair
/// without asking the other.
const BLOCK_PREFIX = "blk:";
const BLOCKED_BY_PREFIX = "blkby:";
/// `pex:<setting>:<peerId>`: a named override of one privacy tier, 1 or 0.
const PEX_PREFIX = "pex:";
/// `rep:<ulid>`: a report this user filed.
const REPORT_PREFIX = "rep:";
/// `bot:<botId>`: a bot account this user runs.
const BOT_PREFIX = "bot:";

/// The card of the account plus what only the account itself may read.
interface Profile extends PublicUser {
  phone_hash: string | null;
  created_at: number;
}

interface DeviceRecord {
  name: string | null;
  tokenHash: string;
  createdAt: number;
  lastSeen: number | null;
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
  /// the chat was muted when the frame arrived: the push travels silent and
  /// says so, and the device decides what a mention or a reply still shows
  muted?: boolean;
}

// One object per user: the sockets of all their devices, the chat list, presence, pushes.
export class UserDO extends DurableObject<Env> {
  private userId: string | null = null;
  /// Dev test hook (devFault): how many frame deliveries to reject next.
  private devFailEvents = 0;
  /// True while alarm() runs. setAlarm during a running alarm handler cancels
  /// the handler mid-await (workerd), so while it runs, arming requests
  /// collect here and the handler arms the nearest one as it leaves.
  private alarmRunning = false;
  private rearmAt: number | undefined;

  /// dev measurement (PERF_LOG); never installed otherwise
  private perf: PerfCounters | null = null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    if (env.PERF_LOG) {
      this.perf = newCounters();
      this.ctx = wrapState(this.ctx, this.perf);
    }
  }

  private async getUserId(): Promise<string | null> {
    if (!this.userId) this.userId = (await this.ctx.storage.get<string>("userId")) ?? null;
    return this.userId;
  }

  private convStub(chatId: string) {
    const stub = this.env.CONV_DO.get(this.env.CONV_DO.idFromName(chatId));
    return wrapStub(stub, this.perf);
  }

  private userStub(userId: string) {
    const stub = this.env.USER_DO.get(this.env.USER_DO.idFromName(userId));
    return wrapStub(stub, this.perf);
  }

  /// Wraps one invocation (an RPC call or a client frame) in a PERF line.
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
    return this.ctx.getWebSockets();
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
    const pending = await this.ctx.storage.getAlarm();
    if (!shouldArmAlarm(pending, at, now)) return;
    await this.ctx.storage.setAlarm(at);
  }

  /// Schedules the freshness check the presence TTL asks for. The deadline is
  /// stored because the alarm is shared: an alarm firing early for a push must
  /// not read as the TTL running out.
  private async armPresenceCheck() {
    const at = Date.now() + PRESENCE_TTL_MS;
    await this.ctx.storage.put("presenceCheckAt", at);
    await this.armAlarm(at);
  }

  /// Lifts a mute whose deadline has passed and returns the chat's current flags.
  private async clearExpiredMute(chatId: string): Promise<ChatFlags | undefined> {
    const key = "chat:" + chatId;
    const flags = await this.ctx.storage.get<ChatFlags>(key);
    if (!muteExpired(flags, nowSec())) return flags;
    flags!.muted = false;
    delete flags!.mutedUntil;
    await this.ctx.storage.put(key, flags!);
    return flags;
  }

  /// Puts a chat back on the list with default flags when it is not there.
  private async relistChat(chatId: string) {
    const key = "chat:" + chatId;
    if (await this.ctx.storage.get<ChatFlags>(key)) return;
    await this.ctx.storage.put(key, {
      pinned: false, muted: false, archived: false, joinedAt: nowSec(),
    } satisfies ChatFlags);
  }

  /// The inbox of stories delivered to this user, oldest first; the ones
  /// whose time is over go out of it as they are met. The inbox is bounded by
  /// the peers' output over a week, and the list is capped past that.
  private async storiesInboxList(): Promise<StoryItem[]> {
    const listed = await this.ctx.storage.list<StoryItem>({ prefix: STORY_PREFIX, limit: 2000 });
    const now = Date.now();
    const stories: StoryItem[] = [];
    const expired: string[] = [];
    for (const [k, item] of listed) {
      if (item.expiresAt <= now) expired.push(k); else stories.push(item);
    }
    // one storage delete takes at most 128 keys
    for (let i = 0; i < expired.length; i += 128) {
      await this.ctx.storage.delete(expired.slice(i, i + 128));
    }
    stories.sort((a, b) => a.createdAt - b.createdAt);
    return stories;
  }

  private async chatIds(): Promise<string[]> {
    const listed = await this.ctx.storage.list<ChatFlags>({ prefix: "chat:" });
    return [...listed.keys()].map((k) => k.slice(5));
  }

  /// A presence flip: the new state goes to every subscriber allowed to see it.
  private async broadcastPresence(online: boolean) {
    const lastSeen = nowSec();
    const stamp = ((await this.ctx.storage.get<number>("presenceStamp")) ?? 0) + 1;
    await this.ctx.storage.put({ lastSeen, presenceStamp: stamp });
    await this.pushPresence(await this.subscribers(), { online, lastSeen, stamp });
  }

  private async subscribers(): Promise<string[]> {
    const listed = await this.ctx.storage.list<Reasons>({ prefix: SUB_PREFIX });
    return [...listed.keys()].map((k) => k.slice(SUB_PREFIX.length));
  }

  private async ownPresence(): Promise<PeerPresence> {
    const got = await this.ctx.storage.get<number>(["lastSeen", "presenceStamp"]);
    return {
      online: this.presenceFresh(),
      lastSeen: got.get("lastSeen") ?? 0,
      stamp: got.get("presenceStamp") ?? 0,
    };
  }

  /// The subscribers among `ids` this user's presence may reach: the chats
  /// they share include one this user has accepted, and the privacy rules
  /// let them see it.
  private async visibleSubscribers(ids: string[]): Promise<Set<string>> {
    const userId = await this.getUserId();
    if (!userId || !ids.length) return new Set();
    const open = await this.ctx.storage.list<true>({ prefix: ACC_PREFIX });
    const openChats = new Set([...open.keys()].map((k) => k.slice(ACC_PREFIX.length)));
    const candidates: string[] = [];
    for (const id of ids) {
      const reasons = await this.ctx.storage.get<Reasons>(SUB_PREFIX + id);
      if (reasons && Object.keys(reasons).some((chatId) => !openChats.has(chatId))) candidates.push(id);
    }
    // the last-seen rule, blocks in either direction and the address book are
    // all this object's own storage, so the whole judgement is local. The other
    // half of the rule — hiding your own last seen blinds you to everyone
    // else's — is enforced where it costs nothing, at the subscriber taking
    // the copy in
    const privacy = await this.privacy();
    const out = new Set<string>();
    for (const v of candidates) {
      if (v === userId) continue;
      const { byMe, byPeer } = await this.blockPairInternal(v);
      if (byMe || byPeer) continue;
      if (await this.mayView(v, "last_seen", privacy)) out.add(v);
    }
    return out;
  }

  /// Which of the phone hashes are in this user's address book.
  private async inBook(hashes: string[]): Promise<Set<string>> {
    const held = new Set<string>();
    for (let i = 0; i < hashes.length; i += STORAGE_BATCH) {
      const part = hashes.slice(i, i + STORAGE_BATCH);
      const got = await this.ctx.storage.get(part.map((h) => `ct:${h}`));
      for (const h of part) if (got.has(`ct:${h}`)) held.add(h);
    }
    return held;
  }

  private async privacy(): Promise<PrivacySettings> {
    return (await this.ctx.storage.get<PrivacySettings>("privacy")) ?? PRIVACY_DEFAULTS;
  }

  /// The tier a setting is governed by.
  private tierOf(p: PrivacySettings, setting: PrivacySetting): LastSeenVisibility {
    switch (setting) {
      case "last_seen": return p.lastSeen;
      case "avatar": return p.avatar;
      case "phone_discovery": return p.phoneDiscovery;
      case "group_invites": return p.groupInvites;
      case "call": return p.callPrivacy;
    }
  }

  /// The phone hash another account currently publishes, read from its own
  /// object: "contacts" is answered against the number a person holds now, so
  /// a number registering or changing hands needs no propagation.
  private async peerPhoneHash(userId: string): Promise<string | null> {
    try {
      return (await this.userStub(userId).phoneHash()).phoneHash;
    } catch (e) {
      console.warn(`phone hash of ${userId} failed: ${e}`);
      return null;
    }
  }

  /// May `viewerId` see this user's `setting`? A named exception decides
  /// first, whichever way it points; then the tier — everyone, the address
  /// book, nobody.
  private async mayView(
    viewerId: string, setting: PrivacySetting, privacy?: PrivacySettings,
  ): Promise<boolean> {
    const self = await this.getUserId();
    if (viewerId === self) return true;
    const exception = await this.ctx.storage.get<number>(`${PEX_PREFIX}${setting}:${viewerId}`);
    if (exception !== undefined) return exception === 1;
    const tier = this.tierOf(privacy ?? (await this.privacy()), setting);
    if (tier === "everyone") return true;
    if (tier === "nobody") return false;
    const hash = await this.peerPhoneHash(viewerId);
    return hash !== null && (await this.inBook([hash])).has(hash);
  }

  /// This user's card as `viewerId` may see it: the photo and the bio go only
  /// as far as the avatar rule lets them.
  private async cardForInternal(viewerId: string): Promise<PublicUser | null> {
    const p = await this.ctx.storage.get<Profile>("profile");
    if (!p) return null;
    const card: PublicUser = {
      id: p.id, username: p.username, display_name: p.display_name,
      bio: p.bio, avatar_id: p.avatar_id,
      bot_owner: p.bot_owner ?? null, bot_commands: p.bot_commands ?? null,
    };
    if (await this.mayView(viewerId, "avatar")) return card;
    return { ...card, bio: null, avatar_id: null };
  }

  /// Whether a block stands between this user and `peer`, either way.
  private async blockPairInternal(peer: string): Promise<{ byMe: boolean; byPeer: boolean }> {
    const got = await this.ctx.storage.get([BLOCK_PREFIX + peer, BLOCKED_BY_PREFIX + peer]);
    return {
      byMe: got.get(BLOCK_PREFIX + peer) !== undefined,
      byPeer: got.get(BLOCKED_BY_PREFIX + peer) !== undefined,
    };
  }

  /// Pushes this user's presence to the subscribers in `ids` who may see it.
  /// With `dropHidden` the rest are told to forget the copy they hold — for a
  /// change that can take a presence away, such as a tighter tier.
  private async pushPresence(
    ids: string[], presence?: PeerPresence, dropHidden = false,
  ) {
    const userId = await this.getUserId();
    if (!userId || !ids.length) return;
    const p = presence ?? await this.ownPresence();
    const visible = await this.visibleSubscribers(ids);
    const calls: Array<() => Promise<void>> = [];
    for (const id of ids) {
      if (visible.has(id)) {
        calls.push(() => this.tellPeerPresence(id, userId, p));
      } else if (dropHidden) {
        calls.push(() => this.tellPeerDrop(id, userId));
      }
    }
    for (let i = 0; i < calls.length; i += PRESENCE_FAN) {
      await Promise.all(calls.slice(i, i + PRESENCE_FAN).map((c) => c()));
    }
  }

  /// Hands this user's card to each of `ids`, each seeing what this user's own
  /// avatar rule lets them see. A subscriber holds the copy until it is
  /// replaced, so their chat list asks nobody.
  private async pushCards(ids: string[]) {
    const userId = await this.getUserId();
    if (!userId || !ids.length) return;
    if (!(await this.ctx.storage.get<Profile>("profile"))) return;
    for (let i = 0; i < ids.length; i += PRESENCE_FAN) {
      await Promise.all(ids.slice(i, i + PRESENCE_FAN).map(async (id) => {
        const card = await this.cardForInternal(id);
        if (card) await this.tellPeerCard(id, userId, card);
      }));
    }
  }

  /// One call to another user's object; a failure is logged and not retried —
  /// a lost presence is superseded by the next flip.
  private async tellPeerPresence(userId: string, from: string, p: PeerPresence) {
    try {
      await this.userStub(userId).peerPresence(from, p.online, p.lastSeen, p.stamp);
    } catch (e) {
      console.warn(`peerPresence to ${userId} failed: ${e}`);
    }
  }

  private async tellPeerDrop(userId: string, from: string) {
    try {
      await this.userStub(userId).peerDrop(from);
    } catch (e) {
      console.warn(`peerDrop to ${userId} failed: ${e}`);
    }
  }

  private async tellPeerCard(userId: string, from: string, card: PublicUser) {
    try {
      await this.userStub(userId).peerCard(from, card);
    } catch (e) {
      console.warn(`peerCard to ${userId} failed: ${e}`);
    }
  }

  private async tellPeerRefresh(userId: string, subscriber: string) {
    try {
      await this.userStub(userId).peerRefresh(subscriber);
    } catch (e) {
      console.warn(`peerRefresh to ${userId} failed: ${e}`);
    }
  }

  private async tellPeerGone(userId: string, from: string) {
    try {
      await this.userStub(userId).peerGone(from);
    } catch (e) {
      console.warn(`peerGone to ${userId} failed: ${e}`);
    }
  }

  /// Adds `chatId` to the relation with each of `peers`, both ways.
  private async relate(chatId: string, peers: string[]) {
    for (let i = 0; i < peers.length; i += STORAGE_BATCH / 2) {
      const part = peers.slice(i, i + STORAGE_BATCH / 2);
      const keys = part.flatMap((p) => [WATCH_PREFIX + p, SUB_PREFIX + p]);
      const got = await this.ctx.storage.get<Reasons>(keys);
      const put: Record<string, Reasons> = {};
      for (const k of keys) put[k] = { ...(got.get(k) ?? {}), [chatId]: true };
      await this.ctx.storage.put(put);
    }
  }

  /// Takes `chatId` out of the relation with each of `peers`; a relation left
  /// with no chat goes, and with it the copy of that peer's presence.
  private async unrelate(chatId: string, peers: string[]) {
    for (let i = 0; i < peers.length; i += STORAGE_BATCH / 2) {
      const part = peers.slice(i, i + STORAGE_BATCH / 2);
      const keys = part.flatMap((p) => [WATCH_PREFIX + p, SUB_PREFIX + p]);
      const got = await this.ctx.storage.get<Reasons>(keys);
      const put: Record<string, Reasons> = {};
      const del: string[] = [];
      for (const p of part) {
        for (const k of [WATCH_PREFIX + p, SUB_PREFIX + p]) {
          const reasons = { ...(got.get(k) ?? {}) };
          delete reasons[chatId];
          if (Object.keys(reasons).length) put[k] = reasons;
          else {
            del.push(k);
            if (k.startsWith(WATCH_PREFIX)) del.push(PEER_PREFIX + p, PCARD_PREFIX + p);
          }
        }
      }
      if (Object.keys(put).length) await this.ctx.storage.put(put);
      // a peer losing its last link frees up to four keys, so `del` outgrows
      // the batch limit before `part` does
      for (let j = 0; j < del.length; j += STORAGE_BATCH) {
        await this.ctx.storage.delete(del.slice(j, j + STORAGE_BATCH));
      }
    }
  }

  /// The subscribers who watch this user through `chatId`.
  private async subscribersVia(chatId: string): Promise<string[]> {
    const listed = await this.ctx.storage.list<Reasons>({ prefix: SUB_PREFIX });
    return [...listed].filter(([, r]) => r[chatId]).map(([k]) => k.slice(SUB_PREFIX.length));
  }

  /// Every presence copy this user holds, as frames for a socket that just
  /// connected: the client's picture of who is online starts full.
  private async sendPeerPresence(ws: WebSocket) {
    const listed = await this.ctx.storage.list<PeerPresence>({ prefix: PEER_PREFIX });
    for (const [k, p] of listed) {
      this.send(ws, { t: "presence", userId: k.slice(PEER_PREFIX.length), online: p.online, lastSeen: p.lastSeen });
    }
  }

  /// The WebSocket upgrade: the one path that cannot be an RPC method.
  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== "/ws") return new Response("not_found", { status: 404 });

    const userId = req.headers.get("x-user-id")!;
    const deviceId = req.headers.get("x-device-id")!;
    await this.ctx.storage.put("userId", userId);
    this.userId = userId;
    // the session list shows when each device was last here, and this is
    // when: the connection is the device saying so
    const rec = await this.ctx.storage.get<DeviceRecord>(DEV_PREFIX + deviceId);
    if (rec) {
      rec.lastSeen = Date.now();
      await this.ctx.storage.put(DEV_PREFIX + deviceId, rec);
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ deviceId, lastPing: nowSec() } satisfies SocketAttachment);
    // the handshake names both bounds: what this server speaks and how far
    // down it still serves
    this.send(server, {
      t: "hello", serverTime: nowSec(),
      protocol: PROTOCOL_VERSION, minProtocol: MIN_CLIENT_PROTOCOL,
    });

    await this.sendPeerPresence(server);
    await this.armPresenceCheck();
    if (this.sockets().length === 1) {
      await this.broadcastPresence(true);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  // MARK: - RPC surface

  async event(frame: ServerFrame): Promise<{ dupe?: boolean }> {
    return this.measured("event", () => this.eventInternal(frame));
  }

  private async eventInternal(frame: ServerFrame): Promise<{ dupe?: boolean }> {
    if (this.devFailEvents > 0) {
      this.devFailEvents--;
      throw new DOError("dev_fault", 500);
    }
    // The delivery is idempotent: the chat's seq orders its msg frames and
    // they arrive per chat in order, so anything at or below the mark has
    // been applied already — a retry of a delivery that in fact succeeded
    // is answered "already have it", and never costs a second push.
    // Receipts and marks are monotonic and chat/presence frames are
    // snapshots, so they need no mark.
    let inboxKey: string | undefined;
    if (frame.t === "msg" && typeof frame.seq === "number") {
      inboxKey = "in:" + frame.chatId;
      const applied = (await this.ctx.storage.get<number>(inboxKey)) ?? 0;
      if (frame.seq <= applied) return { dupe: true };
    }
    for (const ws of this.sockets()) this.send(ws, frame);
    if (frame.t === "chat" && frame.users?.length) {
      // the roster's public names, kept for the pushes of these people:
      // a push names its author for a device that has no row for them yet
      const names: Record<string, string> = {};
      for (const u of frame.users) names[NAME_PREFIX + u.id] = u.display_name;
      await this.putBatched(names);
    }
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
      // acknowledged now, and APNs' latency paces no chat. A muted chat
      // pushes too, silent and flagged: the server cannot see a mention
      // or a reply in the encrypted text, so the extension is the one
      // that lets those through and swallows the rest
      if (!isOwnEcho) {
        await this.enqueuePush({ ...frame, muted });
      }
    } else if (frame.t === "msg" && frame.service && (frame.notify || frame.notifyUser)) {
      // a service frame that still notifies — a missed-call record for
      // everyone, a reaction for the author of the message it landed on:
      // the push goes out, but the chat is not relisted and unread stays put
      const flags = await this.clearExpiredMute(frame.chatId);
      const muted = muteActive(flags, nowSec());
      const userId = await this.getUserId();
      const isOwnEcho = userId !== null && frame.from === userId;
      const addressed = frame.notify || frame.notifyUser === userId;
      if (!muted && !isOwnEcho && addressed) {
        await this.enqueuePush(frame);
      }
    }
    if (inboxKey && frame.t === "msg") {
      await this.ctx.storage.put(inboxKey, frame.seq);
    }
    return {};
  }

  /// From ConversationDO: this user is in the chat. `peers` are the other
  /// members, who watch this user from now on and are watched back;
  /// `accepted: false` is a direct request still to be accepted, which
  /// withholds this user's presence from the one who sent it.
  async chatAdded(chatId: string, accepted?: boolean, peers?: string[]): Promise<void> {
    const existing = await this.ctx.storage.get<ChatFlags>("chat:" + chatId);
    if (!existing) {
      await this.ctx.storage.put("chat:" + chatId, {
        pinned: false, muted: false, archived: false, joinedAt: nowSec(),
      } satisfies ChatFlags);
    }
    if (accepted === false) await this.ctx.storage.put(ACC_PREFIX + chatId, true);
    const self = await this.getUserId();
    const relatedPeers = (peers ?? []).filter((p) => p !== self);
    if (relatedPeers.length) {
      await this.relate(chatId, relatedPeers);
      await this.pushPresence(relatedPeers);
      await this.pushCards(relatedPeers);
    }
  }

  async chatRemoved(chatId: string, peers?: string[]): Promise<void> {
    await this.ctx.storage.delete(["chat:" + chatId, ACC_PREFIX + chatId]);
    // the badge sums the listed chats, and a count left in the cache would
    // be counted again the day the chat comes back
    await this.invalidateUnread(chatId);
    if (peers?.length) await this.unrelate(chatId, peers);
  }

  /// From ConversationDO: the roster of a chat this user stays in moved.
  async peersChanged(chatId: string, added?: string[], removed?: string[]): Promise<void> {
    if (removed?.length) await this.unrelate(chatId, removed);
    if (added?.length) {
      await this.relate(chatId, added);
      await this.pushPresence(added);
      await this.pushCards(added);
    }
  }

  /// This user accepted a direct request: the sender may see them now.
  async chatAccepted(chatId: string): Promise<void> {
    await this.ctx.storage.delete(ACC_PREFIX + chatId);
    await this.pushPresence(await this.subscribersVia(chatId));
  }

  /// From a source this user watches: its presence, as it lets this user
  /// see it. Kept even before this object's own roster call has landed —
  /// a chat's members are told at once, and the source's snapshot can
  /// arrive first.
  async peerPresence(userId: string, online: boolean, lastSeen: number, stamp: number): Promise<void> {
    // hiding your own last seen blinds you to everyone else's: the copy is
    // refused here rather than filtered at every source
    if ((await this.privacy()).lastSeen === "nobody") return;
    const held = await this.ctx.storage.get<PeerPresence>(PEER_PREFIX + userId);
    if (held && held.stamp > stamp) return;
    await this.ctx.storage.put(PEER_PREFIX + userId, { online, lastSeen, stamp } satisfies PeerPresence);
    this.broadcast({ t: "presence", userId, online, lastSeen });
  }

  /// From a source this user watches: its card, as it lets this user see
  /// it. The chat list is answered out of these copies.
  async peerCard(userId: string, card: PublicUser): Promise<void> {
    await this.ctx.storage.put({
      [PCARD_PREFIX + userId]: card,
      // the name a push writes is the same name: a rename reaches it here
      // rather than waiting for the next roster frame
      [NAME_PREFIX + userId]: card.display_name,
    });
  }

  /// Every card copy this user holds, for the chat list.
  async peerCards(): Promise<{ cards: PublicUser[] }> {
    const listed = await this.ctx.storage.list<PublicUser>({ prefix: PCARD_PREFIX });
    return { cards: [...listed.values()] };
  }

  /// A source took its presence away from this user: the copy goes.
  async peerDrop(userId: string): Promise<void> {
    await this.ctx.storage.delete(PEER_PREFIX + userId);
  }

  async peerPresenceRead(peer: string): Promise<{ presence: PeerPresence | null }> {
    const p = await this.ctx.storage.get<PeerPresence>(PEER_PREFIX + peer);
    return { presence: p ?? null };
  }

  /// The last-seen tier or one of its exceptions changed: every subscriber
  /// is pushed the presence or told to forget it.
  async presencePolicyChanged(): Promise<void> {
    await this.pushPresence(await this.subscribers(), undefined, true);
    // and the other half of the rule: a user who has just hidden their own
    // last seen holds no more copies, and one who stopped hiding it asks
    // for the copies back
    const self = await this.getUserId();
    const watched = await this.ctx.storage.list<Reasons>({ prefix: WATCH_PREFIX });
    const peers = [...watched.keys()].map((k) => k.slice(WATCH_PREFIX.length));
    if ((await this.privacy()).lastSeen === "nobody") {
      for (let i = 0; i < peers.length; i += STORAGE_BATCH) {
        await this.ctx.storage.delete(
          peers.slice(i, i + STORAGE_BATCH).map((p) => PEER_PREFIX + p));
      }
    } else if (self) {
      for (let i = 0; i < peers.length; i += PRESENCE_FAN) {
        await Promise.all(peers.slice(i, i + PRESENCE_FAN).map(
          (p) => this.tellPeerRefresh(p, self)));
      }
    }
  }

  async peerRefresh(subscriber: string): Promise<void> {
    await this.pushPresence([subscriber]);
    await this.pushCards([subscriber]);
  }

  /// An account this user was related to is deleted.
  async peerGone(userId: string): Promise<void> {
    await this.ctx.storage.delete([
      SUB_PREFIX + userId, WATCH_PREFIX + userId, PEER_PREFIX + userId,
      PCARD_PREFIX + userId, BLOCK_PREFIX + userId, BLOCKED_BY_PREFIX + userId,
    ]);
  }

  async chats(): Promise<{ chats: Record<string, ChatFlags> }> {
    const listed = await this.ctx.storage.list<ChatFlags>({ prefix: "chat:" });
    const now = nowSec();
    const out: Record<string, ChatFlags> = {};
    for (const [k, v] of listed) {
      const chatId = k.slice(5);
      out[chatId] = muteExpired(v, now)
        ? (await this.clearExpiredMute(chatId)) ?? v
        : v;
    }
    return { chats: out };
  }

  async flagsRead(chatId: string): Promise<{ flags: ChatFlags }> {
    const flags = await this.ctx.storage.get<ChatFlags>("chat:" + chatId);
    if (!flags) throw new DOError("chat_not_found", 404);
    return { flags };
  }

  async flags(b: {
    chatId: string; pinned?: boolean; muted?: boolean;
    mutedUntil?: number | null; archived?: boolean; sound?: string | null;
  }): Promise<void> {
    const key = "chat:" + b.chatId;
    const flags = await this.ctx.storage.get<ChatFlags>(key);
    if (!flags) throw new DOError("chat_not_found", 404);
    if (b.sound !== undefined) {
      if (b.sound === null || b.sound === "default") delete flags.sound;
      else if (SOUND_NAME.test(b.sound)) flags.sound = b.sound;
      else throw new DOError("bad_sound");
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
    await this.ctx.storage.put(key, flags);
  }

  async personSound(userId: string, sound?: string | null, read?: boolean): Promise<{ sound?: string | null }> {
    if (read) {
      const s = await this.ctx.storage.get<string>(`usnd:${userId}`);
      return { sound: s ?? null };
    }
    if (sound === null || sound === undefined || sound === "default") {
      await this.ctx.storage.delete(`usnd:${userId}`);
    } else if (SOUND_NAME.test(sound)) {
      await this.ctx.storage.put(`usnd:${userId}`, sound);
    } else {
      throw new DOError("bad_sound");
    }
    return {};
  }

  async notifySoundsRead(): Promise<{ sounds: NotifySounds }> {
    const sounds = (await this.ctx.storage.get<NotifySounds>("notifySounds")) ?? {};
    return { sounds };
  }

  async notifySoundsWrite(b: { direct?: string | null; group?: string | null }): Promise<{ sounds: NotifySounds }> {
    const sounds = (await this.ctx.storage.get<NotifySounds>("notifySounds")) ?? {};
    for (const shape of ["direct", "group"] as const) {
      const v = b[shape];
      if (v === undefined) continue;
      if (v === null || v === "default") delete sounds[shape];
      else if (SOUND_NAME.test(v)) sounds[shape] = v;
      else throw new DOError("bad_sound");
    }
    await this.ctx.storage.put("notifySounds", sounds);
    return { sounds };
  }

  /// The account is being deleted: close every socket and erase the
  /// object whole — keys, chat flags, sounds, the address book, tokens.
  async accountWipe(): Promise<void> {
    for (const ws of this.sockets()) {
      try { ws.close(1000, "account_deleted"); } catch { /* already gone */ }
    }
    // whoever watched this user, or was watched by them, drops the relation
    const userId = await this.getUserId();
    if (userId) {
      const watched = await this.ctx.storage.list<Reasons>({ prefix: WATCH_PREFIX });
      const blocked = await this.ctx.storage.list({ prefix: BLOCK_PREFIX });
      const blockedBy = await this.ctx.storage.list({ prefix: BLOCKED_BY_PREFIX });
      const related = new Set([
        ...(await this.subscribers()),
        ...[...watched.keys()].map((k) => k.slice(WATCH_PREFIX.length)),
        ...[...blocked.keys()].map((k) => k.slice(BLOCK_PREFIX.length)),
        ...[...blockedBy.keys()].map((k) => k.slice(BLOCKED_BY_PREFIX.length)),
      ]);
      const calls = [...related].map((id) => () => this.tellPeerGone(id, userId));
      for (let i = 0; i < calls.length; i += PRESENCE_FAN) {
        await Promise.all(calls.slice(i, i + PRESENCE_FAN).map((c) => c()));
      }
    }
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
    this.userId = null;
  }

  async soundExceptions(): Promise<{
    chats: Array<{ chatId: string; sound: string }>;
    people: Array<{ userId: string; sound: string }>;
  }> {
    const chats: { chatId: string; sound: string }[] = [];
    for (const [k, v] of await this.ctx.storage.list<ChatFlags>({ prefix: "chat:" })) {
      if (v.sound) chats.push({ chatId: k.slice("chat:".length), sound: v.sound });
    }
    const people: { userId: string; sound: string }[] = [];
    for (const [k, v] of await this.ctx.storage.list<string>({ prefix: "usnd:" })) {
      people.push({ userId: k.slice("usnd:".length), sound: v });
    }
    return { chats, people };
  }

  async pushToken(deviceId: string, apnsToken: string, env: string, userId?: string): Promise<void> {
    // unreadCount needs the userId even before the first WS connection
    if (userId) {
      await this.ctx.storage.put("userId", userId);
      this.userId = userId;
    }
    const tokens =
      (await this.ctx.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    tokens[deviceId] = { token: apnsToken, env };
    await this.ctx.storage.put("apns", tokens);
  }

  /// A push that is not a chat message: it carries a ready alert, no
  /// envelope, and leaves the badge at the current unread total.
  async notifyPlain(chatId: string, title: string, body: string, userId?: string): Promise<void> {
    if (userId) {
      await this.ctx.storage.put("userId", userId);
      this.userId = userId;
    }
    await this.pushPlain(chatId, { title, body });
  }

  async revokeDevice(deviceId: string, userId?: string): Promise<void> {
    if (userId) {
      await this.ctx.storage.put("userId", userId);
      this.userId = userId;
    }
    for (const ws of this.sockets()) {
      const att = ws.deserializeAttachment() as SocketAttachment | null;
      if (att?.deviceId !== deviceId) continue;
      try { ws.close(4401, "revoked"); } catch { /* already closed */ }
    }
    const tokens =
      (await this.ctx.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    if (deviceId in tokens) {
      delete tokens[deviceId];
      await this.ctx.storage.put("apns", tokens);
    }
    // the session, its token and its keys go together: the token stops
    // authenticating, the next send builds no box for the device and its
    // prekeys stop being handed out
    const rec = await this.ctx.storage.get<DeviceRecord>(DEV_PREFIX + deviceId);
    const otps = await this.ctx.storage.list({ prefix: otpPrefix(deviceId) });
    const gone = [
      ikKey(deviceId), DEV_PREFIX + deviceId,
      ...(rec ? [TOKEN_PREFIX + rec.tokenHash] : []),
      ...otps.keys(),
    ];
    for (let i = 0; i < gone.length; i += STORAGE_BATCH) {
      await this.ctx.storage.delete(gone.slice(i, i + STORAGE_BATCH));
    }
    const version = ((await this.ctx.storage.get<number>("devicesVersion")) ?? 1) + 1;
    await this.ctx.storage.put("devicesVersion", version);
    await this.broadcastDevicesChanged(version);
    if (this.sockets().length === 0) await this.broadcastPresence(false);
  }

  // --- the E2EE device set: identity keys, prekeys, the set's version ---

  async keysRegister(b: {
    userId: string; deviceId: string;
    identityKey: string; identitySignKey: string; identityKeySig: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekeys?: PrekeyUpload[];
    /// a linked device changes the set an existing account's peers hold;
    /// the first registration starts it and nobody holds a copy yet
    bump?: boolean;
    /// the card a registration opens the account with; a device joining
    /// an account that already exists sends none
    profile?: Profile;
    /// the session this device speaks for from now on
    device?: { deviceId: string; name: string | null; tokenHash: string };
  }): Promise<{ version: number }> {
    await this.ctx.storage.put("userId", b.userId);
    this.userId = b.userId;
    let version = (await this.ctx.storage.get<number>("devicesVersion")) ?? 1;
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
    // the card and the session go in the same write as the keys: an
    // account is either whole here or was never opened
    if (b.profile) puts["profile"] = b.profile;
    if (b.device) {
      puts[DEV_PREFIX + b.device.deviceId] = {
        name: b.device.name, tokenHash: b.device.tokenHash,
        createdAt: Date.now(), lastSeen: null,
      } satisfies DeviceRecord;
      puts[TOKEN_PREFIX + b.device.tokenHash] = b.device.deviceId;
    }
    await this.putBatched(puts);
    if (b.bump) await this.broadcastDevicesChanged(version);
    return { version };
  }

  async keysTopup(deviceId: string, oneTimePrekeys?: PrekeyUpload[]): Promise<void> {
    const wanted = (oneTimePrekeys ?? []).slice(0, 200);
    const names = wanted.map((k) => otpKey(deviceId, k.id));
    const existing = new Set<string>();
    for (let i = 0; i < names.length; i += STORAGE_BATCH) {
      const got = await this.ctx.storage.get(names.slice(i, i + STORAGE_BATCH));
      for (const k of got.keys()) existing.add(k);
    }
    // a key id already uploaded keeps its first value: a retry of the same
    // top-up must not replace a key a bundle may have handed out meanwhile
    const puts: Record<string, unknown> = {};
    wanted.forEach((k, i) => {
      if (!existing.has(names[i])) puts[names[i]] = k.key;
    });
    if (Object.keys(puts).length) await this.putBatched(puts);
  }

  async keysCount(deviceId: string): Promise<{ count: number }> {
    const listed = await this.ctx.storage.list({ prefix: otpPrefix(deviceId) });
    return { count: listed.size };
  }

  /// X3DH bundles for every device; the one-time prekey with the lowest id
  /// is consumed here, inside the object, so two senders never draw the same one.
  async keysPrekeys(): Promise<{ bundles: Array<{
    deviceId: string; identityKey: string; identitySignKey: string; identityKeySig: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekey: { id: number; key: string } | null;
  }> }> {
    const iks = await this.ctx.storage.list<IdentityRecord>({ prefix: IK_PREFIX });
    const bundles = [];
    for (const [key, d] of iks) {
      const deviceId = key.slice(IK_PREFIX.length);
      const prefix = otpPrefix(deviceId);
      const otps = await this.ctx.storage.list<string>({ prefix, limit: 1 });
      let oneTimePrekey: { id: number; key: string } | null = null;
      for (const [otpName, otpVal] of otps) {
        oneTimePrekey = { id: Number(otpName.slice(prefix.length)), key: otpVal };
        await this.ctx.storage.delete(otpName);
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
    return { bundles };
  }

  async keysDevices(): Promise<{
    devices: Array<{ deviceId: string; identityKey: string; identitySignKey: string; identityKeySig: string }>;
    account: { identityKey: string; identitySignKey: string } | null;
    version: number | null;
  }> {
    const iks = await this.ctx.storage.list<IdentityRecord>({ prefix: IK_PREFIX });
    const version = (await this.ctx.storage.get<number>("devicesVersion")) ?? null;
    const devices = [...iks].map(([key, d]) => ({
      deviceId: key.slice(IK_PREFIX.length),
      identityKey: d.identityKey,
      identitySignKey: d.identitySignKey,
      identityKeySig: d.identityKeySig,
    }));
    const account = (await this.ctx.storage.get<{
      identityKey: string; identitySignKey: string;
    }>("accountIdentity")) ?? null;
    return { devices, account, version };
  }

  /// null: no device ever registered here, so the user is unknown.
  async keysVersion(): Promise<{ version: number | null }> {
    const version = (await this.ctx.storage.get<number>("devicesVersion")) ?? null;
    return { version };
  }

  async keysUpdate(b: {
    deviceId: string; identityKey: string; identitySignKey: string; identityKeySig: string;
  }): Promise<{ version: number }> {
    const rec = await this.ctx.storage.get<IdentityRecord>(ikKey(b.deviceId));
    if (!rec) throw new DOError("not_found", 404);
    rec.identityKey = b.identityKey;
    rec.identitySignKey = b.identitySignKey;
    rec.identityKeySig = b.identityKeySig;
    await this.ctx.storage.put(ikKey(b.deviceId), rec);
    await this.ctx.storage.put("accountIdentity", {
      identityKey: b.identityKey,
      identitySignKey: b.identitySignKey,
    });
    // a rotated identity is a changed device set: peers holding the old
    // key by version must drop the cache, or per-send TOFU keeps trusting
    // the key this update just replaced
    const version = ((await this.ctx.storage.get<number>("devicesVersion")) ?? 1) + 1;
    await this.ctx.storage.put("devicesVersion", version);
    await this.broadcastDevicesChanged(version);
    return { version };
  }

  /// The device found out its published bundle is stale: peers build
  /// X3DH sessions it cannot open (its own prekey private halves are
  /// missing). It hands in a fresh signed prekey and a fresh set of
  /// one-time prekeys; the old one-times are dropped whole — every one
  /// of them is from the generation that does not open.
  async keysRepublish(b: {
    deviceId: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekeys?: PrekeyUpload[];
  }): Promise<{ version: number }> {
    const rec = await this.ctx.storage.get<IdentityRecord>(ikKey(b.deviceId));
    if (!rec) throw new DOError("not_found", 404);
    rec.signedPrekeyId = b.signedPrekey.id;
    rec.signedPrekey = b.signedPrekey.key;
    rec.signedPrekeySig = b.signedPrekey.sig;
    const stale = [...(await this.ctx.storage.list({ prefix: otpPrefix(b.deviceId) })).keys()];
    for (let i = 0; i < stale.length; i += STORAGE_BATCH) {
      await this.ctx.storage.delete(stale.slice(i, i + STORAGE_BATCH));
    }
    const puts: Record<string, unknown> = { [ikKey(b.deviceId)]: rec };
    for (const k of (b.oneTimePrekeys ?? []).slice(0, 200)) {
      puts[otpKey(b.deviceId, k.id)] = k.key;
    }
    await this.putBatched(puts);
    // peers holding a cached device set would keep building sessions on
    // the stale bundle; the bump makes them refetch
    const version = ((await this.ctx.storage.get<number>("devicesVersion")) ?? 1) + 1;
    await this.ctx.storage.put("devicesVersion", version);
    await this.broadcastDevicesChanged(version);
    return { version };
  }

  // --- the address book: a set of phone hashes under `ct:<hash>`.
  // Contact-ness is answered against the peer's current hash at the
  // moment of the question, so a number registering or changing hands
  // needs no propagation into anyone's book.

  async contactsSync(hashes?: string[], remove?: string[]): Promise<void> {
    const wantedHashes = [...new Set(hashes ?? [])].slice(0, CONTACTS_SYNC_MAX);
    const wantedRemove = [...new Set(remove ?? [])].slice(0, CONTACTS_SYNC_MAX);
    for (let i = 0; i < wantedHashes.length; i += STORAGE_BATCH) {
      const batch: Record<string, number> = {};
      for (const hash of wantedHashes.slice(i, i + STORAGE_BATCH)) batch[`ct:${hash}`] = 1;
      await this.ctx.storage.put(batch);
    }
    for (let i = 0; i < wantedRemove.length; i += STORAGE_BATCH) {
      await this.ctx.storage.delete(wantedRemove.slice(i, i + STORAGE_BATCH).map((h) => `ct:${h}`));
    }
  }

  async contactOf(hash: string): Promise<{ contact: boolean }> {
    const held = hash !== "" &&
      (await this.ctx.storage.get(`ct:${hash}`)) !== undefined;
    return { contact: held };
  }

  // --- the account itself: who may speak for it, its card, its rules ---

  /// The hash covers the whole token, the account id included, so a
  /// secret lifted from one account proves nothing on another.
  async auth(hash: string): Promise<{ deviceId: string }> {
    const deviceId = hash === "" ? undefined
      : await this.ctx.storage.get<string>(TOKEN_PREFIX + hash);
    if (!deviceId) throw new DOError("unauthorized", 401);
    return { deviceId };
  }

  /// A bot account opening: a card and a session, and no keys at all —
  /// which is exactly what makes every chat it joins readable.
  async botRegister(b: {
    userId: string; profile: Profile;
    device: { deviceId: string; name: string | null; tokenHash: string };
  }): Promise<void> {
    this.userId = b.userId;
    await this.ctx.storage.put({
      userId: b.userId,
      profile: b.profile,
      [DEV_PREFIX + b.device.deviceId]: {
        name: b.device.name, tokenHash: b.device.tokenHash,
        createdAt: Date.now(), lastSeen: null,
      } satisfies DeviceRecord,
      [TOKEN_PREFIX + b.device.tokenHash]: b.device.deviceId,
    });
  }

  /// The bots this account runs. There is no index from an owner back to
  /// their bots anywhere else, so the owner's object keeps the list.
  async botOwnedRead(): Promise<{ botIds: string[] }> {
    const listed = await this.ctx.storage.list({ prefix: BOT_PREFIX });
    return { botIds: [...listed.keys()].map((k) => k.slice(BOT_PREFIX.length)) };
  }

  async botOwnedWrite(botId: string, add: boolean): Promise<void> {
    if (add) await this.ctx.storage.put(BOT_PREFIX + botId, Date.now());
    else await this.ctx.storage.delete(BOT_PREFIX + botId);
  }

  async deviceAdd(deviceId: string, name: string | null, tokenHash: string): Promise<void> {
    await this.ctx.storage.put({
      [DEV_PREFIX + deviceId]: {
        name, tokenHash, createdAt: Date.now(), lastSeen: null,
      } satisfies DeviceRecord,
      [TOKEN_PREFIX + tokenHash]: deviceId,
    });
  }

  /// A fresh token for a device that already exists: the old one stops
  /// working in the same write.
  async deviceRetoken(deviceId: string | undefined, tokenHash: string): Promise<void> {
    const listed = await this.ctx.storage.list<DeviceRecord>({ prefix: DEV_PREFIX });
    const target = deviceId
      ? ([...listed].find(([k]) => k === DEV_PREFIX + deviceId))
      : [...listed][0];
    if (!target) throw new DOError("device_not_found", 404);
    const [key, rec] = target;
    await this.ctx.storage.delete(TOKEN_PREFIX + rec.tokenHash);
    rec.tokenHash = tokenHash;
    await this.ctx.storage.put({ [key]: rec, [TOKEN_PREFIX + tokenHash]: key.slice(DEV_PREFIX.length) });
  }

  async sessions(): Promise<{ sessions: Array<{
    deviceId: string; name: string | null; createdAt: number; lastSeen: number | null; hasPushToken: boolean;
  }> }> {
    const listed = await this.ctx.storage.list<DeviceRecord>({ prefix: DEV_PREFIX });
    const tokens =
      (await this.ctx.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    const sessions = [...listed].map(([k, d]) => ({
      deviceId: k.slice(DEV_PREFIX.length),
      name: d.name, createdAt: d.createdAt, lastSeen: d.lastSeen,
      hasPushToken: (k.slice(DEV_PREFIX.length) in tokens),
    })).sort((a, b2) => a.createdAt - b2.createdAt);
    return { sessions };
  }

  async profileRead(): Promise<{ profile: Profile }> {
    const p = await this.ctx.storage.get<Profile>("profile");
    if (!p) throw new DOError("not_found", 404);
    return { profile: p };
  }

  /// A field left out is left alone. `username` is written only after the
  /// handle object has granted the claim.
  async profileWrite(b: {
    displayName?: string; bio?: string; avatarId?: string; username?: string;
    botCommands?: string;
  }): Promise<{ profile: Profile }> {
    const p = await this.ctx.storage.get<Profile>("profile");
    if (!p) throw new DOError("not_found", 404);
    if (b.displayName !== undefined) p.display_name = b.displayName.trim();
    if (b.bio !== undefined) p.bio = b.bio;
    if (b.avatarId !== undefined) p.avatar_id = b.avatarId;
    if (b.username !== undefined) p.username = b.username;
    if (b.botCommands !== undefined) p.bot_commands = b.botCommands;
    await this.ctx.storage.put("profile", p);
    return { profile: p };
  }

  async card(viewer: string): Promise<{ user: PublicUser }> {
    const card = await this.cardForInternal(viewer);
    if (!card) throw new DOError("not_found", 404);
    return { user: card };
  }

  /// The half of the card that is public whoever asks: the name, the
  /// handle and whether this is a bot. The photo and the bio are per-viewer
  /// and are not in it, so a chat may hold this copy for its whole roster.
  async cardPublic(): Promise<{ user: PublicUser }> {
    const p = await this.ctx.storage.get<Profile>("profile");
    if (!p) throw new DOError("not_found", 404);
    return { user: {
      id: p.id, username: p.username, display_name: p.display_name,
      bio: null, avatar_id: null,
      bot_owner: p.bot_owner ?? null, bot_commands: p.bot_commands ?? null,
    } satisfies PublicUser };
  }

  async phoneHash(): Promise<{ phoneHash: string | null }> {
    const p = await this.ctx.storage.get<Profile>("profile");
    return { phoneHash: p?.phone_hash ?? null };
  }

  async phone(phoneHash: string | null): Promise<{ was: string | null }> {
    const p = await this.ctx.storage.get<Profile>("profile");
    if (!p) throw new DOError("not_found", 404);
    const was = p.phone_hash;
    p.phone_hash = phoneHash;
    await this.ctx.storage.put("profile", p);
    return { was };
  }

  async privacyRead(): Promise<{ privacy: PrivacySettings }> {
    return { privacy: await this.privacy() };
  }

  async privacyWrite(b: Partial<PrivacySettings>): Promise<{
    privacy: PrivacySettings; avatarChanged: boolean; lastSeenChanged: boolean;
  }> {
    const current = await this.privacy();
    const next: PrivacySettings = { ...current, ...b };
    await this.ctx.storage.put("privacy", next);
    return {
      privacy: next,
      avatarChanged: next.avatar !== current.avatar,
      lastSeenChanged: next.lastSeen !== current.lastSeen,
    };
  }

  async privacyCheck(viewerId: string, settings: PrivacySetting[]): Promise<{ allow: Record<string, boolean> }> {
    const privacy = await this.privacy();
    const allow: Record<string, boolean> = {};
    for (const s of settings) allow[s] = await this.mayView(viewerId, s, privacy);
    return { allow };
  }

  async privacyExceptions(): Promise<{
    exceptions: Array<{ setting: string; peerId: string; allow: boolean }>;
  }> {
    const listed = await this.ctx.storage.list<number>({ prefix: PEX_PREFIX });
    const exceptions = [...listed].map(([k, allow]) => {
      const rest = k.slice(PEX_PREFIX.length);
      const cut = rest.indexOf(":");
      return { setting: rest.slice(0, cut), peerId: rest.slice(cut + 1), allow: allow === 1 };
    });
    return { exceptions };
  }

  async privacyException(setting: string, peerId: string, allow: boolean | null): Promise<void> {
    const key = `${PEX_PREFIX}${setting}:${peerId}`;
    if (allow === null) await this.ctx.storage.delete(key);
    else await this.ctx.storage.put(key, allow ? 1 : 0);
  }

  // --- blocks: this user's own list, and the mirror of who blocked them ---

  async blocks(): Promise<{ blocked: string[]; blockedBy: string[] }> {
    const mine = await this.ctx.storage.list<number>({ prefix: BLOCK_PREFIX });
    const theirs = await this.ctx.storage.list<number>({ prefix: BLOCKED_BY_PREFIX });
    return {
      blocked: [...mine.keys()].map((k) => k.slice(BLOCK_PREFIX.length)),
      blockedBy: [...theirs.keys()].map((k) => k.slice(BLOCKED_BY_PREFIX.length)),
    };
  }

  async blockPair(peer: string): Promise<{ byMe: boolean; byPeer: boolean }> {
    return this.blockPairInternal(peer);
  }

  /// The mirror in the peer's object is what lets either side answer for
  /// the pair without a second call on the send path.
  async block(peer: string, blocked: boolean): Promise<void> {
    const userId = await this.getUserId();
    if (blocked) await this.ctx.storage.put(BLOCK_PREFIX + peer, Date.now());
    else await this.ctx.storage.delete(BLOCK_PREFIX + peer);
    if (userId) {
      await this.tellBlockedBy(peer, userId, blocked);
    }
    if (blocked) {
      await this.ctx.storage.delete([PEER_PREFIX + peer, PCARD_PREFIX + peer]);
      if (userId) await this.tellPeerDrop(peer, userId);
    } else {
      await this.pushPresence([peer]);
      await this.pushCards([peer]);
      if (userId) await this.tellPeerRefresh(peer, userId);
    }
  }

  private async tellBlockedBy(userId: string, from: string, blocked: boolean) {
    try {
      await this.userStub(userId).blockedBy(from, blocked);
    } catch (e) {
      console.warn(`blockedBy to ${userId} failed: ${e}`);
    }
  }

  async blockedBy(peer: string, blocked: boolean): Promise<void> {
    if (blocked) {
      await this.ctx.storage.put(BLOCKED_BY_PREFIX + peer, Date.now());
      // nothing of theirs is held any more, name and photo included
      await this.ctx.storage.delete([PEER_PREFIX + peer, PCARD_PREFIX + peer]);
    } else {
      await this.ctx.storage.delete(BLOCKED_BY_PREFIX + peer);
    }
  }

  /// A report the person filed. Nothing reads these back yet; they are
  /// kept with the account that made them.
  async report(rec: Record<string, unknown>): Promise<void> {
    await this.ctx.storage.put(REPORT_PREFIX + ulid(), rec);
  }

  async devFault(failEvents?: number): Promise<{ failEvents: number }> {
    this.devFailEvents = Math.max(0, Math.floor(failEvents ?? 0));
    return { failEvents: this.devFailEvents };
  }

  async presenceInfo(): Promise<{ online: boolean; lastSeen: number }> {
    const lastSeen = (await this.ctx.storage.get<number>("lastSeen")) ?? 0;
    return { online: this.presenceFresh(), lastSeen };
  }

  /// A story delivered by its author's object: kept in this user's inbox
  /// and told to their sockets. `new` adds it, `removed` takes it out,
  /// `stats` moves the counts on this user's own story. The inbox is what
  /// GET /api/stories reads — one object, nothing asked of the authors.
  async storyEvent(d: StoryDelivery): Promise<{ dupe?: boolean }> {
    const key = STORY_PREFIX + d.storyId;
    if (d.kind === "new" && d.story) {
      const me = await this.getUserId();
      const mine = d.authorId === me;
      const item: StoryItem = {
        id: d.storyId, authorId: d.authorId,
        username: d.story.author?.username ?? "", displayName: d.story.author?.display_name ?? "",
        avatarId: d.story.author?.avatar_id ?? null,
        createdAt: d.story.createdAt, expiresAt: d.story.expiresAt,
        frames: d.story.frames, audience: d.story.audience, link: d.story.link,
        seen: false, liked: false, views: mine ? 0 : null, likes: mine ? 0 : null,
      };
      // a delivery repeated after a failure that in fact landed changes nothing
      const had = await this.ctx.storage.get<StoryItem>(key);
      if (had) return { dupe: true };
      await this.ctx.storage.put(key, item);
      this.broadcast({ t: "story", event: "new", storyId: d.storyId, story: item });
    } else if (d.kind === "removed") {
      const had = await this.ctx.storage.get<StoryItem>(key);
      await this.ctx.storage.delete(key);
      if (had) this.broadcast({ t: "story", event: "removed", storyId: d.storyId });
    } else if (d.kind === "stats") {
      const item = await this.ctx.storage.get<StoryItem>(key);
      if (item) {
        item.views = d.views ?? item.views;
        item.likes = d.likes ?? item.likes;
        await this.ctx.storage.put(key, item);
        this.broadcast({ t: "story", event: "stats", storyId: d.storyId,
          views: item.views ?? 0, likes: item.likes ?? 0 });
      }
    }
    return {};
  }

  /// This user's own state on a story — watched, hearted, or a new link on
  /// their own — written into the inbox row and told to their other devices.
  async storyMark(storyId: string, seen?: boolean, liked?: boolean, link?: string | null): Promise<{ missing?: boolean }> {
    const key = STORY_PREFIX + storyId;
    const item = await this.ctx.storage.get<StoryItem>(key);
    if (!item) return { missing: true };
    if (seen !== undefined) item.seen = seen;
    if (liked !== undefined) item.liked = liked;
    if (link !== undefined) item.link = link;
    await this.ctx.storage.put(key, item);
    this.broadcast({ t: "story", event: "mark", storyId, seen: item.seen, liked: item.liked });
    return {};
  }

  /// Whether the story was delivered to this user: one read, the whole of
  /// the right to act on it.
  async storyHas(id: string): Promise<{ has: boolean }> {
    const item = await this.ctx.storage.get<StoryItem>(STORY_PREFIX + id);
    return { has: !!item && item.expiresAt > Date.now() };
  }

  /// Every live story delivered to this user, oldest first.
  async storiesInbox(): Promise<{ stories: StoryItem[] }> {
    return { stories: await this.storiesInboxList() };
  }

  /// The card travels the same road as presence: out through every chat
  /// this user is in, and to their own other devices. `peerUser` is the
  /// card as other users may see it: the worker blanks a hidden photo and
  /// bio there, while the user's own devices get it whole.
  async profileChanged(user: PublicUser, peerUser?: PublicUser): Promise<void> {
    const peer = peerUser ?? user;
    this.broadcast({ t: "profile", user });
    // the subscribers' copies are rewritten each as that subscriber may
    // see the card, which is more than the one frame below can carry
    await this.pushCards(await this.subscribers());
    const ids = await this.chatIds();
    const results = await Promise.allSettled(
      ids.map((chatId) => this.convStub(chatId).profile(user.id, peer))
    );
    results.forEach((r, i) => {
      if (r.status === "rejected") {
        console.warn(`profile of ${user.id} in ${ids[i]} failed: ${r.reason}`);
      }
    });
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
      ids.map((chatId) => this.convStub(chatId).devices(userId, version))
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
      await this.ctx.storage.put(chunk);
    }
  }

  // --- badge: unread summed over the chats ---
  // Per-chat unread is cached in storage ("unreadCache") and invalidated by an incoming
  // msg or by this user's own read. Recount is lazy, through ConversationDO
  // unreadCount() at push time, and only for the chats whose entry was dropped.

  private async invalidateUnread(chatId: string) {
    const cache =
      (await this.ctx.storage.get<Record<string, number>>("unreadCache")) ?? {};
    if (chatId in cache) {
      delete cache[chatId];
      await this.ctx.storage.put("unreadCache", cache);
    }
  }

  private async totalUnread(): Promise<number> {
    const userId = await this.getUserId();
    const cache =
      (await this.ctx.storage.get<Record<string, number>>("unreadCache")) ?? {};
    let changed = false;
    let total = 0;
    for (const chatId of await this.chatIds()) {
      let n = cache[chatId];
      if (n === undefined) {
        try {
          n = (await this.convStub(chatId).unreadCount(userId ?? "")).unread;
        } catch {
          n = 0;
        }
        cache[chatId] = n;
        changed = true;
      }
      total += n;
    }
    if (changed) await this.ctx.storage.put("unreadCache", cache);
    return total;
  }

  /// Orders the badge numbers this object hands out. The object is the only
  /// writer of the user's unread total and runs single-threaded, so a counter
  /// it bumps per push round says exactly which of two counts is the newer one
  /// — which is all a device needs to ignore a push that overtook another.
  private async nextBadgeStamp(): Promise<number> {
    const next = ((await this.ctx.storage.get<number>("badgeStamp")) ?? 0) + 1;
    await this.ctx.storage.put("badgeStamp", next);
    return next;
  }

  /// Queues a push for the alarm loop and wakes it.
  private async enqueuePush(frame: PushJob) {
    const id = (await this.ctx.storage.get<number>("pqNext")) ?? 1;
    const job: PushJob = {
      chatId: frame.chatId, seq: frame.seq, sentAt: frame.sentAt,
      from: frame.from, fromDevice: frame.fromDevice, ts: frame.ts, body: frame.body,
      ...(frame.muted ? { muted: true } : {}),
    };
    await this.ctx.storage.put({ [pushKey(id)]: job, pqNext: id + 1 });
    await this.armAlarm(Date.now());
  }

  /// Sends the queued pushes oldest first, a bounded number per invocation,
  /// and asks to be woken again for the rest: at once when ready jobs remain,
  /// at the nearest deadline when the head of the queue is waiting one out.
  private async drainPushes() {
    const listed = await this.ctx.storage.list<PushJob>({
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
        await this.ctx.storage.delete(key);
        continue;
      }
      const attempt = (job.attempt ?? 0) + 1;
      const retryMs = PUSH_RETRY_MS[Math.min(attempt - 1, PUSH_RETRY_MS.length - 1)];
      const nextAt = Date.now() + retryMs;
      const tokens =
        (await this.ctx.storage.get<Record<string, unknown>>("apns")) ?? {};
      const pushed = Object.keys(tokens).filter((d) => !owed.includes(d));
      await this.ctx.storage.put(key, { ...job, attempt, nextAt, pushed });
      nextWake = nextWake === undefined ? nextAt : Math.min(nextWake, nextAt);
    }
    if (skippedReady) await this.armAlarm(Date.now());
    else if (nextWake !== undefined) await this.armAlarm(nextWake);
  }

  /// A single informational push to every device of this user (added to a
  /// group, and the like). No envelope, no seq; the badge stays at the current
  /// unread total. A dead token is dropped the same way the message path does.
  private async pushPlain(chatId: string, alert: { title: string; body: string }): Promise<void> {
    const tokens =
      (await this.ctx.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
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

  /// The push carries the message itself, addressed to the device it goes to:
  /// the extension decrypts it and writes it, so the chat holds what the banner
  /// showed even if the socket never comes up. Returns the devices still owed
  /// their push — the ones that failed in transit and are worth another try. A
  /// refusal APNs actually pronounced is final: retrying the same payload buys
  /// nothing, and a dead token is dropped here.
  private async pushToDevices(frame: PushJob, skip: string[] = []): Promise<string[]> {
    const tokens =
      (await this.ctx.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    const devices = Object.entries(tokens).filter(([d]) => !skip.includes(d));
    if (!devices.length) return [];
    const badge = await this.totalUnread();
    const badgeStamp = await this.nextBadgeStamp();
    const userId = await this.getUserId();
    // the chat's own sound wins; then the sender's personal sound wherever
    // they write; then the user's default for the chat's shape
    const flags = await this.ctx.storage.get<ChatFlags>("chat:" + frame.chatId);
    const personal = frame.from
      ? await this.ctx.storage.get<string>(`usnd:${frame.from}`) : undefined;
    const defaults = (await this.ctx.storage.get<NotifySounds>("notifySounds")) ?? {};
    const sound = flags?.sound ?? personal ?? defaults[chatShape(frame.chatId)];
    const fromName = frame.from
      ? await this.ctx.storage.get<string>(NAME_PREFIX + frame.from) : undefined;
    // Every device is handled independently: one failure neither cancels the
    // others nor fails the frame delivery that already went over the socket.
    const results = await Promise.all(
      devices.map(async ([deviceId, t]) => {
        try {
          return {
            deviceId,
            res: await sendPush(this.env, t.token, t.env, {
              chatId: frame.chatId, seq: frame.seq,
              // a muted chat's push makes no sound of its own; the device
              // gives a mention or a reply its sound when it opens the envelope
              sound: frame.muted ? "none" : sound,
              muted: frame.muted,
              sentAt: frame.sentAt, badge, badgeStamp,
              from: frame.from, fromDevice: frame.fromDevice, fromName, ts: frame.ts,
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

  /// A token APNs answered 410 for is forgotten: the device is still a
  /// session, it just has no push address any more.
  private async dropPushTokens(deviceIds: string[]) {
    const tokens =
      (await this.ctx.storage.get<Record<string, { token: string; env: string }>>("apns")) ?? {};
    let changed = false;
    for (const id of deviceIds) {
      if (id in tokens) {
        delete tokens[id];
        changed = true;
      }
    }
    if (changed) await this.ctx.storage.put("apns", tokens);
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
    // every chat of the portion gets a share of the budget. Spending it in
    // order let one flooded chat take the whole of it and leave the rest of the
    // list untouched portion after portion — a message in a quiet chat then
    // never arrived at all, because the client only re-asks for the chats the
    // portion answered
    const touching = Math.max(1, Math.min(Object.keys(cursors).length, SYNC_CHATS));
    const share = Math.max(1, Math.floor(SYNC_BUDGET / touching));
    for (const [chatId, from] of Object.entries(cursors)) {
      if (budget <= 0 || chats <= 0) {
        pending = true;
        continue;
      }
      chats--;
      const limit = Math.min(SYNC_PAGE, share, budget);
      let r: { msgs?: Array<Record<string, unknown>>; scanned?: number; lastScannedSeq?: number | null };
      try {
        r = await this.convStub(chatId).history({ userId, fromSeq: from, limit }) as typeof r;
      } catch (e) {
        // removed from the chat while the client was offline: it missed the live chat
        // frame and the journal is no longer served to it, so say so outright, otherwise
        // the chat would stay with it forever
        if (DOError.from(e)?.error === "not_member") {
          this.send(ws, { t: "chat", chatId, event: "removed" });
        }
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
    let e: {
      deleted?: Array<{ seq: number; by: string }>;
      readMarks?: Record<string, number>;
      deliveredMarks?: Record<string, number>;
      state?: unknown;
      users?: unknown[];
    };
    try {
      e = await this.convStub(chatId).events(userId) as typeof e;
    } catch {
      return;
    }
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
        this.send(ws, { t: "pong" });
        // a socket whose app is in the background stays a socket, not a presence
        if (att.bg) return;
        const wasFresh = this.presenceFresh();
        ws.serializeAttachment({ ...att, lastPing: nowSec() } satisfies SocketAttachment);
        await this.armPresenceCheck();
        if (!wasFresh) await this.broadcastPresence(true);
        return;
      }

      case "bg":
        ws.serializeAttachment({ ...att, lastPing: 0, bg: true } satisfies SocketAttachment);
        await this.broadcastPresence(false);
        return;

      case "fg": {
        ws.serializeAttachment({ ...att, lastPing: nowSec(), bg: false } satisfies SocketAttachment);
        await this.armPresenceCheck();
        await this.broadcastPresence(true);
        return;
      }

      case "send": {
        try {
          const r = await this.convStub(frame.chatId).send({
            from: userId, fromDevice: att.deviceId,
            clientMsgId: frame.clientMsgId, sentAt: frame.sentAt, body: frame.body,
            service: frame.service ?? false,
            ...(frame.notify ? { notify: true } : {}),
            ...(frame.notifyUser ? { notifyUser: frame.notifyUser } : {}),
          });
          this.send(ws, {
            t: "sent", chatId: frame.chatId, clientMsgId: frame.clientMsgId,
            seq: r.seq, ts: r.ts,
          });
        } catch (e) {
          this.send(ws, {
            t: "error", error: DOError.from(e)?.error ?? "send_failed",
            chatId: frame.chatId, clientMsgId: frame.clientMsgId,
          });
        }
        return;
      }

      case "defer": {
        try {
          const r = await this.convStub(frame.chatId).defer({
            from: userId, fromDevice: att.deviceId,
            clientMsgId: frame.clientMsgId, sentAt: frame.sentAt,
            body: frame.body, dueAt: frame.dueAt,
          });
          if (r.seq) {
            // the journal already holds this clientMsgId: answer the way a resend is answered
            this.send(ws, {
              t: "sent", chatId: frame.chatId, clientMsgId: frame.clientMsgId,
              seq: r.seq, ts: r.ts!,
            });
          } else {
            this.send(ws, {
              t: "deferred", chatId: frame.chatId, clientMsgId: frame.clientMsgId,
              dueAt: r.dueAt!,
            });
          }
        } catch (e) {
          this.send(ws, {
            t: "error", error: DOError.from(e)?.error ?? "defer_failed",
            chatId: frame.chatId, clientMsgId: frame.clientMsgId,
          });
        }
        return;
      }

      case "deferCancel":
        await this.convStub(frame.chatId).deferCancel(userId, frame.clientMsgId);
        return;

      case "recv":
        await this.convStub(frame.chatId).recv(userId, frame.seqs);
        return;

      case "read":
        await this.convStub(frame.chatId).read(userId, frame.upToSeq);
        // this user's own read moves the chat's unread, so the cached badge is stale
        await this.invalidateUnread(frame.chatId);
        return;

      case "typing":
        await this.convStub(frame.chatId).typing(userId, frame.kind);
        return;

      case "callRelay":
        await this.convStub(frame.chatId).callRelay({
          userId, deviceId: att.deviceId, sentAt: frame.sentAt, body: frame.body,
        });
        return;

      case "delete": {
        // the chat takes a bounded slice per call; a long selection goes in
        // as many calls, each tombstoned and fanned out on its own
        const seqs = Array.isArray(frame.seqs) ? frame.seqs : [];
        for (let i = 0; i < seqs.length; i += DELETE_SEQS_PER_CALL) {
          await this.convStub(frame.chatId).delete(
            userId, seqs.slice(i, i + DELETE_SEQS_PER_CALL), frame.forAll);
        }
        return;
      }

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
                  // own object: read storage directly, a self-call has no answer
                  v = (await this.ctx.storage.get<number>("devicesVersion")) ?? null;
                } else {
                  v = (await this.userStub(id).keysVersion()).version;
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
          // the stories inbox as it stands: a story frame sent while the socket
          // was down is gone, and this is what stands in for it
          this.send(ws, { t: "stories", stories: await this.storiesInboxList() });
          // chats the client does not know yet, created or joined while it was offline:
          // send the state and replay the history from zero
          const known = new Set(Object.keys(frame.cursors));
          const listed = await this.ctx.storage.list<unknown>({ prefix: "chat:" });
          for (const key of listed.keys()) {
            const chatId = key.slice(5);
            if (known.has(chatId)) continue;
            try {
              const sj = await this.convStub(chatId).state();
              this.send(ws, { t: "chat", chatId, event: "sync", state: sj.state, users: sj.users } as ServerFrame);
              cursors[chatId] = 0; // history replayed below
            } catch {
              // the chat is gone; nothing to replay
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
      const checkAt = await this.ctx.storage.get<number>("presenceCheckAt");
      if (checkAt !== undefined) {
        if (Date.now() >= checkAt) {
          if (this.presenceFresh()) {
            await this.armPresenceCheck();
          } else {
            await this.ctx.storage.delete("presenceCheckAt");
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
