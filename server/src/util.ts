import { verifyAsync as ed25519VerifyAsync } from "@noble/ed25519";
import type { PrivacySettings, PublicUser } from "./types";

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

/// A bearer token: the account it belongs to, a dot, and the secret. Nothing
/// outside a user's own object knows which devices exist, so the token has to
/// name the object that can answer for it; the secret is what the answer is
/// checked against, and the stored hash covers the whole token, so a secret
/// lifted from one account proves nothing on another.
export function newToken(userId: string): string {
  return userId + "." + b64url(crypto.getRandomValues(new Uint8Array(32)));
}

/// The account a token names, or null when it is not one of ours.
export function tokenOwner(token: string): string | null {
  const dot = token.indexOf(".");
  if (dot <= 0 || dot === token.length - 1) return null;
  return token.slice(0, dot);
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

/// The defaults a user who never opened the privacy screen is read with.
export const PRIVACY_DEFAULTS: PrivacySettings = {
  lastSeen: "everyone", avatar: "everyone", phoneDiscovery: "everyone",
  groupInvites: "everyone", callPrivacy: "everyone", readReceipts: true, typing: true,
};

/// Every read that goes to another person's object needs only the namespace.
type Objects = { USER_DO: DurableObjectNamespace };

export function userStub(env: Objects, userId: string) {
  return env.USER_DO.get(env.USER_DO.idFromName(userId));
}

/// The settings a privacy question can be asked about.
export type PrivacySetting =
  "last_seen" | "avatar" | "phone_discovery" | "group_invites" | "call";

/// A user's privacy settings, from their own object. Shared by the worker (for
/// the REST endpoint) and ConversationDO (for gating receipts and typing).
export async function readPrivacy(env: Objects, userId: string): Promise<PrivacySettings> {
  const r = await userStub(env, userId).fetch("https://do/privacy-read");
  const j = (await r.json()) as { privacy?: PrivacySettings };
  return j.privacy ?? PRIVACY_DEFAULTS;
}

/// One question every tier answers: may `viewerId` see `ownerId`'s `setting`?
/// The owner's object decides — the tier, the named exceptions and the address
/// book that "contacts" means are all its own storage — so the whole judgement
/// is one call, whoever asks.
export async function privacyAllows(
  env: Objects, ownerId: string, viewerId: string, setting: PrivacySetting,
): Promise<boolean> {
  if (ownerId === viewerId) return true;
  return (await privacyChecks(env, ownerId, viewerId, [setting]))[setting];
}

/// Several of the same owner's settings in one call: a user card wants the
/// photo rule and the call rule together.
export async function privacyChecks(
  env: Objects, ownerId: string, viewerId: string, settings: PrivacySetting[],
): Promise<Record<string, boolean>> {
  if (ownerId === viewerId) return Object.fromEntries(settings.map((s) => [s, true]));
  const r = await userStub(env, ownerId).fetch("https://do/privacy-check", {
    method: "POST", body: JSON.stringify({ viewerId, settings }),
  });
  const j = (await r.json()) as { allow?: Record<string, boolean> };
  return j.allow ?? Object.fromEntries(settings.map((s) => [s, false]));
}

/// One person's card as `viewerId` may see it: the owner's object blanks the
/// photo and the bio when its own rule closes them to this viewer.
export async function cardFor(
  env: Objects, viewerId: string, targetId: string,
): Promise<PublicUser | null> {
  const r = await userStub(env, targetId).fetch(
    `https://do/card?viewer=${encodeURIComponent(viewerId)}`);
  if (!r.ok) return null;
  const j = (await r.json()) as { user: PublicUser | null };
  return j.user;
}

/// A user avatar's id carries its owner: the bytes route has to apply that
/// person's own rule to whoever asks for them, and there is no index from a
/// blob back to an account. A chat avatar has no owner part.
export function userAvatarId(userId: string): string {
  return `avatar-${userId}-${ulid()}`;
}

export function avatarOwner(mediaId: string): string | null {
  const m = /^avatar-([0-9A-HJKMNP-TV-Z]{26})-/.exec(mediaId);
  return m ? m[1] : null;
}

/// The same for a list of people, asked of every object at once.
export async function cardsFor(
  env: Objects, viewerId: string, ids: string[],
): Promise<Map<string, PublicUser>> {
  const out = new Map<string, PublicUser>();
  const cards = await Promise.all(ids.map((id) => cardFor(env, viewerId, id)));
  for (const card of cards) if (card) out.set(card.id, card);
  return out;
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
