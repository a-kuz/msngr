import type { Env } from "../types";
import { b64url } from "../util";

// APNs token-based auth (p8, ES256). JWT кэшируется до ~50 минут.
let cachedJwt: { token: string; iat: number } | null = null;

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

async function apnsJwt(env: Env): Promise<string | null> {
  if (!env.APNS_KEY_P8 || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return null;
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt.iat < 3000) return cachedJwt.token;

  const enc = new TextEncoder();
  const header = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const payload = b64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })));
  const key = await importP8(env.APNS_KEY_P8);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    enc.encode(`${header}.${payload}`)
  );
  const token = `${header}.${payload}.${b64url(new Uint8Array(sig))}`;
  cachedJwt = { token, iat: now };
  return token;
}

export interface PushPayload {
  chatId: string;
  msgId?: string;
  badge?: number; // суммарный unread пользователя по всем чатам
}

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

export async function sendPush(
  env: Env,
  apnsToken: string,
  apnsEnv: string,
  payload: PushPayload
): Promise<boolean> {
  const base = apnsBase(env, apnsEnv);
  const isApple = /\.push\.apple\.com$/.test(new URL(base).hostname);
  // не-яблочный хост = dev-мок: без JWT-подписи, p8-ключ не нужен
  const topic = env.APNS_TOPIC ?? (isApple ? null : "ai.enface.Msngr");
  if (!topic) return false;

  const headers: Record<string, string> = {
    "apns-topic": topic,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "content-type": "application/json",
  };
  // collapse-id = msgId: повторная доставка того же сообщения не плодит баннеры
  if (payload.msgId) headers["apns-collapse-id"] = payload.msgId;
  if (isApple) {
    const jwt = await apnsJwt(env);
    if (!jwt) return false;
    headers.authorization = `bearer ${jwt}`;
  }

  // Текста сообщения в пуше нет (E2EE). mutable-content: NSE на устройстве
  // подтянет и расшифрует сообщение для превью.
  const body = {
    aps: {
      alert: { title: "Msngr", body: "Новое сообщение" },
      ...(payload.badge !== undefined ? { badge: payload.badge } : {}),
      sound: "default",
      "mutable-content": 1,
      "thread-id": payload.chatId,
    },
    chatId: payload.chatId,
    msgId: payload.msgId,
  };

  const res = await fetch(`${base}/3/device/${apnsToken}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  return res.ok;
}
