import { DurableObject } from "cloudflare:workers";
import type { Env } from "../types";
import { wrapStub } from "../perf";

/// The people-search index. `idFromName` finds an exact handle and nothing
/// near it, and search is a substring match over the handle and the display
/// name, so it needs an index of its own: a small card per account in SQLite
/// storage, spread over `DIRECTORY_SHARDS` objects by a hash of the user id. A
/// search asks every shard and merges; a card change reaches one shard. The
/// count is fixed: changing it moves cards between shards, which is a wipe.
export const DIRECTORY_SHARDS = 4;

/// The card as search returns it: what the results list shows before a profile
/// is opened. `bot_owner` and `bot_commands` tell a bot from a person.
export interface DirectoryCard {
  id: string;
  username: string;
  display_name: string;
  avatar_id: string | null;
  bot_owner: string | null;
  bot_commands: string | null;
}

/// Results a search returns, over all shards together.
export const SEARCH_LIMIT = 20;

export class DirectoryDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS people (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL,
        username_lc TEXT NOT NULL,
        display_name TEXT NOT NULL,
        display_name_lc TEXT NOT NULL,
        avatar_id TEXT,
        bot_owner TEXT,
        bot_commands TEXT
      )`);
    // Discovery by a phone number's hash is a lookup by an exact value, so it
    // needs an index of its own too. It is sharded by the hash rather than by
    // the user id: a discovery call arrives with thousands of hashes and each
    // shard is asked only for its own.
    this.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS phones (
        hash TEXT PRIMARY KEY,
        user_id TEXT NOT NULL
      )`);
  }

  /// The whole card, replacing whatever the shard held for that id.
  async put(c: DirectoryCard): Promise<void> {
    const sql = this.ctx.storage.sql;
    // folded in JS: SQLite's LOWER folds ASCII only and display names are
    // free Unicode
    sql.exec(
      `INSERT INTO people (id, username, username_lc, display_name, display_name_lc,
                           avatar_id, bot_owner, bot_commands)
       VALUES (?,?,?,?,?,?,?,?)
       ON CONFLICT(id) DO UPDATE SET
         username = excluded.username, username_lc = excluded.username_lc,
         display_name = excluded.display_name, display_name_lc = excluded.display_name_lc,
         avatar_id = excluded.avatar_id, bot_owner = excluded.bot_owner,
         bot_commands = excluded.bot_commands`,
      c.id, c.username, c.username.toLowerCase(), c.display_name,
      c.display_name.toLowerCase(), c.avatar_id, c.bot_owner, c.bot_commands,
    );
  }

  async remove(id: string): Promise<void> {
    this.ctx.storage.sql.exec("DELETE FROM people WHERE id = ?", id);
  }

  /// `userId` set claims the hash; omitted frees it. A number that changed
  /// hands answers for whoever holds it now.
  async phonePut(hash: string, userId?: string): Promise<void> {
    const sql = this.ctx.storage.sql;
    if (userId) {
      sql.exec(
        `INSERT INTO phones (hash, user_id) VALUES (?,?)
         ON CONFLICT(hash) DO UPDATE SET user_id = excluded.user_id`,
        hash, userId);
    } else {
      sql.exec("DELETE FROM phones WHERE hash = ?", hash);
    }
  }

  /// The hashes that are registered, as hash/userId pairs. Batched at the
  /// SQLite backend's 100 bound parameters per query, not the platform's
  /// 128-key storage batch: this is a SQL `IN (...)`, a smaller ceiling.
  async phoneFind(hashes: string[]): Promise<{ found: Array<{ hash: string; user_id: string }> }> {
    const sql = this.ctx.storage.sql;
    const found: Array<{ hash: string; user_id: string }> = [];
    for (let i = 0; i < hashes.length; i += 100) {
      const part = hashes.slice(i, i + 100);
      const marks = part.map(() => "?").join(",");
      found.push(...(sql.exec(
        `SELECT hash, user_id FROM phones WHERE hash IN (${marks})`, ...part,
      ).toArray() as unknown as Array<{ hash: string; user_id: string }>));
    }
    return { found };
  }

  /// `q` folded by the caller. Exact handle matches come first, then by
  /// handle; the caller merges the shards by the same rule.
  async search(q: string): Promise<{ users: DirectoryCard[] }> {
    const sql = this.ctx.storage.sql;
    const like = `%${q}%`;
    const rows = sql.exec(
      `SELECT id, username, display_name, avatar_id, bot_owner, bot_commands
       FROM people
       WHERE username_lc LIKE ? OR display_name_lc LIKE ?
       ORDER BY CASE WHEN username_lc = ? THEN 0 ELSE 1 END, username
       LIMIT ?`,
      like, like, q, SEARCH_LIMIT,
    ).toArray() as unknown as DirectoryCard[];
    return { users: rows };
  }
}

function shardOf(key: string): number {
  // FNV-1a over the key: stable across isolates, cheap, spreads ULIDs and
  // hex digests evenly alike
  let h = 0x811c9dc5;
  for (let i = 0; i < key.length; i++) {
    h ^= key.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h % DIRECTORY_SHARDS;
}

function shardStub(env: Env, shard: number) {
  return wrapStub(env.DIRECTORY_DO.get(env.DIRECTORY_DO.idFromName(`shard:${shard}`)));
}

export async function directoryPut(env: Env, card: DirectoryCard): Promise<void> {
  await shardStub(env, shardOf(card.id)).put(card);
}

export async function directoryRemove(env: Env, userId: string): Promise<void> {
  await shardStub(env, shardOf(userId)).remove(userId);
}

/// Puts a phone hash on the account that publishes it, or takes it off the
/// index when `userId` is null.
export async function phoneIndexPut(
  env: Env, hash: string, userId: string | null,
): Promise<void> {
  await shardStub(env, shardOf(hash)).phonePut(hash, userId ?? undefined);
}

/// The accounts behind the hashes that are registered: hash to user id. Every
/// shard is asked only for the hashes that belong to it.
export async function phoneIndexFind(
  env: Env, hashes: string[],
): Promise<Map<string, string>> {
  const byShard = new Map<number, string[]>();
  for (const h of hashes) {
    const s = shardOf(h);
    (byShard.get(s) ?? byShard.set(s, []).get(s)!).push(h);
  }
  const out = new Map<string, string>();
  await Promise.all([...byShard].map(async ([shard, part]) => {
    const { found } = await shardStub(env, shard).phoneFind(part);
    for (const row of found) out.set(row.hash, row.user_id);
  }));
  return out;
}

/// A substring search over every shard, merged: exact handle first, then by
/// handle, cut to `SEARCH_LIMIT`. `q` arrives folded.
export async function directorySearch(env: Env, q: string): Promise<DirectoryCard[]> {
  const shards = Array.from({ length: DIRECTORY_SHARDS }, (_, i) => i);
  const parts = await Promise.all(shards.map(async (s) => (await shardStub(env, s).search(q)).users));
  const rank = (u: DirectoryCard) => (u.username.toLowerCase() === q ? 0 : 1);
  return parts.flat()
    .sort((a, b) => rank(a) - rank(b) || (a.username < b.username ? -1 : a.username > b.username ? 1 : 0))
    .slice(0, SEARCH_LIMIT);
}
