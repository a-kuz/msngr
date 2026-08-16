const ULID_CHARS = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export function ulid(now = Date.now()): string {
  let ts = now;
  let time = "";
  for (let i = 0; i < 10; i++) {
    time = ULID_CHARS[ts % 32] + time;
    ts = Math.floor(ts / 32);
  }
  const rnd = crypto.getRandomValues(new Uint8Array(16));
  let rand = "";
  for (let i = 0; i < 16; i++) rand += ULID_CHARS[rnd[i] % 32];
  return time + rand;
}

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromB64url(s: string): Uint8Array {
  const pad = s.replace(/-/g, "+").replace(/_/g, "/");
  const bin = atob(pad + "=".repeat((4 - (pad.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function sha256hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function newToken(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

/// Code a device being linked shows for its owner to type on a device that is
/// already on the account. Crockford base32 has no character pair a reader can
/// confuse, and 32 divides 256, so the bytes map onto it without bias.
export const PROVISION_CODE_LENGTH = 8;
export function provisionCode(): string {
  const rnd = crypto.getRandomValues(new Uint8Array(PROVISION_CODE_LENGTH));
  let out = "";
  for (const b of rnd) out += ULID_CHARS[b % 32];
  return out;
}

// Все клиент-видимые метки времени — в СЕКУНДАХ (как Date.timeIntervalSince1970 на клиенте).
// ulid хранит миллисекунды внутри себя отдельно.
export function nowSec(): number {
  return Date.now() / 1000;
}

export function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export function err(error: string, status = 400): Response {
  return json({ ok: false, error }, status);
}

// direct-чат детерминированно адресуется парой userId, чтобы дедуплицироваться
export function directChatName(a: string, b: string): string {
  return "direct:" + [a, b].sort().join(":");
}

/// Whether a drain has to be armed for `at` given the alarm the storage
/// reports as pending.
///
/// A pending time that is not in the future promises no drain: an alarm keeps
/// its stored time after it has fired, and an alarm written for a moment the
/// running handler has already reached is dropped. Treating either as "someone
/// is coming" is what leaves queued jobs undelivered, so only an alarm still
/// ahead of `now` and no later than `at` lets the caller skip.
export function shouldArmAlarm(pending: number | null, at: number, now: number): boolean {
  if (pending === null) return true;
  return !(pending > now && pending <= at);
}

export const SEQ_PAD = 10;
export function seqKey(seq: number): string {
  return "msg:" + String(seq).padStart(SEQ_PAD, "0");
}
