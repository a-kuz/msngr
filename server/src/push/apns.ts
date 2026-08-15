import type { Env } from "../types";
import { b64url } from "../util";

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

/// Подпись APNs-токена (p8, ES256). Единственный вызывающий — ApnsTokenDO:
/// владелец минтинга должен быть один, Apple ограничивает его частоту.
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
  msgId?: string;
  seq?: number; // позиция сообщения в чате: по ней клиент выстраивает порядок показа
  sentAt?: number; // время отправки, мс: порядок между чатами
  badge?: number; // суммарный unread пользователя по всем чатам
  /// Position of `badge` in the sequence of numbers this user's object
  /// produced. APNs delivers a burst in an arbitrary order, so the device
  /// needs it to tell a fresh count from one that overtook it.
  badgeStamp?: number;
}

export interface PushResult {
  ok: boolean;
  /// HTTP-статус APNs; 0 — ответа не было
  status: number;
  /// reason из тела ответа APNs
  reason?: string;
  /// токен устройства больше не действителен, его надо удалить
  dead?: boolean;
}

// Лестница повторов на 429 и 5xx.
const RETRY_DELAYS_MS = [500, 1500];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// База APNs: env.APNS_HOST (dev-мок вроде http://localhost:9871),
// иначе прод/sandbox Apple по apns-env устройства.
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
  // не-яблочный хост = dev-мок: без JWT-подписи, p8-ключ не нужен
  const topic = env.APNS_TOPIC ?? (isApple ? null : "ai.enface.Msngr");
  if (!topic) return { ok: false, status: 0, reason: "no_topic" };

  // Текста сообщения в пуше нет (E2EE). mutable-content: NSE на устройстве
  // подтянет и расшифрует сообщение для превью.
  const body = JSON.stringify({
    aps: {
      alert: { title: "Msngr", body: "Новое сообщение" },
      ...(payload.badge !== undefined ? { badge: payload.badge } : {}),
      sound: "default",
      "mutable-content": 1,
      "thread-id": payload.chatId,
    },
    chatId: payload.chatId,
    msgId: payload.msgId,
    // seq and sentAt let the extension order a burst of pushes: APNs delivers
    // them in an arbitrary order, and the banner order is the posting order.
    seq: payload.seq,
    sentAt: payload.sentAt,
    badgeStamp: payload.badgeStamp,
  });

  let forceJwt = false;
  for (let attempt = 0; ; attempt++) {
    const headers: Record<string, string> = {
      "apns-topic": topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    };
    // collapse-id = msgId: повторная доставка того же сообщения не плодит баннеры
    if (payload.msgId) headers["apns-collapse-id"] = payload.msgId;
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
      console.log(`apns: сеть не ответила после ${attempt + 1} попыток: ${String(e)}`);
      return { ok: false, status: 0, reason: "network" };
    }

    if (res.ok) return { ok: true, status: res.status };
    const reason = await readReason(res);

    if (res.status === 410) {
      console.log(`apns: 410 ${reason ?? "Unregistered"} — токен устройства мёртв`);
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
    console.log(`apns: отказ ${res.status} ${reason ?? "без reason"}`);
    return { ok: false, status: res.status, reason };
  }
}
