import type { Env } from "../types";
import { json, err, ulid, b64url } from "../util";

/// One object per author, addressed by `idFromName(userId)`: their stories,
/// who watched each, who left a heart, and the public link codes. A story is
/// not end-to-end encrypted — who may see one is an access rule the Worker
/// applies before it asks here — so the object holds the frames as the
/// composer built them and hands them out unchanged.
///
/// Every write of a watch or a heart lands in the author's own object, so the
/// hottest path stories have is spread over as many objects as there are
/// authors, and the counts are read where they are written.

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
  return env.STORIES_DO.get(env.STORIES_DO.idFromName(`author:${authorId}`));
}

function linkStub(env: Env, code: string) {
  return env.STORIES_DO.get(env.STORIES_DO.idFromName(`link:${code}`));
}

/// Mints a code and makes it point at the author.
async function mintLinkCode(env: Env, authorId: string): Promise<string> {
  const code = newLinkCode();
  await linkStub(env, code).fetch("https://do/point", {
    method: "POST", body: JSON.stringify({ author: authorId }),
  });
  return code;
}

/// Whose stories a public link's code belongs to, if it was ever minted.
export async function authorOfLink(env: Env, code: string): Promise<string | null> {
  const r = await linkStub(env, code).fetch("https://do/pointer");
  if (!r.ok) return null;
  return ((await r.json()) as { author: string }).author;
}

export class StoriesDO implements DurableObject {
  constructor(private state: DurableObjectState, private env: Env) {
    const sql = this.state.storage.sql;
    sql.exec(`
      CREATE TABLE IF NOT EXISTS stories (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        frames TEXT NOT NULL,
        audience TEXT NOT NULL,
        link_code TEXT,
        link_revoked INTEGER NOT NULL DEFAULT 0,
        taken_down INTEGER NOT NULL DEFAULT 0
      )`);
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
  }

  /// The story if it is still there to be watched: not taken down, its time
  /// not over.
  private live(id: string, now: number): StoryRecord | null {
    const row = this.state.storage.sql.exec(
      "SELECT * FROM stories WHERE id = ? AND taken_down = 0 AND expires_at > ?", id, now,
    ).toArray()[0] as unknown as StoryRecord | undefined;
    return row ?? null;
  }

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const sql = this.state.storage.sql;
    const now = Date.now();
    switch (url.pathname) {
      /// {authorId, frames, audience, hours, link} → {id, code}
      case "/publish": {
        const b = (await req.json()) as {
          authorId: string; frames: unknown[]; audience: string; hours: number; link: boolean;
        };
        const id = `${b.authorId}~${ulid(now)}`;
        const code = b.link ? await mintLinkCode(this.env, b.authorId) : null;
        sql.exec(
          `INSERT INTO stories (id, created_at, expires_at, frames, audience, link_code)
           VALUES (?,?,?,?,?,?)`,
          id, now, now + b.hours * 3600_000, JSON.stringify(b.frames), b.audience, code,
        );
        return json({ ok: true, id, code });
      }

      /// ?viewer= → the author's live stories as this viewer sees them: their
      /// own watch and heart on each, and — for the author alone — how many
      /// watched and how many liked.
      case "/live": {
        const viewer = url.searchParams.get("viewer") ?? "";
        const mine = url.searchParams.get("author") === viewer;
        const rows = sql.exec(
          `SELECT s.*,
                  EXISTS(SELECT 1 FROM views v WHERE v.story_id = s.id AND v.viewer_id = ?) AS seen,
                  EXISTS(SELECT 1 FROM likes l WHERE l.story_id = s.id AND l.user_id = ?) AS liked,
                  (SELECT COUNT(*) FROM views v WHERE v.story_id = s.id) AS views,
                  (SELECT COUNT(*) FROM likes l WHERE l.story_id = s.id) AS likes
           FROM stories s
           WHERE s.taken_down = 0 AND s.expires_at > ?
           ORDER BY s.created_at`,
          viewer, viewer, now,
        ).toArray() as unknown as Array<StoryRecord & {
          seen: number; liked: number; views: number; likes: number;
        }>;
        return json({
          ok: true,
          stories: rows.map((r) => ({
            id: r.id, createdAt: r.created_at, expiresAt: r.expires_at,
            frames: JSON.parse(r.frames), audience: r.audience,
            code: r.link_code && !r.link_revoked ? r.link_code : null,
            seen: r.seen === 1, liked: r.liked === 1,
            views: mine ? r.views : null, likes: mine ? r.likes : null,
          })),
        });
      }

      /// ?id= → the live story's access facts, for the Worker to decide with.
      case "/story": {
        const story = this.live(url.searchParams.get("id") ?? "", now);
        if (!story) return err("not_found", 404);
        return json({ ok: true, audience: story.audience });
      }

      /// {storyId, viewer} → the watch is remembered once.
      case "/seen": {
        const b = (await req.json()) as { storyId: string; viewer: string };
        if (!this.live(b.storyId, now)) return err("not_found", 404);
        sql.exec(
          `INSERT INTO views (story_id, viewer_id, seen_at) VALUES (?,?,?)
           ON CONFLICT(story_id, viewer_id) DO NOTHING`,
          b.storyId, b.viewer, now,
        );
        return json({ ok: true });
      }

      /// {storyId, user, on} → the heart goes on or comes off. A heart is a
      /// watch too.
      case "/like": {
        const b = (await req.json()) as { storyId: string; user: string; on: boolean };
        if (!this.live(b.storyId, now)) return err("not_found", 404);
        if (b.on) {
          sql.exec(
            `INSERT INTO views (story_id, viewer_id, seen_at) VALUES (?,?,?)
             ON CONFLICT(story_id, viewer_id) DO NOTHING`,
            b.storyId, b.user, now,
          );
          sql.exec(
            `INSERT INTO likes (story_id, user_id, liked_at) VALUES (?,?,?)
             ON CONFLICT(story_id, user_id) DO NOTHING`,
            b.storyId, b.user, now,
          );
        } else {
          sql.exec("DELETE FROM likes WHERE story_id = ? AND user_id = ?", b.storyId, b.user);
        }
        return json({ ok: true, liked: b.on });
      }

      /// ?storyId= → who watched, hearts first; 404 for a story the author
      /// never had.
      case "/viewers": {
        const storyId = url.searchParams.get("storyId") ?? "";
        const exists = sql.exec("SELECT 1 FROM stories WHERE id = ?", storyId).toArray()[0];
        if (!exists) return err("not_found", 404);
        const rows = sql.exec(
          `SELECT v.viewer_id, v.seen_at, l.user_id IS NOT NULL AS liked
           FROM views v
           LEFT JOIN likes l ON l.story_id = v.story_id AND l.user_id = v.viewer_id
           WHERE v.story_id = ? ORDER BY liked DESC, v.seen_at DESC`,
          storyId,
        ).toArray() as unknown as Array<{ viewer_id: string; seen_at: number; liked: number }>;
        return json({
          ok: true,
          viewers: rows.map((r) => ({ viewer_id: r.viewer_id, seen_at: r.seen_at, liked: r.liked === 1 })),
        });
      }

      /// {authorId, storyId, takeDown?, link?} → the story taken down, or its
      /// link minted or revoked. A revoked code is never handed out again.
      case "/update": {
        const b = (await req.json()) as {
          authorId: string; storyId: string; takeDown?: boolean; link?: boolean;
        };
        const story = sql.exec("SELECT * FROM stories WHERE id = ?", b.storyId)
          .toArray()[0] as unknown as StoryRecord | undefined;
        if (!story) return err("not_found", 404);
        if (b.takeDown) {
          sql.exec("UPDATE stories SET taken_down = 1 WHERE id = ?", b.storyId);
          return json({ ok: true });
        }
        if (b.link === true) {
          const code = story.link_code && !story.link_revoked
            ? story.link_code : await mintLinkCode(this.env, b.authorId);
          sql.exec("UPDATE stories SET link_code = ?, link_revoked = 0 WHERE id = ?", code, b.storyId);
          return json({ ok: true, code });
        }
        if (b.link === false) {
          sql.exec("UPDATE stories SET link_revoked = 1 WHERE id = ?", b.storyId);
          return json({ ok: true, code: null });
        }
        return err("nothing_to_do");
      }

      /// ?code= → the frames behind a public link while it opens; a revoked
      /// link, a story taken down and one whose day is over all answer 404.
      case "/public": {
        const code = url.searchParams.get("code") ?? "";
        const row = sql.exec(
          `SELECT frames FROM stories
           WHERE link_code = ? AND link_revoked = 0 AND taken_down = 0 AND expires_at > ?`,
          code, now,
        ).toArray()[0] as unknown as { frames: string } | undefined;
        if (!row) return err("not_found", 404);
        return json({ ok: true, frames: JSON.parse(row.frames) });
      }

      /// An object named by a link code: {author} → it points at the author.
      case "/point": {
        const b = (await req.json()) as { author: string };
        await this.state.storage.put("author", b.author);
        return json({ ok: true });
      }

      case "/pointer": {
        const author = await this.state.storage.get<string>("author");
        return author ? json({ ok: true, author }) : err("not_found", 404);
      }

      /// The account is gone: so is everything here.
      case "/wipe": {
        sql.exec("DELETE FROM likes");
        sql.exec("DELETE FROM views");
        sql.exec("DELETE FROM stories");
        return json({ ok: true });
      }

      default:
        return err("not_found", 404);
    }
  }
}
