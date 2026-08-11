export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  USER_DO: DurableObjectNamespace;
  CONV_DO: DurableObjectNamespace;
  APNS_ENV: string;
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

// --- WS frames: client -> server ---
export type ClientFrame =
  | { t: "sync"; cursors: Record<string, number> }
  | { t: "send"; chatId: string; clientMsgId: string; sentAt: number; body: unknown }
  | { t: "recv"; chatId: string; seqs: number[] }
  | { t: "read"; chatId: string; upToSeq: number }
  | { t: "typing"; chatId: string; kind: string | null }
  | { t: "delete"; chatId: string; msgIds: string[]; forAll: boolean }
  | { t: "ping" };

// --- WS frames: server -> client ---
export type ServerFrame =
  | { t: "hello"; serverTime: number }
  | { t: "sent"; chatId: string; clientMsgId: string; msgId: string; seq: number; ts: number }
  | { t: "msg"; chatId: string; seq: number; msgId: string; from: string; fromDevice: string; sentAt: number; ts: number; body: unknown }
  | { t: "receipt"; chatId: string; kind: "delivered" | "read"; upToSeq?: number; seqs?: number[]; by: string }
  | { t: "typing"; chatId: string; from: string; kind: string | null }
  | { t: "presence"; userId: string; online: boolean; lastSeen: number }
  | { t: "chat"; chatId: string; event: string; state: ChatState }
  | { t: "deleted"; chatId: string; msgIds: string[]; forAll: boolean; by: string }
  | { t: "pong" };

export interface ChatMember {
  userId: string;
  role: "admin" | "member";
  joinedAt: number;
  /// message request: false = чат в заявках, receipts/presence автору не идут
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
  deleted?: boolean;
}

export interface AuthCtx {
  userId: string;
  deviceId: string;
}

// Internal DO RPC payloads (Worker <-> DO, DO <-> DO)
export type UserEvent = ServerFrame; // events pushed into UserSessionDO for fan-out
