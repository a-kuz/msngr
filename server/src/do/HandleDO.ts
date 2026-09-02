import { DurableObject } from "cloudflare:workers";
import type { Env } from "../types";
import { DOError, USERNAME_QUARANTINE_MS } from "../util";
import { wrapStub } from "../perf";

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

export class HandleDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
  }

  /// {userId} → ok, or throws username_taken (409). The same owner claiming
  /// again is a no-op.
  async claim(userId: string): Promise<void> {
    const storage = this.ctx.storage;
    const now = Date.now();
    const owner = await storage.get<string>("owner");
    if (owner === userId) return;
    if (owner) throw new DOError("username_taken", 409);
    const released = await storage.get<Released>("released");
    if (released && released.by !== userId && now - released.at < USERNAME_QUARANTINE_MS) {
      throw new DOError("username_taken", 409);
    }
    await storage.put("owner", userId);
    await storage.delete("released");
  }

  /// The handle is free again. A rename quarantines it; an account deletion
  /// frees it outright. Someone else's handle is left alone: the release is a
  /// no-op that still answers released:false.
  async release(userId: string, quarantine: boolean): Promise<{ released: boolean }> {
    const storage = this.ctx.storage;
    const owner = await storage.get<string>("owner");
    if (owner !== userId) return { released: false };
    await storage.delete("owner");
    if (quarantine) {
      await storage.put("released", { by: userId, at: Date.now() } satisfies Released);
    } else {
      await storage.delete("released");
    }
    return { released: true };
  }

  /// Who holds the handle, if anyone.
  async resolve(): Promise<{ ownerId: string | null }> {
    const owner = (await this.ctx.storage.get<string>("owner")) ?? null;
    return { ownerId: owner };
  }
}

/// The stub for a handle. Handles are ASCII by the registration rule and the
/// D1 index that guarded them was NOCASE, so the object is named by the folded
/// form: `Alice` and `alice` are one handle.
export function handleStub(env: Env, username: string) {
  return wrapStub(env.HANDLE_DO.get(env.HANDLE_DO.idFromName(username.toLowerCase())));
}

export async function claimHandle(env: Env, username: string, userId: string): Promise<boolean> {
  try {
    await handleStub(env, username).claim(userId);
    return true;
  } catch {
    return false;
  }
}

export async function releaseHandle(
  env: Env, username: string, userId: string, quarantine: boolean,
): Promise<void> {
  await handleStub(env, username).release(userId, quarantine);
}

export async function resolveHandle(env: Env, username: string): Promise<string | null> {
  return (await handleStub(env, username).resolve()).ownerId;
}
