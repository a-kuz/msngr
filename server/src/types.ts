export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  USER_DO: DurableObjectNamespace;
  CONV_DO: DurableObjectNamespace;
  APNS_DO: DurableObjectNamespace;
  APNS_ENV: string;
  /// Overrides the APNs endpoint, e.g. the dev mock at http://localhost:9871.
  /// Unset means Apple's production or sandbox host, picked by the device's apns-env.
  APNS_HOST?: string;
  /// Artificial delay in ms before fanout in ConversationDO /send (dev only).
  DEV_WS_LATENCY_MS?: string;
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

// --- WS frames: client -> server ---
export type ClientFrame =
  // sync: full cursor map of everything the client knows; chats missing from it
  // are new to the client and get their state replayed
  | { t: "sync"; cursors: Record<string, number> }
  // catchup: next portion for the chats that are still behind
  | { t: "catchup"; cursors: Record<string, number> }
  | { t: "send"; chatId: string; clientMsgId: string; sentAt: number; body: unknown; service?: boolean }
  | { t: "recv"; chatId: string; seqs: number[] }
  | { t: "read"; chatId: string; upToSeq: number }
  | { t: "typing"; chatId: string; kind: string | null }
  | { t: "delete"; chatId: string; msgIds: string[]; forAll: boolean }
  | { t: "ping" }
  | { t: "bg" }   // app went to background: presence goes offline at once
  | { t: "fg" };  // app came back: presence goes online

// --- WS frames: server -> client ---
export type ServerFrame =
  | { t: "hello"; serverTime: number; protocol: number; minProtocol: number }
  | { t: "sent"; chatId: string; clientMsgId: string; msgId: string; seq: number; ts: number }
  | { t: "msg"; chatId: string; seq: number; msgId: string; from: string; fromDevice: string; sentAt: number; ts: number; body: unknown; service?: boolean }
  | { t: "receipt"; chatId: string; kind: "delivered" | "read"; upToSeq?: number; seqs?: number[]; by: string }
  | { t: "typing"; chatId: string; from: string; kind: string | null }
  | { t: "presence"; userId: string; online: boolean; lastSeen: number }
  | { t: "chat"; chatId: string; event: string; state: ChatState }
  | { t: "deleted"; chatId: string; msgIds: string[]; forAll: boolean; by: string }
  /// catch-up progress of one chat: cursor to resume from, more — whether the
  /// chat still has history beyond this portion
  | { t: "syncState"; chatId: string; cursor: number; more: boolean }
  /// end of one catch-up portion; more — whether another portion is due
  | { t: "syncDone"; more: boolean }
  /// rejection of a client frame; error is a machine-readable code
  | { t: "error"; error: string; chatId?: string; clientMsgId?: string }
  | { t: "pong" };

export interface ChatMember {
  userId: string;
  role: "admin" | "member";
  joinedAt: number;
  /// message request: false means the chat sits in requests, and receipts and presence
  /// are withheld from whoever started it
  accepted: boolean;
}

export interface ChatState {
  chatId: string;
  kind: "direct" | "group";
  title: string | null;
  avatarId: string | null;
  description: string | null;
  createdBy: string;
  createdAt: number;
  members: ChatMember[];
  pinnedMsgId: string | null;
  lastSeq: number;
  readMarks: Record<string, number>;      // userId -> upToSeq
  deliveredMarks: Record<string, number>; // userId -> upToSeq
}

export interface StoredMsg {
  msgId: string;
  seq: number;
  from: string;
  fromDevice: string;
  clientMsgId: string;
  sentAt: number; // client clock
  ts: number;     // server clock
  body: unknown;  // E2E envelope; null if tombstoned
  service?: boolean;
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
export type UserEvent = ServerFrame; // events pushed into UserSessionDO for fan-out
