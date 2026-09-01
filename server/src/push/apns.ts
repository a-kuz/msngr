import type { Env } from "../types";
import { b64url, sha256hex } from "../util";

async function importP8(p8: string): Promise<CryptoKey> {
  const body = p8
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
}

/// Signs an APNs provider token (p8, ES256). The only caller is ApnsTokenDO: minting
/// needs a single owner, because Apple limits how often a token may be issued.
export async function mintApnsJwt(env: Env, iat: number): Promise<string | null> {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return null;
  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const payload = b64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat })));
  const key = await importP8(env.APNS_KEY_P8);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    enc.encode(`${header}.${payload}`)
  );
  return `${header}.${payload}.${b64url(new Uint8Array(sig))}`;
}

async function apnsJwt(env: Env, force: boolean): Promise<string | null> {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return null;
  const stub = env.APNS_DO.get(env.APNS_DO.idFromName("apns-jwt"));
  const r = await stub.fetch(`https://do/jwt${force ? "?force=1" : ""}`);
  const j = (await r.json()) as { ok: boolean; token?: string };
  return j.ok ? j.token ?? null : null;
}

export interface PushPayload {
  chatId: string;
  /// APNs sound name: a caf file bundled with the app, "default", or "none"
  /// for a silent push. Resolved by the sender's object from the chat's own
  /// sound, then the user's direct/group default.
  sound?: string;
  seq?: number; // position of the message in its chat; the client shows a burst in this order
  sentAt?: number; // send time in ms, which orders messages across chats
  badge?: number; // the user's total unread over all chats
  /// Position of `badge` in the sequence of numbers this user's object
  /// produced. APNs delivers a burst in an arbitrary order, so the device
  /// needs it to tell a fresh count from one that overtook it.
  badgeStamp?: number;
  /// Author of the message: the device needs both to pick its ciphertext out of
  /// the envelope and to step the right session.
  from?: string;
  fromDevice?: string;
  /// Server clock of the message, as the socket carries it.
  ts?: number;
  /// The E2E envelope, addressed to this one device, as compact JSON. The
  /// extension decrypts it and writes the message, so a message read in a
  /// banner is in the chat afterwards even if the socket never comes up. It is
  /// dropped when the payload would not fit; the message then arrives on the
  /// next connection.
  env?: string;
  /// A ready alert for a push that is not a chat message — being added to a
  /// group, and the like. It carries no envelope and nothing for the extension
  /// to decrypt: the text is shown as it is.
  alert?: { title: string; body: string };
}

/// APNs refuses a payload over this size, and a refusal is a notification the
/// device never sees.
export const APNS_PAYLOAD_LIMIT = 4096;

/// The part of an envelope this device can open: a pairwise envelope carries a
/// box per recipient device, and the rest of them are dead weight in a payload
/// with four kilobytes to spend. A sender-key envelope has one ciphertext for
/// the whole group and travels whole.
export function envelopeForDevice(body: unknown, address: string): string | undefined {
  if (!body || typeof body !== "object") return undefined;
  const env = body as { mode?: string; msgs?: Record<string, unknown> };
  if (env.mode !== "pw") return JSON.stringify(env);
  const box = env.msgs?.[address];
  if (!box) return undefined;
  return JSON.stringify({ ...env, msgs: { [address]: box } });
}

/// A silent choice carries no sound field at all: the system then posts the
/// banner without playing anything, whether the extension ran or not.
function soundField(sound?: string): { sound?: string } {
  if (sound === "none") return {};
  return { sound: sound ?? "default" };
}

/// The APNs body of one push. The envelope is the first thing to go when the
/// payload does not fit: everything else is what orders the burst and counts
/// the badge.
export function pushBody(payload: PushPayload): string {
  if (payload.alert) {
    return JSON.stringify({
      aps: {
        alert: payload.alert,
        ...(payload.badge !== undefined ? { badge: payload.badge } : {}),
        ...soundField(payload.sound),
        "thread-id": payload.chatId,
      },
      chatId: payload.chatId,
      badgeStamp: payload.badgeStamp,
    });
  }
  const build = (env?: string) =>
    JSON.stringify({
      aps: {
        alert: { title: "Msngr", body: "Новое сообщение" },
        ...(payload.badge !== undefined ? { badge: payload.badge } : {}),
        ...soundField(payload.sound),
        "mutable-content": 1,
        "thread-id": payload.chatId,
      },
      chatId: payload.chatId,
      // seq and sentAt let the extension order a burst of pushes: APNs delivers
      // them in an arbitrary order, and the banner order is the posting order.
      seq: payload.seq,
      sentAt: payload.sentAt,
      badgeStamp: payload.badgeStamp,
      from: payload.from,
      fromDevice: payload.fromDevice,
      ts: payload.ts,
      env,
    });
  const full = build(payload.env);
  if (new TextEncoder().encode(full).length <= APNS_PAYLOAD_LIMIT) return full;
  return build(undefined);
}

export interface PushResult {
  ok: boolean;
  /// APNs HTTP status; 0 means no response arrived
  status: number;
  /// reason from the APNs response body
  reason?: string;
  /// the device token is no longer valid and has to be dropped
  dead?: boolean;
}

// Retry ladder for 429 and 5xx.
const RETRY_DELAYS_MS = [500, 1500];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function apnsBase(env: Env, apnsEnv: string): string {
  if (env.APNS_HOST) {
    const h = env.APNS_HOST.replace(/\/+$/, "");
    return h.includes("://") ? h : `https://${h}`;
  }
  return apnsEnv === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
}

async function readReason(res: Response): Promise<string | undefined> {
  try {
    const text = await res.text();
    if (!text) return undefined;
    return (JSON.parse(text) as { reason?: string }).reason;
  } catch {
    return undefined;
  }
}

export async function sendPush(
  env: Env,
  apnsToken: string,
  apnsEnv: string,
  payload: PushPayload
): Promise<PushResult> {
  const base = apnsBase(env, apnsEnv);
  const isApple = /\.push\.apple\.com$/.test(new URL(base).hostname);
  // a non-Apple host is the dev mock: it takes no JWT, so no p8 key is needed
  const topic = env.APNS_TOPIC ?? (isApple ? null : "msngr.msngr");
  if (!topic) return { ok: false, status: 0, reason: "no_topic" };

  // The alert text is neutral: the payload carries ciphertext, and the
  // extension replaces the text with what it decrypts (mutable-content).
  const body = pushBody(payload);

  // collapse-id names the message, so redelivering it does not stack up
  // banners. (chatId, seq) is the identity, but the header caps at 64 bytes
  // and a direct chat id alone runs to 60, so the chat travels as a hash.
  const collapseId = payload.seq === undefined
    ? undefined
    : `${(await sha256hex(payload.chatId)).slice(0, 16)}:${payload.seq}`;

  let forceJwt = false;
  for (let attempt = 0; ; attempt++) {
    const headers: Record<string, string> = {
      "apns-topic": topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    };
    if (collapseId) headers["apns-collapse-id"] = collapseId;
    if (isApple) {
      const jwt = await apnsJwt(env, forceJwt);
      if (!jwt) return { ok: false, status: 0, reason: "no_jwt" };
      headers.authorization = `bearer ${jwt}`;
    }

    let res: Response;
    try {
      res = await fetch(`${base}/3/device/${apnsToken}`, { method: "POST", headers, body });
    } catch (e) {
      if (attempt < RETRY_DELAYS_MS.length) {
        await sleep(RETRY_DELAYS_MS[attempt]);
        continue;
      }
      console.log(`apns: no response after ${attempt + 1} attempts: ${String(e)}`);
      return { ok: false, status: 0, reason: "network" };
    }

    if (res.ok) return { ok: true, status: res.status };
    const reason = await readReason(res);

    if (res.status === 410) {
      console.log(`apns: 410 ${reason ?? "Unregistered"}, device token is dead`);
      return { ok: false, status: 410, reason, dead: true };
    }
    if (res.status === 403 && reason === "ExpiredProviderToken" && !forceJwt) {
      forceJwt = true;
      continue;
    }
    if ((res.status === 429 || res.status >= 500) && attempt < RETRY_DELAYS_MS.length) {
      await sleep(RETRY_DELAYS_MS[attempt]);
      continue;
    }
    console.log(`apns: rejected ${res.status} ${reason ?? "no reason"}`);
    return { ok: false, status: res.status, reason };
  }
}
