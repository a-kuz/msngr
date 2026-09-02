import type { Env, AuthCtx } from "./types";
import { sha256hex, tokenOwner, userStub } from "./util";

/// The bearer token of the request, from the header or the `token` query the
/// WebSocket upgrade carries.
export function bearerToken(req: Request): string | null {
  const h = req.headers.get("authorization");
  if (h?.startsWith("Bearer ")) return h.slice(7);
  return new URL(req.url).searchParams.get("token");
}

/// Who is calling. The token names its own account, so the check runs inside
/// that account's object, next to the device list it is a check against; a
/// device that was revoked has no record left there and never authenticates
/// again.
export async function authenticate(env: Env, req: Request): Promise<AuthCtx | null> {
  const token = bearerToken(req);
  if (!token) return null;
  const userId = tokenOwner(token);
  if (!userId) return null;
  const hash = await sha256hex(token);
  try {
    const { deviceId } = await userStub(env, userId).auth(hash);
    return deviceId ? { userId, deviceId } : null;
  } catch {
    return null;
  }
}
