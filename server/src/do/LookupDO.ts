import { DurableObject } from "cloudflare:workers";
import type { Env } from "../types";
import { DOError } from "../util";
import { wrapStub } from "../perf";

/// One object per lookup key, for the three things a client names before it
/// has an account to name: the provisioning session of a device being linked,
/// the restore session of a device coming back from a backup, and the invite
/// code of a chat. None of them can live in a user's object — the caller is
/// not authenticated yet, or does not know whose chat the code belongs to — and
/// each is a lookup by an exact value, which is what `idFromName` answers.
///
/// The object holds one record. `expiresAt` (ms since epoch, 0 for never) is
/// what a spent session is recognised by: an expired record reads as absent,
/// so a code coming round again finds nothing in the way and nothing has to
/// sweep the objects.
export class LookupDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
  }

  private async live(): Promise<Record<string, unknown> | null> {
    const rec = await this.ctx.storage.get<Record<string, unknown>>("rec");
    if (!rec) return null;
    const expiresAt = (rec.expiresAt as number) ?? 0;
    if (expiresAt && expiresAt <= Date.now()) return null;
    return rec;
  }

  /// Writes the record whatever was there.
  async put(rec: Record<string, unknown>): Promise<void> {
    await this.ctx.storage.put("rec", rec);
  }

  /// Writes the record only while the key is free — an expired record
  /// counts as free. Throws taken (409) when someone else holds it.
  async claim(rec: Record<string, unknown>): Promise<void> {
    if (await this.live()) throw new DOError("taken", 409);
    await this.ctx.storage.put("rec", rec);
  }

  /// The record as it stands, expired or not: whoever asked knows what an
  /// expiry means for their own answer, and «this session has run out» is
  /// not the same reply as «there is no such session».
  async get(): Promise<{ rec: Record<string, unknown> }> {
    const rec = await this.ctx.storage.get<Record<string, unknown>>("rec");
    if (!rec) throw new DOError("not_found", 404);
    return { rec };
  }

  /// Merges fields into a live record, but only while every field named in
  /// `unless` is still absent: that is how one approval and one claim of
  /// the same session are settled between two racing requests.
  async patch(
    set: Record<string, unknown>, unless?: string[],
  ): Promise<{ rec: Record<string, unknown> }> {
    const rec = await this.live();
    if (!rec) throw new DOError("not_found", 404);
    for (const field of unless ?? []) {
      if (rec[field] !== undefined && rec[field] !== null) throw new DOError("taken", 409);
    }
    const next = { ...rec, ...set };
    await this.ctx.storage.put("rec", next);
    return { rec: next };
  }

  async del(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}

function stub(env: Env, kind: string, key: string) {
  return wrapStub(env.LOOKUP_DO.get(env.LOOKUP_DO.idFromName(`${kind}:${key}`)));
}

export async function lookupPut(
  env: Env, kind: string, key: string, rec: object,
): Promise<void> {
  await stub(env, kind, key).put(rec as Record<string, unknown>);
}

/// True when the key was free and is now this record's.
export async function lookupClaim(
  env: Env, kind: string, key: string, rec: object,
): Promise<boolean> {
  try {
    await stub(env, kind, key).claim(rec as Record<string, unknown>);
    return true;
  } catch {
    return false;
  }
}

export async function lookupGet<T>(
  env: Env, kind: string, key: string,
): Promise<T | null> {
  try {
    const r = await stub(env, kind, key).get() as { rec: Record<string, unknown> };
    return r.rec as T;
  } catch {
    return null;
  }
}

/// Merges `set` into the record unless one of `unless` is already filled in.
/// Null means the record was gone or the guard held.
export async function lookupPatch<T>(
  env: Env, kind: string, key: string,
  set: Record<string, unknown>, unless?: string[],
): Promise<T | null> {
  try {
    const r = await stub(env, kind, key).patch(set, unless) as { rec: Record<string, unknown> };
    return r.rec as T;
  } catch {
    return null;
  }
}

export async function lookupDelete(env: Env, kind: string, key: string): Promise<void> {
  await stub(env, kind, key).del();
}
