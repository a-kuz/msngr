export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  USER_DO: DurableObjectNamespace;
  CONV_DO: DurableObjectNamespace;
  APNS_DO: DurableObjectNamespace;
  /// One object per username: who holds it, and the quarantine after a rename.
  HANDLE_DO: DurableObjectNamespace;
  /// The people-search index, sharded by user id.
  DIRECTORY_DO: DurableObjectNamespace;
  APNS_ENV: string;
  /// Overrides the APNs endpoint, e.g. the dev mock at http://localhost:9871.
  /// Unset means Apple's production or sandbox host, picked by the device's apns-env.
  APNS_HOST?: string;
  /// Artificial delay in ms before fanout in ConversationDO /send (dev only).
  DEV_WS_LATENCY_MS?: string;
  /// Dev only: log what each object invocation costs (see src/perf.ts).
  PERF_LOG?: string;
  /// Override the idempotency-record sweep for tests: minimum age in seconds
  /// and the pause between passes.
  CMID_MIN_AGE?: string;
  CMID_SWEEP_EVERY?: string;
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

// --- WS frames: client -> server ---
export type ClientFrame =
  // sync: full cursor map of everything the client knows; chats missing from it
  // are new to the client and get their state replayed. deviceVersions is the
  // client's device cache — userId to the devices_version it holds — answered
  // with a deviceVersions frame so entries still current survive the reconnect
  | { t: "sync"; cursors: Record<string, number>; deviceVersions?: Record<string, number> }
  // catchup: next portion for the chats that are still behind
  | { t: "catchup"; cursors: Record<string, number> }
  | { t: "send"; chatId: string; clientMsgId: string; sentAt: number; body: unknown; service?: boolean; notify?: boolean }
  // a scheduled send: the envelope is encrypted now, journaled by the server at
  // dueAt (ms since epoch). Re-sending the same clientMsgId before the deadline
  // replaces the envelope and the deadline (reschedule, edit)
  | { t: "defer"; chatId: string; clientMsgId: string; sentAt: number; body: unknown; dueAt: number }
  | { t: "deferCancel"; chatId: string; clientMsgId: string }
  | { t: "recv"; chatId: string; seqs: number[] }
  | { t: "read"; chatId: string; upToSeq: number }
  | { t: "typing"; chatId: string; kind: string | null }
  // an ephemeral E2E envelope for a call's ICE candidates: relayed to live
  // sockets, never journaled — a lost batch is superseded by the next one
  | { t: "callRelay"; chatId: string; sentAt: number; body: unknown }
  | { t: "delete"; chatId: string; seqs: number[]; forAll: boolean }
  | { t: "ping" }
  | { t: "bg" }   // app went to background: presence goes offline at once
  | { t: "fg" };  // app came back: presence goes online

export type LastSeenVisibility = "everyone" | "contacts" | "nobody";

/// A user's privacy settings. A user with no row in `privacy_settings` gets
/// these defaults.
export interface PrivacySettings {
  lastSeen: LastSeenVisibility;
  /// Who sees the profile photo and bio; the display name is always visible.
  avatar: LastSeenVisibility;
  /// Who may find this user by their phone hash; the username search is open.
  phoneDiscovery: LastSeenVisibility;
  /// Who may put this user straight into a group; anyone else can only send
  /// an invite link.
  groupInvites: LastSeenVisibility;
  /// Who may ring this user. Enforced on the callee's device — the signaling
  /// is E2EE — and mirrored to a viewer as `canCall` on the user card.
  callPrivacy: LastSeenVisibility;
  readReceipts: boolean;
  typing: boolean;
}

/// A user card as everyone may see it: the columns GET /api/users/:id serves.
export interface PublicUser {
  id: string;
  username: string;
  display_name: string;
  bio: string | null;
  avatar_id: string | null;
  /// A bot: who owns it. A bot has no keys of its own, so a chat it takes part
  /// in is not end-to-end encrypted, and the interface has to say so.
  bot_owner?: string | null;
  /// The bot's commands, as JSON `[{command, description}]`. The input offers
  /// them after «/».
  bot_commands?: string | null;
}

/// The columns every user card is read with.
export const USER_CARD_COLUMNS =
  "id, username, display_name, bio, avatar_id, bot_owner, bot_commands";

// --- WS frames: server -> client ---
export type ServerFrame =
  | { t: "hello"; serverTime: number; protocol: number; minProtocol: number }
  | { t: "sent"; chatId: string; clientMsgId: string; seq: number; ts: number }
  /// a defer frame's ack: the server holds the envelope and will journal it at dueAt
  | { t: "deferred"; chatId: string; clientMsgId: string; dueAt: number }
  | { t: "msg"; chatId: string; seq: number; from: string; fromDevice: string; clientMsgId?: string; sentAt: number; ts: number; body: unknown; service?: boolean; notify?: boolean }
  | { t: "receipt"; chatId: string; kind: "delivered" | "read"; upToSeq?: number; seqs?: number[]; by: string }
  | { t: "typing"; chatId: string; from: string; kind: string | null }
  | { t: "callRelay"; chatId: string; from: string; fromDevice: string; sentAt: number; body: unknown }
  | { t: "presence"; userId: string; online: boolean; lastSeen: number }
  /// someone's card changed: name, bio, avatar or username. The profile is
  /// public, so the frame carries the whole row rather than a hint to refetch
  | { t: "profile"; user: PublicUser }
  /// a user's device set changed: a device was linked or revoked. version is
  /// the user's devices_version after the change: a sender holding an older
  /// one drops its cached device list and re-reads /api/devices
  | { t: "devices"; userId: string; version: number }
  /// answer to the deviceVersions map of a sync frame: the current
  /// devices_version of every asked user the server knows. An entry the
  /// client holds at the same version is still current; anything else,
  /// including a user missing from the answer, is stale
  | { t: "deviceVersions"; versions: Record<string, number> }
  /// state is absent only for event "removed": the addressee is no longer a
  /// member, so the roster is not handed to them. users carries the public
  /// names of the roster (no bio or avatar: those are per-viewer private and
  /// the frame fans out to everyone), so a new chat shows named rows at once
  | { t: "chat"; chatId: string; event: string; state?: ChatState; users?: PublicUser[] }
  | { t: "deleted"; chatId: string; seqs: number[]; forAll: boolean; by: string }
  /// catch-up progress of one chat: cursor to resume from, more — whether the
  /// chat still has history beyond this portion
  | { t: "syncState"; chatId: string; cursor: number; more: boolean }
  /// end of one catch-up portion; more — whether another portion is due
  | { t: "syncDone"; more: boolean }
  /// rejection of a client frame; error is a machine-readable code
  | { t: "error"; error: string; chatId?: string; clientMsgId?: string }
  | { t: "pong" };

/// A group has admins and members; a channel has an owner, editors who may
/// post, and readers who may only comment and react.
export type ChatRole = "admin" | "member" | "owner" | "editor" | "reader";

export interface ChatMember {
  userId: string;
  role: ChatRole;
  joinedAt: number;
  /// message request: false means the chat sits in requests, and receipts and presence
  /// are withheld from whoever started it
  accepted: boolean;
}

/// Who may act in a group: everyone in it, or only its admins.
export type ChatPolicy = "all" | "admins";

/// A channel is the one kind that is not end-to-end encrypted: its posts are
/// journaled in the clear, so the server can search them and hand the whole
/// history to whoever subscribes later.
export type ChatKind = "direct" | "group" | "self" | "channel";

export interface ChatState {
  chatId: string;
  kind: ChatKind;
  title: string | null;
  avatarId: string | null;
  description: string | null;
  /// who may send content; service frames are never held back
  sendPolicy: ChatPolicy;
  /// who may add members and mint invite links
  invitePolicy: ChatPolicy;
  createdBy: string;
  createdAt: number;
  /// The chat's content is journaled readable: a channel, or any chat a bot is
  /// in. The client sends `plain` envelopes here and opens them only here.
  plaintext: boolean;
  members: ChatMember[];
  /// pinned messages by seq, oldest pin first
  pinnedSeqs: number[];
  lastSeq: number;
  readMarks: Record<string, number>;      // userId -> upToSeq
  deliveredMarks: Record<string, number>; // userId -> upToSeq
}

export interface StoredMsg {
  seq: number;
  from: string;
  fromDevice: string;
  clientMsgId: string;
  sentAt: number; // client clock
  ts: number;     // server clock
  body: unknown;  // E2E envelope; null if tombstoned
  service?: boolean;
  /// How many content messages the chat held once this one was written; a
  /// service frame carries the count it did not change. Unread is the distance
  /// between this number at a member's mark and the chat's current one.
  contentAt?: number;
  deleted?: boolean;
  deletedBy?: string;
  /// userId of a recipient who has blocked the sender: this member gets the message
  /// neither in fanout nor in history
  blockedFor?: string;
}

export interface AuthCtx {
  userId: string;
  deviceId: string;
}

// Internal DO RPC payloads (Worker <-> DO, DO <-> DO)
export type UserEvent = ServerFrame; // events pushed into UserDO for fan-out
