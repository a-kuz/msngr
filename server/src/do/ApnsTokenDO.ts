import type { Env } from "../types";
import { json, err } from "../util";
import { mintApnsJwt } from "../push/apns";

/// Apple принимает провайдерский токен до часа; обновляем с запасом.
const JWT_TTL_SEC = 3000;
/// Нижняя граница между перевыпусками даже по force: защита от шторма 403.
const MIN_REMINT_SEC = 60;

interface CachedJwt {
  token: string;
  iat: number;
}

// Синглтон-владелец APNs JWT (адресуется именем "apns-jwt"). Кэш в storage
// объекта, а не в переменной модуля: изолятов, где живут UserSessionDO, может
// быть много, и частота генерации токена у Apple ограничена.
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
