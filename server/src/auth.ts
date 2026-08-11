import type { Env, AuthCtx } from "./types";
import { sha256hex } from "./util";

export async function authenticate(env: Env, req: Request): Promise<AuthCtx | null> {
  let token: string | null = null;
  const h = req.headers.get("authorization");
  if (h?.startsWith("Bearer ")) token = h.slice(7);
  if (!token) token = new URL(req.url).searchParams.get("token");
  if (!token) return null;
  const hash = await sha256hex(token);
  const row = await env.DB.prepare(
    "SELECT id, user_id FROM devices WHERE token_hash = ?"
  ).bind(hash).first<{ id: string; user_id: string }>();
  if (!row) return null;
  return { userId: row.user_id, deviceId: row.id };
}
