import { Hono } from "hono";
import type { Env, AuthCtx, ChatState } from "./types";
import { authenticate } from "./auth";
import { ulid, newToken, sha256hex, json, err, directChatName, b64url } from "./util";

export { UserSessionDO } from "./do/UserSessionDO";
export { ConversationDO } from "./do/ConversationDO";
export { ApnsTokenDO } from "./do/ApnsTokenDO";

type Vars = { auth: AuthCtx };
const app = new Hono<{ Bindings: Env; Variables: Vars }>();

function userStub(env: Env, userId: string) {
  return env.USER_DO.get(env.USER_DO.idFromName(userId));
}
function convStub(env: Env, chatId: string) {
  return env.CONV_DO.get(env.CONV_DO.idFromName(chatId));
}

// --- регистрация (без auth) ---
app.post("/api/register", async (c) => {
  const b = await c.req.json<{
    username: string; displayName: string; device?: { name?: string };
    identityKey: string; identitySignKey: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekeys: Array<{ id: number; key: string }>;
    phoneHash?: string;
  }>();
  if (!/^[a-zA-Z0-9_]{3,32}$/.test(b.username)) return err("bad_username");
  if (!b.identityKey || !b.signedPrekey?.key) return err("bad_keys");

  const now = Date.now();
  const userId = ulid(now);
  const deviceId = ulid(now);
  const token = newToken();
  const tokenHash = await sha256hex(token);

  try {
    await c.env.DB.batch([
      c.env.DB.prepare(
        "INSERT INTO users (id, username, display_name, created_at) VALUES (?,?,?,?)"
      ).bind(userId, b.username, b.displayName || b.username, now),
      c.env.DB.prepare(
        "INSERT INTO devices (id, user_id, name, token_hash, created_at) VALUES (?,?,?,?,?)"
      ).bind(deviceId, userId, b.device?.name ?? null, tokenHash, now),
      c.env.DB.prepare(
        "INSERT INTO identity_keys (device_id, user_id, identity_key, identity_sign_key, signed_prekey_id, signed_prekey, signed_prekey_sig) VALUES (?,?,?,?,?,?,?)"
      ).bind(deviceId, userId, b.identityKey, b.identitySignKey, b.signedPrekey.id, b.signedPrekey.key, b.signedPrekey.sig),
      ...b.oneTimePrekeys.slice(0, 200).map((k) =>
        c.env.DB.prepare(
          "INSERT INTO one_time_prekeys (device_id, key_id, key) VALUES (?,?,?)"
        ).bind(deviceId, k.id, k.key)
      ),
    ]);
  } catch (e) {
    const msg = String(e);
    if (msg.includes("UNIQUE")) return err("username_taken", 409);
    throw e;
  }
  return json({ ok: true, userId, deviceId, token });
});

// --- всё остальное под auth ---
app.use("/api/*", async (c, next) => {
  const auth = await authenticate(c.env, c.req.raw);
  if (!auth) return err("unauthorized", 401);
  c.set("auth", auth);
  await next();
});

app.get("/api/me", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const u = await c.env.DB.prepare(
    "SELECT id, username, display_name, bio, avatar_id FROM users WHERE id = ?"
  ).bind(userId).first();
  return json({ ok: true, user: u, deviceId });
});

// --- активные устройства и отзыв токена ---

// Отзывает токен устройства: закрывает его сокеты и гасит его APNs-токен.
async function revokeDevice(env: Env, userId: string, deviceId: string) {
  await env.DB.prepare(
    "UPDATE devices SET revoked_at = ?, apns_token = NULL, apns_env = NULL WHERE id = ? AND user_id = ?"
  ).bind(Date.now(), deviceId, userId).run();
  await userStub(env, userId).fetch("https://do/revoke-device", {
    method: "POST",
    body: JSON.stringify({ deviceId }),
  });
}

app.get("/api/sessions", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const rows = await c.env.DB.prepare(
    `SELECT id, name, created_at, last_seen, apns_token IS NOT NULL AS has_push
     FROM devices WHERE user_id = ? AND revoked_at IS NULL ORDER BY created_at`
  ).bind(userId).all<{
    id: string; name: string | null; created_at: number;
    last_seen: number | null; has_push: number;
  }>();
  return json({
    ok: true,
    sessions: rows.results.map((r) => ({
      deviceId: r.id,
      name: r.name,
      createdAt: r.created_at,
      lastSeen: r.last_seen,
      hasPushToken: r.has_push === 1,
      current: r.id === deviceId,
    })),
  });
});

// Логаут текущего устройства: его токен перестаёт действовать сразу.
app.post("/api/logout", async (c) => {
  const { userId, deviceId } = c.get("auth");
  await revokeDevice(c.env, userId, deviceId);
  return json({ ok: true });
});

// Отзыв конкретного устройства того же пользователя.
app.post("/api/sessions/:deviceId/revoke", async (c) => {
  const { userId } = c.get("auth");
  const target = c.req.param("deviceId");
  const row = await c.env.DB.prepare(
    "SELECT id FROM devices WHERE id = ? AND user_id = ? AND revoked_at IS NULL"
  ).bind(target, userId).first();
  if (!row) return err("device_not_found", 404);
  await revokeDevice(c.env, userId, target);
  return json({ ok: true });
});

app.get("/api/users", async (c) => {
  // юзернейм могут ввести с @ и лишними пробелами
  const q = (c.req.query("q") ?? "").trim().replace(/^@+/, "");
  if (q.length < 2) return json({ ok: true, users: [] });
  // LOWER() для регистронезависимости и по не-ASCII именам тоже
  const like = `%${q.toLowerCase()}%`;
  const rows = await c.env.DB.prepare(
    `SELECT u.id, u.username, u.display_name, u.avatar_id
     FROM users u
     WHERE LOWER(u.username) LIKE ? OR LOWER(u.display_name) LIKE ?
     ORDER BY CASE WHEN LOWER(u.username) = ? THEN 0 ELSE 1 END, u.username
     LIMIT 20`
  ).bind(like, like, q.toLowerCase()).all();
  return json({ ok: true, users: rows.results });
});

// Профиль пользователя. Presence отдаётся только тому, кому этот пользователь
// уже виден: у них есть общий direct-чат и запрашиваемый его принял. Автор
// заявки до принятия presence получателя не видит — так же, как по WS.
app.get("/api/users/:id", async (c) => {
  const { userId } = c.get("auth");
  const targetId = c.req.param("id");
  const u = await c.env.DB.prepare(
    "SELECT id, username, display_name, bio, avatar_id FROM users WHERE id = ?"
  ).bind(targetId).first();
  if (!u) return err("not_found", 404);
  let presence: { online: boolean; lastSeen: number } | null = null;
  if (await presenceVisible(c.env, userId, targetId)) {
    const p = await userStub(c.env, targetId).fetch("https://do/presence-info");
    presence = (await p.json()) as { online: boolean; lastSeen: number };
  }
  return json({ ok: true, user: u, presence });
});

/// Виден ли presence target'а запрашивающему: общий direct-чат, в котором
/// target принял переписку. Себя видно всегда.
async function presenceVisible(env: Env, viewerId: string, targetId: string): Promise<boolean> {
  if (viewerId === targetId) return true;
  const r = await convStub(env, directChatName(viewerId, targetId)).fetch("https://do/state");
  const j = (await r.json()) as { ok: boolean; state?: ChatState };
  if (!j.ok || !j.state) return false;
  return j.state.members.some((m) => m.userId === targetId && m.accepted);
}

// Устройства и identity-ключи списка пользователей (?ids=uid1,uid2).
// Ничего не потребляет — в отличие от /prekeys, который выдаёт one-time prekey.
app.get("/api/devices", async (c) => {
  const ids = [...new Set((c.req.query("ids") ?? "").split(",").filter(Boolean))].slice(0, 100);
  if (!ids.length) return json({ ok: true, devices: [] });
  const placeholders = ids.map(() => "?").join(",");
  const rows = await c.env.DB.prepare(
    `SELECT user_id, device_id, identity_key, identity_sign_key
     FROM identity_keys WHERE user_id IN (${placeholders})`
  ).bind(...ids).all<{
    user_id: string; device_id: string; identity_key: string; identity_sign_key: string;
  }>();
  return json({
    ok: true,
    devices: rows.results.map((r) => ({
      userId: r.user_id,
      deviceId: r.device_id,
      identityKey: r.identity_key,
      identitySignKey: r.identity_sign_key,
    })),
  });
});

// Остаток собственных one-time prekeys (клиент пополняет при < 20)
app.get("/api/prekeys/count", async (c) => {
  const { deviceId } = c.get("auth");
  const row = await c.env.DB.prepare(
    "SELECT COUNT(*) AS n FROM one_time_prekeys WHERE device_id = ?"
  ).bind(deviceId).first<{ n: number }>();
  return json({ ok: true, count: row?.n ?? 0 });
});

// X3DH prekey-бандлы всех устройств пользователя (one-time prekey выдаётся и удаляется)
app.get("/api/users/:id/prekeys", async (c) => {
  const targetId = c.req.param("id");
  const devices = await c.env.DB.prepare(
    `SELECT ik.device_id, ik.identity_key, ik.identity_sign_key,
            ik.signed_prekey_id, ik.signed_prekey, ik.signed_prekey_sig
     FROM identity_keys ik WHERE ik.user_id = ?`
  ).bind(targetId).all<{
    device_id: string; identity_key: string; identity_sign_key: string;
    signed_prekey_id: number; signed_prekey: string; signed_prekey_sig: string;
  }>();

  const bundles = [];
  for (const d of devices.results) {
    const otp = await c.env.DB.prepare(
      "SELECT key_id, key FROM one_time_prekeys WHERE device_id = ? LIMIT 1"
    ).bind(d.device_id).first<{ key_id: number; key: string }>();
    if (otp) {
      await c.env.DB.prepare(
        "DELETE FROM one_time_prekeys WHERE device_id = ? AND key_id = ?"
      ).bind(d.device_id, otp.key_id).run();
    }
    bundles.push({
      deviceId: d.device_id,
      identityKey: d.identity_key,
      identitySignKey: d.identity_sign_key,
      signedPrekey: { id: d.signed_prekey_id, key: d.signed_prekey, sig: d.signed_prekey_sig },
      oneTimePrekey: otp ? { id: otp.key_id, key: otp.key } : null,
    });
  }
  return json({ ok: true, userId: targetId, bundles });
});

app.post("/api/prekeys", async (c) => {
  const { deviceId } = c.get("auth");
  const b = await c.req.json<{ oneTimePrekeys: Array<{ id: number; key: string }> }>();
  await c.env.DB.batch(
    b.oneTimePrekeys.slice(0, 200).map((k) =>
      c.env.DB.prepare(
        "INSERT OR IGNORE INTO one_time_prekeys (device_id, key_id, key) VALUES (?,?,?)"
      ).bind(deviceId, k.id, k.key)
    )
  );
  return json({ ok: true });
});

app.post("/api/profile", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ displayName?: string; bio?: string; avatarId?: string }>();
  await c.env.DB.prepare(
    `UPDATE users SET display_name = COALESCE(?, display_name),
     bio = COALESCE(?, bio), avatar_id = COALESCE(?, avatar_id) WHERE id = ?`
  ).bind(b.displayName ?? null, b.bio ?? null, b.avatarId ?? null, userId).run();
  return json({ ok: true });
});

// --- чаты ---
app.post("/api/chats", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ kind: "direct" | "group"; memberIds: string[]; title?: string }>();
  const members = [...new Set(b.memberIds)].filter((m) => m !== userId);
  if (b.kind === "direct" && members.length !== 1) return err("direct_needs_one_peer");

  // блокировки: нельзя создать direct с тем, кто тебя заблокировал
  if (b.kind === "direct") {
    const blocked = await c.env.DB.prepare(
      "SELECT 1 FROM blocks WHERE (user_id = ? AND blocked_id = ?) OR (user_id = ? AND blocked_id = ?)"
    ).bind(members[0], userId, userId, members[0]).first();
    if (blocked) return err("blocked", 403);
  }

  const chatId = b.kind === "direct" ? directChatName(userId, members[0]) : ulid();
  const res = await convStub(c.env, chatId).fetch("https://do/create", {
    method: "POST",
    body: JSON.stringify({
      chatId, kind: b.kind, title: b.title ?? null, memberIds: members, createdBy: userId,
    }),
  });
  return new Response(res.body, res);
});

app.get("/api/chats", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).fetch("https://do/chats");
  const { chats } = (await r.json()) as { chats: Record<string, unknown> };
  const states: Array<{ flags: unknown; state: ChatState }> = [];
  await Promise.all(
    Object.entries(chats).map(async ([chatId, flags]) => {
      const sr = await convStub(c.env, chatId).fetch("https://do/state");
      const sj = (await sr.json()) as { ok: boolean; state?: ChatState };
      if (sj.ok && sj.state) states.push({ flags, state: sj.state });
    })
  );
  // профили участников одним запросом
  const memberIds = [...new Set(states.flatMap((s) => s.state.members.map((m) => m.userId)))];
  let users: unknown[] = [];
  if (memberIds.length) {
    const placeholders = memberIds.map(() => "?").join(",");
    const rows = await c.env.DB.prepare(
      `SELECT id, username, display_name, bio, avatar_id FROM users WHERE id IN (${placeholders})`
    ).bind(...memberIds).all();
    users = rows.results;
  }
  return json({ ok: true, chats: states, users });
});

app.get("/api/chats/:id/history", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.param("id");
  const sr = await convStub(c.env, chatId).fetch("https://do/state");
  const sj = (await sr.json()) as { ok: boolean; state?: ChatState };
  if (!sj.ok || !sj.state?.members.some((m) => m.userId === userId))
    return err("not_member", 403);
  const qs = new URL(c.req.url).searchParams;
  qs.set("userId", userId);
  const r = await convStub(c.env, chatId).fetch(
    `https://do/history?${qs.toString()}`
  );
  return new Response(r.body, r);
});

// Fanout queue of the chat: depth and the head job's delivery cursor.
app.get("/api/chats/:id/fanout", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.param("id");
  const sr = await convStub(c.env, chatId).fetch("https://do/state");
  const sj = (await sr.json()) as { ok: boolean; state?: ChatState };
  if (!sj.ok || !sj.state?.members.some((m) => m.userId === userId))
    return err("not_member", 403);
  const r = await convStub(c.env, chatId).fetch("https://do/fanout-state");
  return new Response(r.body, r);
});

// Dev test hook: the caller's own session object rejects the next n frame
// deliveries, which exercises the fanout retry path end to end.
app.post("/api/dev/fault", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ failEvents: number }>();
  const r = await userStub(c.env, userId).fetch("https://do/dev-fault", {
    method: "POST", body: JSON.stringify({ failEvents: b.failEvents }),
  });
  return new Response(r.body, r);
});

app.post("/api/chats/:id/members", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ add?: string[]; remove?: string[] }>();
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/members", {
    method: "POST",
    body: JSON.stringify({ actor: userId, add: b.add ?? [], remove: b.remove ?? [] }),
  });
  return new Response(r.body, r);
});

app.post("/api/chats/:id/accept", async (c) => {
  const { userId } = c.get("auth");
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/accept", {
    method: "POST", body: JSON.stringify({ userId }),
  });
  return new Response(r.body, r);
});

app.post("/api/chats/:id/leave", async (c) => {
  const { userId } = c.get("auth");
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/leave", {
    method: "POST", body: JSON.stringify({ userId }),
  });
  return new Response(r.body, r);
});

app.post("/api/chats/:id/settings", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json();
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/settings", {
    method: "POST", body: JSON.stringify({ ...b, actor: userId }),
  });
  return new Response(r.body, r);
});

app.post("/api/chats/:id/admins", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json();
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/admins", {
    method: "POST", body: JSON.stringify({ ...b, actor: userId }),
  });
  return new Response(r.body, r);
});

app.post("/api/chats/:id/pin-message", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json();
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/pin-message", {
    method: "POST", body: JSON.stringify({ ...b, actor: userId }),
  });
  return new Response(r.body, r);
});

app.post("/api/chats/:id/flags", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json();
  const r = await userStub(c.env, userId).fetch("https://do/flags", {
    method: "POST", body: JSON.stringify({ ...b, chatId: c.req.param("id") }),
  });
  return new Response(r.body, r);
});

// --- invite links ---
app.post("/api/chats/:id/invite", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.param("id");
  // инвайт может создать только участник чата
  const sr = await convStub(c.env, chatId).fetch("https://do/state");
  const sj = (await sr.json()) as { ok: boolean; state?: ChatState };
  if (!sj.ok || !sj.state?.members.some((m) => m.userId === userId))
    return err("not_member", 403);
  const code = b64url(crypto.getRandomValues(new Uint8Array(9)));
  await c.env.DB.prepare(
    "INSERT INTO invites (code, chat_id, created_by, created_at) VALUES (?,?,?,?)"
  ).bind(code, chatId, userId, Date.now()).run();
  return json({ ok: true, code, link: `msngr://join/${code}` });
});

app.post("/api/join/:code", async (c) => {
  const { userId } = c.get("auth");
  const inv = await c.env.DB.prepare(
    "SELECT chat_id FROM invites WHERE code = ?"
  ).bind(c.req.param("code")).first<{ chat_id: string }>();
  if (!inv) return err("invalid_invite", 404);
  const r = await convStub(c.env, inv.chat_id).fetch("https://do/members", {
    method: "POST",
    body: JSON.stringify({ actor: userId, add: [userId], remove: [], viaInvite: true }),
  });
  const rj = (await r.json()) as { ok: boolean; error?: string };
  if (!rj.ok) return err(rj.error ?? "join_failed", r.status);
  return json({ ok: true, chatId: inv.chat_id });
});

// --- медиа (E2E: сервер хранит только ciphertext-блобы) ---
app.post("/api/media", async (c) => {
  const { userId } = c.get("auth");
  const mediaId = ulid();
  const body = c.req.raw.body;
  if (!body) return err("empty_body");
  await c.env.MEDIA.put(mediaId, body, {
    httpMetadata: { contentType: "application/octet-stream" },
  });
  const head = await c.env.MEDIA.head(mediaId);
  await c.env.DB.prepare(
    "INSERT INTO media (id, owner_id, size, created_at) VALUES (?,?,?,?)"
  ).bind(mediaId, userId, head?.size ?? 0, Date.now()).run();
  return json({ ok: true, mediaId, size: head?.size ?? 0 });
});

app.get("/api/media/:id", async (c) => {
  const obj = await c.env.MEDIA.get(c.req.param("id"), {
    range: c.req.raw.headers,
  });
  if (!obj) return err("not_found", 404);
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("accept-ranges", "bytes");
  if (obj.range && "offset" in obj.range) {
    const offset = obj.range.offset ?? 0;
    const length = obj.range.length ?? obj.size - offset;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${obj.size}`);
    return new Response(obj.body, { status: 206, headers });
  }
  return new Response(obj.body, { headers });
});

// аватары — не E2E, публичные. Без ?chatId — свой профиль, с ним — аватар чата
// (права те же, что у /chats/:id/settings: в группе только админ).
app.post("/api/avatar", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.query("chatId");
  if (chatId) {
    const sr = await convStub(c.env, chatId).fetch("https://do/state");
    const sj = (await sr.json()) as { ok: boolean; state?: ChatState };
    const me = sj.state?.members.find((m) => m.userId === userId);
    if (!sj.ok || !me) return err("not_member", 403);
    if (sj.state!.kind === "group" && me.role !== "admin") return err("not_admin", 403);
  }
  const mediaId = "avatar-" + ulid();
  const body = c.req.raw.body;
  if (!body) return err("empty_body");
  await c.env.MEDIA.put(mediaId, body, {
    httpMetadata: { contentType: c.req.header("content-type") ?? "image/jpeg" },
  });
  if (chatId) {
    const r = await convStub(c.env, chatId).fetch("https://do/settings", {
      method: "POST",
      body: JSON.stringify({ actor: userId, avatarId: mediaId }),
    });
    const rj = (await r.json()) as { ok: boolean; error?: string };
    if (!rj.ok) return err(rj.error ?? "settings_failed", r.status);
  } else {
    await c.env.DB.prepare("UPDATE users SET avatar_id = ? WHERE id = ?")
      .bind(mediaId, userId).run();
  }
  return json({ ok: true, avatarId: mediaId });
});

app.get("/api/avatar/:id", async (c) => {
  const obj = await c.env.MEDIA.get(c.req.param("id"));
  if (!obj) return err("not_found", 404);
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("cache-control", "public, max-age=86400");
  return new Response(obj.body, { headers });
});

// --- пуш-токены / блокировки ---
app.post("/api/push-token", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const b = await c.req.json<{ apnsToken: string; env: string }>();
  await c.env.DB.prepare(
    "UPDATE devices SET apns_token = ?, apns_env = ? WHERE id = ?"
  ).bind(b.apnsToken, b.env, deviceId).run();
  await userStub(c.env, userId).fetch("https://do/push-token", {
    method: "POST",
    body: JSON.stringify({ deviceId, apnsToken: b.apnsToken, env: b.env, userId }),
  });
  return json({ ok: true });
});

// contact discovery: клиент шлёт SHA-256(E.164), сервер отвечает совпадениями
app.post("/api/contacts/discover", async (c) => {
  const b = await c.req.json<{ hashes: string[] }>();
  const hashes = [...new Set(b.hashes)].slice(0, 5000);
  if (!hashes.length) return json({ ok: true, matches: [] });
  const matches: unknown[] = [];
  for (let i = 0; i < hashes.length; i += 100) {
    const chunk = hashes.slice(i, i + 100);
    const placeholders = chunk.map(() => "?").join(",");
    const rows = await c.env.DB.prepare(
      `SELECT id, username, display_name, avatar_id, phone_hash FROM users WHERE phone_hash IN (${placeholders})`
    ).bind(...chunk).all();
    matches.push(...rows.results);
  }
  return json({ ok: true, matches });
});

app.post("/api/phone", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ phoneHash: string | null }>();
  await c.env.DB.prepare("UPDATE users SET phone_hash = ? WHERE id = ?")
    .bind(b.phoneHash, userId).run();
  return json({ ok: true });
});

app.post("/api/block", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ userId: string; blocked: boolean }>();
  if (b.blocked) {
    await c.env.DB.prepare(
      "INSERT OR IGNORE INTO blocks (user_id, blocked_id, created_at) VALUES (?,?,?)"
    ).bind(userId, b.userId, Date.now()).run();
  } else {
    await c.env.DB.prepare(
      "DELETE FROM blocks WHERE user_id = ? AND blocked_id = ?"
    ).bind(userId, b.userId).run();
  }
  // сбросить кэш блокировок в direct-чате пары (чат может ещё не существовать)
  await convStub(c.env, directChatName(userId, b.userId))
    .fetch("https://do/block-changed", { method: "POST" });
  return json({ ok: true });
});

app.get("/api/blocked", async (c) => {
  const { userId } = c.get("auth");
  const rows = await c.env.DB.prepare(
    "SELECT blocked_id FROM blocks WHERE user_id = ?"
  ).bind(userId).all<{ blocked_id: string }>();
  return json({ ok: true, blocked: rows.results.map((r) => r.blocked_id) });
});

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(req.url);

    // WS: авторизуем здесь, апгрейд делает UserSessionDO
    if (url.pathname === "/ws") {
      if (req.headers.get("upgrade")?.toLowerCase() !== "websocket")
        return err("expected_websocket", 426);
      const auth = await authenticate(env, req);
      if (!auth) return err("unauthorized", 401);
      const stub = env.USER_DO.get(env.USER_DO.idFromName(auth.userId));
      const fwd = new Request("https://do/ws", req);
      fwd.headers.set("x-user-id", auth.userId);
      fwd.headers.set("x-device-id", auth.deviceId);
      ctx.waitUntil(
        env.DB.prepare("UPDATE devices SET last_seen = ? WHERE id = ?")
          .bind(Date.now(), auth.deviceId).run()
      );
      return stub.fetch(fwd);
    }

    return app.fetch(req, env, ctx);
  },
};
