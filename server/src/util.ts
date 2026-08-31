import { verifyAsync as ed25519VerifyAsync } from "@noble/ed25519";
import type { PrivacySettings, LastSeenVisibility } from "./types";

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

// Every client-visible timestamp is in SECONDS, matching Date.timeIntervalSince1970 on the
// client. The milliseconds ulid keeps inside itself are a separate thing.
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

// A direct chat is addressed by its pair of userIds, so both sides land on the same object
export function directChatName(a: string, b: string): string {
  return "direct:" + [a, b].sort().join(":");
}

/// The handle a person is found by. Registration and a later rename apply the
/// same rule, and it matches `RegistrationValidator.isValidUsername` on the
/// client; uniqueness is the UNIQUE COLLATE NOCASE index on users.username.
export function isValidUsername(username: unknown): username is string {
  return typeof username === "string" && /^[a-zA-Z0-9_]{3,32}$/.test(username);
}

/// How long a username a rename frees stays out of circulation for everyone
/// but the person who freed it (`released_usernames.released_by`).
export const USERNAME_QUARANTINE_MS = 14 * 24 * 60 * 60 * 1000;

/// The name a peer reads in their chat list. Required: it is the only place a
/// person's own spelling of their name can live, and every screen renders it
/// with no fallback. Trimmed length, so spaces alone are not a name.
export const DISPLAY_NAME_MAX = 64;
export function isValidDisplayName(name: unknown): name is string {
  if (typeof name !== "string") return false;
  const trimmed = name.trim();
  return trimmed.length >= 1 && trimmed.length <= DISPLAY_NAME_MAX;
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

/// A user's privacy row, or the defaults if they never set one. Shared by the
/// worker (for the REST endpoint and presence visibility) and ConversationDO
/// (for gating receipts, typing and presence fanout).
export async function readPrivacy(db: D1Database, userId: string): Promise<PrivacySettings> {
  const row = await db.prepare(
    `SELECT last_seen, avatar_visibility, phone_discovery, group_invites, call_privacy,
       read_receipts, typing
     FROM privacy_settings WHERE user_id = ?`
  ).bind(userId).first<{
    last_seen: string; avatar_visibility: string; phone_discovery: string;
    group_invites: string; call_privacy: string; read_receipts: number; typing: number;
  }>();
  if (!row) {
    return { lastSeen: "everyone", avatar: "everyone", phoneDiscovery: "everyone",
             groupInvites: "everyone", callPrivacy: "everyone", readReceipts: true, typing: true };
  }
  return {
    lastSeen: row.last_seen as PrivacySettings["lastSeen"],
    avatar: row.avatar_visibility as PrivacySettings["avatar"],
    phoneDiscovery: row.phone_discovery as PrivacySettings["phoneDiscovery"],
    groupInvites: row.group_invites as PrivacySettings["groupInvites"],
    callPrivacy: row.call_privacy as PrivacySettings["callPrivacy"],
    readReceipts: row.read_receipts === 1,
    typing: row.typing === 1,
  };
}

/// Whether `viewerId` is in `ownerId`'s address book. The book is a set of
/// phone hashes in the owner's object; the viewer's current hash is read
/// here, so a number registering or changing hands needs no propagation.
export async function isContactOf(
  env: { DB: D1Database; USER_DO: DurableObjectNamespace },
  ownerId: string, viewerId: string
): Promise<boolean> {
  const row = await env.DB.prepare("SELECT phone_hash FROM users WHERE id = ?")
    .bind(viewerId).first<{ phone_hash: string | null }>();
  if (!row?.phone_hash) return false;
  const stub = env.USER_DO.get(env.USER_DO.idFromName(ownerId));
  const res = await stub.fetch(
    `https://do/contact-of?hash=${encodeURIComponent(row.phone_hash)}`);
  const r = (await res.json()) as { contact: boolean };
  return r.contact;
}

/// One question every tier answers: may `viewerId` see `ownerId`'s `setting`?
/// A named exception decides first — an allow row opens it whatever the tier
/// says, a deny row closes it the same way — and only then the tier itself:
/// everyone, contacts (the owner's synced book), nobody.
export async function privacyAllows(
  env: { DB: D1Database; USER_DO: DurableObjectNamespace },
  ownerId: string, viewerId: string,
  setting: "last_seen" | "avatar" | "phone_discovery" | "group_invites" | "call",
  tier: LastSeenVisibility
): Promise<boolean> {
  if (ownerId === viewerId) return true;
  const exception = await env.DB.prepare(
    "SELECT allow FROM privacy_exceptions WHERE user_id = ? AND setting = ? AND peer_id = ?"
  ).bind(ownerId, setting, viewerId).first<{ allow: number }>();
  if (exception) return exception.allow === 1;
  if (tier === "everyone") return true;
  if (tier === "nobody") return false;
  return isContactOf(env, ownerId, viewerId);
}

/// The user ids among `ids` whose profile photo and bio are hidden from this
/// viewer: "nobody" hides from everyone, "contacts" from whoever the owner
/// does not hold in their own address book, either way overridden by the
/// owner's named exceptions.
export async function hiddenAvatarOwners(
  env: { DB: D1Database; USER_DO: DurableObjectNamespace },
  viewerId: string, ids: string[]
): Promise<Set<string>> {
  const hidden = new Set<string>();
  if (!ids.length) return hidden;
  const placeholders = ids.map(() => "?").join(",");
  const restricted = await env.DB.prepare(
    `SELECT user_id, avatar_visibility FROM privacy_settings
     WHERE avatar_visibility != 'everyone' AND user_id IN (${placeholders})`
  ).bind(...ids).all<{ user_id: string; avatar_visibility: string }>();
  const denied = await env.DB.prepare(
    `SELECT user_id FROM privacy_exceptions
     WHERE setting = 'avatar' AND allow = 0 AND peer_id = ? AND user_id IN (${placeholders})`
  ).bind(viewerId, ...ids).all<{ user_id: string }>();
  const candidates = new Map(restricted.results.map((r) => [r.user_id, r.avatar_visibility]));
  for (const row of denied.results) candidates.set(row.user_id, "nobody-exception");
  for (const [ownerId, tierRaw] of candidates) {
    if (ownerId === viewerId) continue;
    const tier = (tierRaw === "nobody-exception" ? "nobody" : tierRaw) as LastSeenVisibility;
    if (!(await privacyAllows(env, ownerId, viewerId, "avatar", tier))) hidden.add(ownerId);
  }
  return hidden;
}

export const SEQ_PAD = 10;
export function seqKey(seq: number): string {
  return "msg:" + String(seq).padStart(SEQ_PAD, "0");
}

/// Proves a restore claim holds the account's identity private key: `pubKeyB64url`
/// is the Ed25519 public half already on file for the account, `message` is the
/// restore session's own nonce, never reused across sessions.
export async function verifyEd25519(
  pubKeyB64url: string, signatureB64url: string, message: Uint8Array
): Promise<boolean> {
  try {
    return await ed25519VerifyAsync(fromB64url(signatureB64url), message, fromB64url(pubKeyB64url));
  } catch {
    return false;
  }
}
