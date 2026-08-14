export interface Env {
  DB: D1Database;
  MEDIA: R2Bucket;
  USER_DO: DurableObjectNamespace;
  CONV_DO: DurableObjectNamespace;
  APNS_ENV: string;
  /// Переопределение APNs-эндпоинта (dev-мок, например http://localhost:9871);
  /// не задан — прод/sandbox Apple по apns-env устройства.
  APNS_HOST?: string;
  /// Искусственная задержка (мс) перед fanout в ConversationDO /send (dev).
  DEV_WS_LATENCY_MS?: string;
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_TOPIC?: string;
}

// --- WS frames: client -> server ---
export type ClientFrame =
  | { t: "sync"; cursors: Record<string, number> }
  // service: служебный фрейм (skd/reaction/edit и т.п.) — не должен растить unread/бейдж
  | { t: "send"; chatId: string; clientMsgId: string; sentAt: number; body: unknown; service?: boolean }
  | { t: "recv"; chatId: string; seqs: number[] }
  | { t: "read"; chatId: string; upToSeq: number }
  | { t: "typing"; chatId: string; kind: string | null }
  | { t: "delete"; chatId: string; msgIds: string[]; forAll: boolean }
  | { t: "ping" }
  | { t: "bg" }   // приложение ушло в фон: presence offline немедленно
  | { t: "fg" };  // вернулось: presence online

// --- WS frames: server -> client ---
export type ServerFrame =
  | { t: "hello"; serverTime: number }
  | { t: "sent"; chatId: string; clientMsgId: string; msgId: string; seq: number; ts: number }
  | { t: "msg"; chatId: string; seq: number; msgId: string; from: string; fromDevice: string; sentAt: number; ts: number; body: unknown; service?: boolean }
  | { t: "receipt"; chatId: string; kind: "delivered" | "read"; upToSeq?: number; seqs?: number[]; by: string }
  | { t: "typing"; chatId: string; from: string; kind: string | null }
  | { t: "presence"; userId: string; online: boolean; lastSeen: number }
  | { t: "chat"; chatId: string; event: string; state: ChatState }
  | { t: "deleted"; chatId: string; msgIds: string[]; forAll: boolean; by: string }
  /// отказ по клиентскому фрейму: error — машиночитаемый код
  | { t: "error"; error: string; chatId?: string; clientMsgId?: string }
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
  service?: boolean;
  deleted?: boolean;
  deletedBy?: string;
  /// userId получателя, который заблокировал автора: этому участнику сообщение
  /// не рассылается и не отдаётся в истории
  blockedFor?: string;
}

export interface AuthCtx {
  userId: string;
  deviceId: string;
}

// Internal DO RPC payloads (Worker <-> DO, DO <-> DO)
export type UserEvent = ServerFrame; // events pushed into UserSessionDO for fan-out
