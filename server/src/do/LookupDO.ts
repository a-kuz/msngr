import type { Env } from "../types";
import { json, err } from "../util";

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
export class LookupDO implements DurableObject {
  constructor(private state: DurableObjectState, private env: Env) {}

  private async live(): Promise<Record<string, unknown> | null> {
    const rec = await this.state.storage.get<Record<string, unknown>>("rec");
    if (!rec) return null;
    const expiresAt = (rec.expiresAt as number) ?? 0;
    if (expiresAt && expiresAt <= Date.now()) return null;
    return rec;
  }

  async fetch(req: Request): Promise<Response> {
    switch (new URL(req.url).pathname) {
      /// Writes the record whatever was there.
      case "/put": {
        await this.state.storage.put("rec", await req.json());
        return json({ ok: true });
      }

      /// Writes the record only while the key is free — an expired record
      /// counts as free. 409 says someone else holds it.
      case "/claim": {
        if (await this.live()) return err("taken", 409);
        await this.state.storage.put("rec", await req.json());
        return json({ ok: true });
      }

      /// The record as it stands, expired or not: whoever asked knows what an
      /// expiry means for their own answer, and «this session has run out» is
      /// not the same reply as «there is no such session».
      case "/get": {
        const rec = await this.state.storage.get<Record<string, unknown>>("rec");
        return rec ? json({ ok: true, rec }) : err("not_found", 404);
      }

      /// Merges fields into a live record, but only while every field named in
      /// `unless` is still absent: that is how one approval and one claim of
      /// the same session are settled between two racing requests.
      case "/patch": {
        const b = (await req.json()) as { set: Record<string, unknown>; unless?: string[] };
        const rec = await this.live();
        if (!rec) return err("not_found", 404);
        for (const field of b.unless ?? []) {
          if (rec[field] !== undefined && rec[field] !== null) return err("taken", 409);
        }
        await this.state.storage.put("rec", { ...rec, ...b.set });
        return json({ ok: true, rec: { ...rec, ...b.set } });
      }

      case "/del": {
        await this.state.storage.deleteAll();
        return json({ ok: true });
      }

      default:
        return err("not_found", 404);
    }
  }
}

function stub(env: Env, kind: string, key: string) {
  return env.LOOKUP_DO.get(env.LOOKUP_DO.idFromName(`${kind}:${key}`));
}

export async function lookupPut(
  env: Env, kind: string, key: string, rec: object,
): Promise<void> {
  await stub(env, kind, key).fetch("https://do/put", {
    method: "POST", body: JSON.stringify(rec),
  });
}

/// True when the key was free and is now this record's.
export async function lookupClaim(
  env: Env, kind: string, key: string, rec: object,
): Promise<boolean> {
  const r = await stub(env, kind, key).fetch("https://do/claim", {
    method: "POST", body: JSON.stringify(rec),
  });
  return r.ok;
}

export async function lookupGet<T>(
  env: Env, kind: string, key: string,
): Promise<T | null> {
  const r = await stub(env, kind, key).fetch("https://do/get");
  if (!r.ok) return null;
  return ((await r.json()) as { rec: T }).rec;
}

/// Merges `set` into the record unless one of `unless` is already filled in.
/// Null means the record was gone or the guard held.
export async function lookupPatch<T>(
  env: Env, kind: string, key: string,
  set: Record<string, unknown>, unless?: string[],
): Promise<T | null> {
  const r = await stub(env, kind, key).fetch("https://do/patch", {
    method: "POST", body: JSON.stringify({ set, unless }),
  });
  if (!r.ok) return null;
  return ((await r.json()) as { rec: T }).rec;
}

export async function lookupDelete(env: Env, kind: string, key: string): Promise<void> {
  await stub(env, kind, key).fetch("https://do/del", { method: "POST" });
}
