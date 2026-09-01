import type { Env } from "./types";
import { readPrivacy } from "./util";

/// A chat with more members than this builds no presence relations among
/// them: a roster of n makes n² of them, and a member list that large is
/// read, not watched.
export const PRESENCE_GROUP_MAX = 100;

/// D1 binds at most 100 parameters to one statement.
const IN_CHUNK = 90;

function chunks<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

/// Which of `viewers` may see `ownerId`'s presence. Decided at the source, in
/// a handful of statements whatever the number of viewers: the owner's tier
/// and named exceptions, blocks in either direction, viewers who hid their own
/// last seen (hiding yours blinds you to everyone else's), and for the
/// "contacts" tier whether the viewer's phone hash is in the owner's book —
/// `inBook` answers that from the owner's own object.
export async function presenceViewers(
  env: Env, ownerId: string, viewers: string[],
  inBook: (hashes: string[]) => Promise<Set<string>>,
): Promise<Set<string>> {
  const out = new Set<string>();
  if (!viewers.length) return out;
  const tier = (await readPrivacy(env.DB, ownerId)).lastSeen;
  const exceptions = await env.DB.prepare(
    "SELECT peer_id, allow FROM privacy_exceptions WHERE user_id = ? AND setting = 'last_seen'"
  ).bind(ownerId).all<{ peer_id: string; allow: number }>();
  const named = new Map(exceptions.results.map((r) => [r.peer_id, r.allow === 1]));
  const blocked = await env.DB.prepare(
    `SELECT blocked_id AS id FROM blocks WHERE user_id = ?
     UNION SELECT user_id AS id FROM blocks WHERE blocked_id = ?`
  ).bind(ownerId, ownerId).all<{ id: string }>();
  const blockedIds = new Set(blocked.results.map((r) => r.id));
  const blind = new Set<string>();
  const hashes = new Map<string, string>();
  for (const part of chunks(viewers, IN_CHUNK)) {
    const ph = part.map(() => "?").join(",");
    const rows = await env.DB.prepare(
      `SELECT user_id FROM privacy_settings WHERE last_seen = 'nobody' AND user_id IN (${ph})`
    ).bind(...part).all<{ user_id: string }>();
    for (const r of rows.results) blind.add(r.user_id);
    if (tier === "contacts") {
      const hr = await env.DB.prepare(
        `SELECT id, phone_hash FROM users WHERE phone_hash IS NOT NULL AND id IN (${ph})`
      ).bind(...part).all<{ id: string; phone_hash: string }>();
      for (const r of hr.results) hashes.set(r.id, r.phone_hash);
    }
  }
  const book = tier === "contacts" && hashes.size ? await inBook([...hashes.values()]) : new Set<string>();
  for (const v of viewers) {
    if (v === ownerId || blockedIds.has(v) || blind.has(v)) continue;
    const exception = named.get(v);
    if (exception !== undefined) {
      if (exception) out.add(v);
      continue;
    }
    if (tier === "everyone") {
      out.add(v);
    } else if (tier === "contacts") {
      const h = hashes.get(v);
      if (h && book.has(h)) out.add(v);
    }
  }
  return out;
}
