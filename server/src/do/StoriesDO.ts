import { DurableObject } from "cloudflare:workers";
import type { Env, PublicUser } from "../types";
import { DOError, ulid, b64url, shouldArmAlarm, withTimeout } from "../util";
import { wrapStub } from "../perf";

/// One object per author, addressed by `idFromName(userId)`: their stories,
/// who watched each, who left a heart, the public link codes, and the fan-out
/// queue that carries every story to the people it is for. A story is not
/// end-to-end encrypted — who may see one is an access rule — so the object
/// holds the frames as the composer built them and hands them out unchanged.
///
/// Nothing about a story is asked for at read time. When one is published the
/// Worker names its recipients, and this object delivers the story into each
/// recipient's own UserDO, which keeps it in an inbox and tells that person's
/// sockets. A watch or a heart lands here, in the author's object, and the
/// new counts leave for the author's UserDO the same way; a story taken down
/// leaves as a removal to everyone who got it. Each delivery is a row in a
/// queue pumped by this object's alarm: a failure moves the row's deadline out
/// on a growing pause and is never given up.

/// A story as the object keeps it.
export interface StoryRecord {
  id: string;
  created_at: number;
  expires_at: number;
  frames: string;
  audience: string;
  link_code: string | null;
  link_revoked: number;
  taken_down: number;
}

/// A queued delivery to one recipient's UserDO.
interface Delivery {
  id: number;
  story_id: string;
  user_id: string;
  kind: "new" | "removed" | "stats";
  attempt: number;
  next_at: number;
}

/// Pause before the next try of a delivery that failed, by the tries already
/// failed; the last value repeats until it lands.
const RETRY_MS = [1_000, 5_000, 15_000, 60_000, 300_000];
/// Deliveries one alarm run sends before re-arming for the rest.
const DRAIN = 50;
const DELIVERY_TIMEOUT_MS = 5_000;

/// A story's id carries the author in front of a `~`, so any request naming
/// one finds the object without an index. A public link's code carries
/// nothing: the page must not name the author, so the code is random and an
/// object of this class named by the code points at the author instead.
export function authorOf(storyId: string): string | null {
  const cut = storyId.indexOf("~");
  return cut > 0 ? storyId.slice(0, cut) : null;
}

function newLinkCode(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(9)));
}

export function storiesStub(env: Env, authorId: string) {
  return wrapStub(env.STORIES_DO.get(env.STORIES_DO.idFromName(`author:${authorId}`)));
}

function linkStub(env: Env, code: string) {
  return wrapStub(env.STORIES_DO.get(env.STORIES_DO.idFromName(`link:${code}`)));
}

/// Mints a code and makes it point at the author.
async function mintLinkCode(env: Env, authorId: string): Promise<string> {
  const code = newLinkCode();
  await linkStub(env, code).point(authorId);
  return code;
}

/// Whose stories a public link's code belongs to, if it was ever minted.
export async function authorOfLink(env: Env, code: string): Promise<string | null> {
  try {
    return (await linkStub(env, code).pointer()).author;
  } catch {
    return null;
  }
}

/// What a recipient's UserDO is handed: the story as the recipient will keep
/// it, with the author's card so the frame names them without a lookup.
export interface StoryDelivery {
  kind: "new" | "removed" | "stats";
  storyId: string;
  authorId: string;
  story?: {
    createdAt: number; expiresAt: number; frames: unknown[]; audience: string; link: string | null;
    author: PublicUser;
  };
  views?: number;
  likes?: number;
}

export class StoriesDO extends DurableObject<Env> {
  private alarmRunning = false;
  private rearmDelay: number | undefined;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = this.ctx.storage.sql;
    sql.exec(`
      CREATE TABLE IF NOT EXISTS stories (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        frames TEXT NOT NULL,
        audience TEXT NOT NULL,
        link_code TEXT,
        link_revoked INTEGER NOT NULL DEFAULT 0,
        taken_down INTEGER NOT NULL DEFAULT 0,
        author_card TEXT,
        origin TEXT
      )`);
    // an object created before these two columns existed grows them here;
    // SQLite has no "add column if absent", so the failure of an add that
    // finds the column is the normal case
    for (const column of ["author_card TEXT", "origin TEXT"]) {
      try { sql.exec(`ALTER TABLE stories ADD COLUMN ${column}`); } catch { /* already there */ }
    }
    sql.exec(`
      CREATE TABLE IF NOT EXISTS views (
        story_id TEXT NOT NULL,
        viewer_id TEXT NOT NULL,
        seen_at INTEGER NOT NULL,
        PRIMARY KEY (story_id, viewer_id)
      )`);
    sql.exec(`
      CREATE TABLE IF NOT EXISTS likes (
        story_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        liked_at INTEGER NOT NULL,
        PRIMARY KEY (story_id, user_id)
      )`);
    // who each story was delivered to: a removal goes exactly there
    sql.exec(`
      CREATE TABLE IF NOT EXISTS recipients (
        story_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        PRIMARY KEY (story_id, user_id)
      )`);
    sql.exec(`
      CREATE TABLE IF NOT EXISTS deliveries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        story_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 0,
        next_at INTEGER NOT NULL
      )`);
  }

  /// The story if it is still there to be watched: not taken down, its time
  /// not over.
  private live(id: string, now: number): StoryRecord | null {
    const row = this.ctx.storage.sql.exec(
      "SELECT * FROM stories WHERE id = ? AND taken_down = 0 AND expires_at > ?", id, now,
    ).toArray()[0] as unknown as StoryRecord | undefined;
    return row ?? null;
  }

  private counts(storyId: string): { views: number; likes: number } {
    const sql = this.ctx.storage.sql;
    const views = sql.exec("SELECT COUNT(*) AS n FROM views WHERE story_id = ?", storyId)
      .toArray()[0] as unknown as { n: number };
    const likes = sql.exec("SELECT COUNT(*) AS n FROM likes WHERE story_id = ?", storyId)
      .toArray()[0] as unknown as { n: number };
    return { views: views.n, likes: likes.n };
  }

  // MARK: - The fan-out queue

  /// Queues one delivery per recipient and starts the pump behind the request.
  private async enqueue(storyId: string, users: string[], kind: Delivery["kind"]) {
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    for (const u of users) {
      sql.exec(
        "INSERT INTO deliveries (story_id, user_id, kind, attempt, next_at) VALUES (?,?,?,0,?)",
        storyId, u, kind, now,
      );
    }
    // strictly in the future, so the write is never mistaken for the alarm
    // that is running right now
    await this.arm(1);
  }

  private async arm(delayMs: number) {
    if (this.alarmRunning) {
      this.rearmDelay = this.rearmDelay === undefined ? delayMs : Math.min(this.rearmDelay, delayMs);
      return;
    }
    const now = Date.now();
    const at = now + Math.max(delayMs, 1);
    const pending = await this.ctx.storage.getAlarm();
    if (!shouldArmAlarm(pending, at, now)) return;
    await this.ctx.storage.setAlarm(at);
  }

  /// What one delivery carries, built from the story as it stands now.
  private payload(d: Delivery, authorId: string): StoryDelivery | null {
    const sql = this.ctx.storage.sql;
    if (d.kind === "removed") return { kind: "removed", storyId: d.story_id, authorId };
    const row = sql.exec("SELECT * FROM stories WHERE id = ?", d.story_id)
      .toArray()[0] as unknown as (StoryRecord & { author_card: string | null; origin: string | null }) | undefined;
    if (!row) return null;
    if (d.kind === "stats") return { kind: "stats", storyId: d.story_id, authorId, ...this.counts(d.story_id) };
    // a story taken down before its delivery went out is not delivered
    if (row.taken_down) return null;
    return {
      kind: "new", storyId: d.story_id, authorId,
      story: {
        createdAt: row.created_at, expiresAt: row.expires_at,
        frames: JSON.parse(row.frames), audience: row.audience,
        link: row.link_code && !row.link_revoked ? `${row.origin ?? ""}/s/${row.link_code}` : null,
        author: JSON.parse(row.author_card ?? "null") as PublicUser,
      },
    };
  }

  private async deliver(d: Delivery): Promise<void> {
    const authorId = authorOf(d.story_id) ?? "";
    const body = this.payload(d, authorId);
    if (!body) return;
    const stub = wrapStub(this.env.USER_DO.get(this.env.USER_DO.idFromName(d.user_id)));
    await withTimeout(stub.storyEvent(body), DELIVERY_TIMEOUT_MS);
  }

  /// Sends what is due, oldest first; a failure keeps the row and moves its
  /// deadline out. Returns when to come back, or undefined when the queue is
  /// empty.
  private async pump(): Promise<number | undefined> {
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    const due = sql.exec(
      "SELECT * FROM deliveries WHERE next_at <= ? ORDER BY id LIMIT ?", now, DRAIN,
    ).toArray() as unknown as Delivery[];
    for (const d of due) {
      try {
        await this.deliver(d);
        sql.exec("DELETE FROM deliveries WHERE id = ?", d.id);
      } catch (e) {
        const pause = RETRY_MS[Math.min(d.attempt, RETRY_MS.length - 1)];
        sql.exec("UPDATE deliveries SET attempt = attempt + 1, next_at = ? WHERE id = ?",
          Date.now() + pause, d.id);
        console.warn(`stories: delivery ${d.kind} of ${d.story_id} to ${d.user_id} failed: ${e}`);
      }
    }
    const next = sql.exec("SELECT MIN(next_at) AS at FROM deliveries")
      .toArray()[0] as unknown as { at: number | null };
    return next.at ?? undefined;
  }

  async alarm() {
    this.alarmRunning = true;
    let next: number | undefined;
    try {
      next = await this.pump();
    } finally {
      this.alarmRunning = false;
    }
    const delays: number[] = [];
    if (next !== undefined) delays.push(next - Date.now());
    if (this.rearmDelay !== undefined) delays.push(this.rearmDelay);
    this.rearmDelay = undefined;
    if (delays.length) await this.arm(Math.min(...delays));
  }

  /// {authorId, frames, audience, hours, link, recipients, author, origin} → {id, code}.
  /// The story is kept and leaves for every recipient through the queue;
  /// `origin` is what a public link is minted under.
  async publish(b: {
    authorId: string; frames: unknown[]; audience: string; hours: number; link: boolean;
    recipients: string[]; author: PublicUser | null; origin: string;
  }): Promise<{ id: string; code: string | null }> {
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    const id = `${b.authorId}~${ulid(now)}`;
    const code = b.link ? await mintLinkCode(this.env, b.authorId) : null;
    sql.exec(
      `INSERT INTO stories (id, created_at, expires_at, frames, audience, link_code, author_card, origin)
       VALUES (?,?,?,?,?,?,?,?)`,
      id, now, now + b.hours * 3600_000, JSON.stringify(b.frames), b.audience, code,
      JSON.stringify(b.author), b.origin,
    );
    const users = [...new Set(b.recipients)];
    for (const u of users) {
      sql.exec("INSERT OR IGNORE INTO recipients (story_id, user_id) VALUES (?,?)", id, u);
    }
    await this.enqueue(id, users, "new");
    return { id, code };
  }

  /// The live story's access facts, for the Worker to decide with.
  async story(id: string): Promise<{ audience: string }> {
    const story = this.live(id, Date.now());
    if (!story) throw new DOError("not_found", 404);
    return { audience: story.audience };
  }

  /// The watch is remembered once; a first watch sends the author their new
  /// counts.
  async seen(storyId: string, viewer: string): Promise<void> {
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    if (!this.live(storyId, now)) throw new DOError("not_found", 404);
    const before = this.counts(storyId).views;
    sql.exec(
      `INSERT INTO views (story_id, viewer_id, seen_at) VALUES (?,?,?)
       ON CONFLICT(story_id, viewer_id) DO NOTHING`,
      storyId, viewer, now,
    );
    if (this.counts(storyId).views !== before) {
      await this.enqueue(storyId, [authorOf(storyId) ?? ""], "stats");
    }
  }

  /// The heart goes on or comes off. A heart is a watch too. The author hears
  /// the counts move.
  async like(storyId: string, user: string, on: boolean): Promise<{ liked: boolean }> {
    const sql = this.ctx.storage.sql;
    const now = Date.now();
    if (!this.live(storyId, now)) throw new DOError("not_found", 404);
    const before = this.counts(storyId);
    if (on) {
      sql.exec(
        `INSERT INTO views (story_id, viewer_id, seen_at) VALUES (?,?,?)
         ON CONFLICT(story_id, viewer_id) DO NOTHING`,
        storyId, user, now,
      );
      sql.exec(
        `INSERT INTO likes (story_id, user_id, liked_at) VALUES (?,?,?)
         ON CONFLICT(story_id, user_id) DO NOTHING`,
        storyId, user, now,
      );
    } else {
      sql.exec("DELETE FROM likes WHERE story_id = ? AND user_id = ?", storyId, user);
    }
    const after = this.counts(storyId);
    if (after.views !== before.views || after.likes !== before.likes) {
      await this.enqueue(storyId, [authorOf(storyId) ?? ""], "stats");
    }
    return { liked: on };
  }

  /// Who watched, hearts first; throws not_found for a story the author
  /// never had.
  async viewers(storyId: string): Promise<{
    viewers: Array<{ viewer_id: string; seen_at: number; liked: boolean }>;
  }> {
    const sql = this.ctx.storage.sql;
    const exists = sql.exec("SELECT 1 FROM stories WHERE id = ?", storyId).toArray()[0];
    if (!exists) throw new DOError("not_found", 404);
    const rows = sql.exec(
      `SELECT v.viewer_id, v.seen_at, l.user_id IS NOT NULL AS liked
       FROM views v
       LEFT JOIN likes l ON l.story_id = v.story_id AND l.user_id = v.viewer_id
       WHERE v.story_id = ? ORDER BY liked DESC, v.seen_at DESC`,
      storyId,
    ).toArray() as unknown as Array<{ viewer_id: string; seen_at: number; liked: number }>;
    return {
      viewers: rows.map((r) => ({ viewer_id: r.viewer_id, seen_at: r.seen_at, liked: r.liked === 1 })),
    };
  }

  /// The story taken down, or its link minted or revoked. A revoked code is
  /// never handed out again. A take-down leaves for everyone the story was
  /// delivered to.
  async update(b: {
    authorId: string; storyId: string; takeDown?: boolean; link?: boolean;
  }): Promise<{ code?: string | null }> {
    const sql = this.ctx.storage.sql;
    const story = sql.exec("SELECT * FROM stories WHERE id = ?", b.storyId)
      .toArray()[0] as unknown as StoryRecord | undefined;
    if (!story) throw new DOError("not_found", 404);
    if (b.takeDown) {
      sql.exec("UPDATE stories SET taken_down = 1 WHERE id = ?", b.storyId);
      const users = (sql.exec("SELECT user_id FROM recipients WHERE story_id = ?", b.storyId)
        .toArray() as unknown as Array<{ user_id: string }>).map((r) => r.user_id);
      await this.enqueue(b.storyId, users, "removed");
      return {};
    }
    if (b.link === true) {
      const code = story.link_code && !story.link_revoked
        ? story.link_code : await mintLinkCode(this.env, b.authorId);
      sql.exec("UPDATE stories SET link_code = ?, link_revoked = 0 WHERE id = ?", code, b.storyId);
      return { code };
    }
    if (b.link === false) {
      sql.exec("UPDATE stories SET link_revoked = 1 WHERE id = ?", b.storyId);
      return { code: null };
    }
    throw new DOError("nothing_to_do");
  }

  /// The frames behind a public link while it opens; a revoked link, a story
  /// taken down and one whose day is over all throw not_found.
  async publicFrames(code: string): Promise<{ frames: unknown[] }> {
    const row = this.ctx.storage.sql.exec(
      `SELECT frames FROM stories
       WHERE link_code = ? AND link_revoked = 0 AND taken_down = 0 AND expires_at > ?`,
      code, Date.now(),
    ).toArray()[0] as unknown as { frames: string } | undefined;
    if (!row) throw new DOError("not_found", 404);
    return { frames: JSON.parse(row.frames) };
  }

  /// An object named by a link code: makes it point at the author.
  async point(author: string): Promise<void> {
    await this.ctx.storage.put("author", author);
  }

  async pointer(): Promise<{ author: string }> {
    const author = await this.ctx.storage.get<string>("author");
    if (!author) throw new DOError("not_found", 404);
    return { author };
  }

  /// How the queue stands, for the smoke test.
  async queue(): Promise<{ pending: number }> {
    const n = this.ctx.storage.sql.exec("SELECT COUNT(*) AS n FROM deliveries")
      .toArray()[0] as unknown as { n: number };
    return { pending: n.n };
  }

  /// The account is gone: so is everything here.
  async wipe(): Promise<void> {
    const sql = this.ctx.storage.sql;
    sql.exec("DELETE FROM likes");
    sql.exec("DELETE FROM views");
    sql.exec("DELETE FROM recipients");
    sql.exec("DELETE FROM deliveries");
    sql.exec("DELETE FROM stories");
  }
}
