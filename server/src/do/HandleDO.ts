import type { Env } from "../types";
import { json, err, USERNAME_QUARANTINE_MS } from "../util";

/// One object per username, addressed by `idFromName(username.toLowerCase())`:
/// the authority on who owns the handle. Uniqueness comes from the addressing
/// — a claim is a write inside the object for that exact name, serialized with
/// every other claim of the same name — and needs no index anywhere else.
///
/// Storage: `owner` (the userId holding the handle) and, after a rename freed
/// it, `released` (who let it go and when). A freed handle stays out of
/// circulation for the quarantine: otherwise whoever is watching a handle
/// inherits the searches for it the instant its owner steps away. The one who
/// released it may take it straight back.
interface Released {
  by: string;
  at: number;
}

export class HandleDO implements DurableObject {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname;
    const storage = this.state.storage;
    switch (path) {
      /// {userId} → ok, or 409 username_taken. The same owner claiming again
      /// is a no-op.
      case "/claim": {
        const b = (await req.json()) as { userId: string };
        const now = Date.now();
        const owner = await storage.get<string>("owner");
        if (owner === b.userId) return json({ ok: true });
        if (owner) return err("username_taken", 409);
        const released = await storage.get<Released>("released");
        if (released && released.by !== b.userId && now - released.at < USERNAME_QUARANTINE_MS) {
          return err("username_taken", 409);
        }
        await storage.put("owner", b.userId);
        await storage.delete("released");
        return json({ ok: true });
      }

      /// {userId, quarantine} → the handle is free again. A rename quarantines
      /// it; an account deletion frees it outright. Someone else's handle is
      /// left alone: the release is a no-op that still answers ok.
      case "/release": {
        const b = (await req.json()) as { userId: string; quarantine: boolean };
        const owner = await storage.get<string>("owner");
        if (owner !== b.userId) return json({ ok: true, released: false });
        await storage.delete("owner");
        if (b.quarantine) {
          await storage.put("released", { by: b.userId, at: Date.now() } satisfies Released);
        } else {
          await storage.delete("released");
        }
        return json({ ok: true, released: true });
      }

      /// Who holds the handle, if anyone.
      case "/resolve": {
        const owner = (await storage.get<string>("owner")) ?? null;
        return json({ ok: true, ownerId: owner });
      }

      default:
        return err("not_found", 404);
    }
  }
}

/// The stub for a handle. Handles are ASCII by the registration rule and the
/// D1 index that guarded them was NOCASE, so the object is named by the folded
/// form: `Alice` and `alice` are one handle.
export function handleStub(env: Env, username: string) {
  return env.HANDLE_DO.get(env.HANDLE_DO.idFromName(username.toLowerCase()));
}

export async function claimHandle(env: Env, username: string, userId: string): Promise<boolean> {
  const r = await handleStub(env, username).fetch("https://do/claim", {
    method: "POST", body: JSON.stringify({ userId }),
  });
  return r.ok;
}

export async function releaseHandle(
  env: Env, username: string, userId: string, quarantine: boolean,
): Promise<void> {
  await handleStub(env, username).fetch("https://do/release", {
    method: "POST", body: JSON.stringify({ userId, quarantine }),
  });
}

export async function resolveHandle(env: Env, username: string): Promise<string | null> {
  const r = await handleStub(env, username).fetch("https://do/resolve");
  const j = (await r.json()) as { ownerId: string | null };
  return j.ownerId;
}
