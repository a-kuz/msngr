import type { Env } from "../types";
import { json, err } from "../util";
import { mintApnsJwt } from "../push/apns";

/// Apple accepts a provider token for up to an hour; refresh with margin.
const JWT_TTL_SEC = 3000;
/// Floor between remints even when forced, so a burst of 403s cannot storm Apple.
const MIN_REMINT_SEC = 60;

interface CachedJwt {
  token: string;
  iat: number;
}

// Sole owner of the APNs JWT, addressed by the name "apns-jwt". The cache lives in
// object storage rather than a module variable: UserSessionDO can be spread over many
// isolates, and Apple rate-limits how often a token may be generated.
export class ApnsTokenDO implements DurableObject {
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== "/jwt") return err("unknown_path", 404);

    const force = url.searchParams.get("force") === "1";
    const now = Math.floor(Date.now() / 1000);
    const cached = await this.state.storage.get<CachedJwt>("jwt");
    if (cached) {
      const age = now - cached.iat;
      if (age < (force ? MIN_REMINT_SEC : JWT_TTL_SEC)) {
        return json({ ok: true, token: cached.token });
      }
    }

    const token = await mintApnsJwt(this.env, now);
    if (!token) return err("no_apns_key", 500);
    await this.state.storage.put("jwt", { token, iat: now } satisfies CachedJwt);
    return json({ ok: true, token });
  }
}
