import { DurableObject } from "cloudflare:workers";
import type { Env } from "../types";
import { DOError } from "../util";
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
// object storage rather than a module variable: UserDO can be spread over many
// isolates, and Apple rate-limits how often a token may be generated.
export class ApnsTokenDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
  }

  async jwt(force: boolean): Promise<{ token: string }> {
    const now = Math.floor(Date.now() / 1000);
    const cached = await this.ctx.storage.get<CachedJwt>("jwt");
    if (cached) {
      const age = now - cached.iat;
      if (age < (force ? MIN_REMINT_SEC : JWT_TTL_SEC)) {
        return { token: cached.token };
      }
    }

    const token = await mintApnsJwt(this.env, now);
    if (!token) throw new DOError("no_apns_key", 500);
    await this.ctx.storage.put("jwt", { token, iat: now } satisfies CachedJwt);
    return { token };
  }
}
