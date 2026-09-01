import { Hono } from "hono";
import type { Env, AuthCtx, ChatState, ChatKind, PublicUser } from "./types";
import { USER_CARD_COLUMNS } from "./types";
import { authenticate } from "./auth";
import {
  ulid, newToken, sha256hex, json, err, directChatName, b64url, provisionCode,
  isValidUsername, isValidDisplayName, verifyEd25519, readPrivacy,
  hiddenAvatarOwners, privacyAllows,
} from "./util";
import type { LastSeenVisibility } from "./types";
import { PROTOCOL_VERSION, MIN_CLIENT_PROTOCOL } from "./version";
import { newCounters, wrapDB } from "./perf";
import { claimHandle, releaseHandle, resolveHandle } from "./do/HandleDO";
import { directoryPut, directoryRemove, directorySearch, type DirectoryCard } from "./do/DirectoryDO";

export { UserDO } from "./do/UserDO";
export { ConversationDO } from "./do/ConversationDO";
export { ApnsTokenDO } from "./do/ApnsTokenDO";
export { HandleDO } from "./do/HandleDO";
export { DirectoryDO } from "./do/DirectoryDO";

type Vars = { auth: AuthCtx };
const app = new Hono<{ Bindings: Env; Variables: Vars }>();

function userStub(env: Env, userId: string) {
  return env.USER_DO.get(env.USER_DO.idFromName(userId));
}
function convStub(env: Env, chatId: string) {
  return env.CONV_DO.get(env.CONV_DO.idFromName(chatId));
}

/// Copies the account's card into the people-search index. The card is read
/// from the `users` row, which is where a profile change lands first.
async function indexUser(env: Env, userId: string): Promise<void> {
  const card = await env.DB.prepare(
    "SELECT id, username, display_name, avatar_id, bot_owner, bot_commands FROM users WHERE id = ?"
  ).bind(userId).first<DirectoryCard>();
  if (card) await directoryPut(env, card);
}

// --- the public page of a story ---
//
// No account, no app, no auth: the link is the whole of the access. The page
// carries the media and the text over it and nothing else — who watched belongs
// to the creator, and the page never counts a view.

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (ch) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!);
}

function storyPage(title: string, body: string): Response {
  return new Response(
    `<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #101014; color: #f2f2f7;
         font: 16px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 480px; margin: 0 auto; padding: 16px; }
  figure { margin: 0 0 16px; position: relative; }
  img, video { width: 100%; display: block; border-radius: 14px; background: #000; }
  figcaption { position: absolute; transform: translate(-50%, -50%); max-width: 80%;
               padding: 8px 12px; border-radius: 10px; font-size: 18px; text-align: center;
               font-weight: 600; box-sizing: border-box; }
  .note { color: #8e8e93; font-size: 14px; text-align: center; padding: 24px 0; }
</style></head><body><main>${body}</main></body></html>`,
    { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } }
  );
}

app.get("/s/:code", async (c) => {
  const story = await c.env.DB.prepare(
    "SELECT * FROM stories WHERE link_code = ?"
  ).bind(c.req.param("code")).first<{
    id: string; frames: string; expires_at: number; link_revoked: number; taken_down: number;
  }>();
  // a link that was revoked, a story taken down and a story whose day is over
  // all read the same from outside: there is nothing here any more
  if (!story || story.link_revoked || story.taken_down || story.expires_at <= Date.now()) {
    return storyPage("msngr", `<p class="note">Эта ссылка больше не открывается.</p>`);
  }
  const frames = JSON.parse(story.frames) as Array<{
    mediaId: string; type: string; text?: string; textColor?: string; plateColor?: string;
    tx?: number; ty?: number;
  }>;
  // the text stands where the author dragged it: the same fraction of the
  // frame here as in the app
  const pct = (v: unknown, fallback: number) =>
    (typeof v === "number" && v >= 0 && v <= 1 ? v : fallback) * 100;
  const body = frames.map((f, i) => {
    const src = `/s/${c.req.param("code")}/m/${i}`;
    const media = f.type === "video"
      ? `<video src="${src}" controls playsinline></video>`
      : `<img src="${src}" alt="">`;
    const caption = f.text
      ? `<figcaption style="color:${escapeHtml(f.textColor ?? "#fff")};` +
        `background:${escapeHtml(f.plateColor ?? "rgba(0,0,0,.35)")};` +
        `left:${pct(f.tx, 0.5)}%;top:${pct(f.ty, 0.5)}%">${escapeHtml(f.text)}</figcaption>`
      : "";
    return `<figure>${media}${caption}</figure>`;
  }).join("");
  return storyPage("msngr", body);
});

/// One frame's bytes, addressed by its place in the story rather than by its
/// media id: the link is the access, and nothing else of the bucket is reachable
/// through it.
app.get("/s/:code/m/:index", async (c) => {
  const story = await c.env.DB.prepare(
    "SELECT frames, expires_at, link_revoked, taken_down FROM stories WHERE link_code = ?"
  ).bind(c.req.param("code")).first<{
    frames: string; expires_at: number; link_revoked: number; taken_down: number;
  }>();
  if (!story || story.link_revoked || story.taken_down || story.expires_at <= Date.now()) {
    return err("not_found", 404);
  }
  const frames = JSON.parse(story.frames) as Array<{ mediaId: string; type: string }>;
  const frame = frames[Number(c.req.param("index"))];
  if (!frame) return err("not_found", 404);
  // the range is passed on only when one was asked for: handing R2 a header set
  // with no Range in it still answers 206, and a partial answer to a whole
  // request is a lie about what was sent
  const wanted = c.req.raw.headers.get("range");
  const obj = await c.env.MEDIA.get(frame.mediaId,
                                    wanted ? { range: c.req.raw.headers } : undefined);
  if (!obj) return err("not_found", 404);
  const headers = new Headers();
  headers.set("content-type", frame.type === "video" ? "video/mp4" : "image/jpeg");
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", "private, max-age=300");
  if (wanted && obj.range && "offset" in obj.range) {
    const offset = obj.range.offset ?? 0;
    const length = obj.range.length ?? obj.size - offset;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${obj.size}`);
    return new Response(obj.body, { status: 206, headers });
  }
  return new Response(obj.body, { headers });
});

// What this server speaks: its protocol version and the floor it still serves.
// No auth: a client asks before it has an account.
app.get("/api/version", (c) =>
  json({ ok: true, protocol: PROTOCOL_VERSION, minProtocol: MIN_CLIENT_PROTOCOL })
);

// --- registration (no auth) ---
app.post("/api/register", async (c) => {
  const b = await c.req.json<{
    username: string; displayName: string; device?: { name?: string };
    identityKey: string; identitySignKey: string; identityKeySig: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekeys: Array<{ id: number; key: string }>;
    phoneHash?: string;
  }>();
  if (!isValidUsername(b.username)) return err("bad_username");
  if (!isValidDisplayName(b.displayName)) return err("bad_name");
  if (!b.identityKey || !b.identitySignKey || !b.identityKeySig || !b.signedPrekey?.key) {
    return err("bad_keys");
  }

  const now = Date.now();
  const userId = ulid(now);
  const deviceId = ulid(now);
  const token = newToken();
  const tokenHash = await sha256hex(token);

  // The handle object is the authority: the claim is the one step that can
  // lose to someone else, so it goes first and nothing is written for a
  // handle that was not won.
  if (!(await claimHandle(c.env, b.username, userId))) return err("username_taken", 409);

  const kw = await userStub(c.env, userId).fetch("https://do/keys-register", {
    method: "POST",
    body: JSON.stringify({
      userId, deviceId,
      identityKey: b.identityKey, identitySignKey: b.identitySignKey,
      identityKeySig: b.identityKeySig, signedPrekey: b.signedPrekey,
      oneTimePrekeys: b.oneTimePrekeys,
    }),
  });
  if (!kw.ok) {
    await releaseHandle(c.env, b.username, userId, false);
    return err("keys_write_failed", 500);
  }

  try {
    await c.env.DB.batch([
      c.env.DB.prepare(
        "INSERT INTO users (id, username, display_name, display_name_lc, phone_hash, created_at) VALUES (?,?,?,?,?,?)"
      ).bind(userId, b.username, b.displayName.trim(), b.displayName.trim().toLowerCase(), b.phoneHash ?? null, now),
      c.env.DB.prepare(
        "INSERT INTO devices (id, user_id, name, token_hash, created_at) VALUES (?,?,?,?,?)"
      ).bind(deviceId, userId, b.device?.name ?? null, tokenHash, now),
    ]);
  } catch (e) {
    await releaseHandle(c.env, b.username, userId, false);
    await userStub(c.env, userId).fetch("https://do/account-wipe", { method: "POST", body: "{}" });
    throw e;
  }
  await indexUser(c.env, userId);
  return json({ ok: true, userId, deviceId, token });
});

// --- linking a new device (the session's own token, not a device token) ---
//
// A device with no account cannot authenticate, so these four routes are
// registered above the device-auth middleware and carry `x-provision-token`
// instead: the secret the server handed to this one device when it opened the
// session. The code in the user's hands only names the session; the token is
// what makes the claim this device's to make.

/// Life of a provisioning session, seconds. Long enough to read a code off one
/// screen and type it on another, short enough that a guessed code has almost
/// nothing to hit.
const PROVISION_TTL = 120;

interface ProvisionRow {
  id: string; token_hash: string; ephemeral_key: string;
  device_name: string | null; platform: string | null;
  expires_at: number; approved_by: string | null; envelope: string | null;
  claimed_at: number | null;
}

/// The session named by the path, once its token matches and it is still alive.
async function provisionSession(
  env: Env, req: Request, id: string
): Promise<{ row: ProvisionRow } | { error: Response }> {
  const token = req.headers.get("x-provision-token");
  if (!token) return { error: err("unauthorized", 401) };
  const row = await env.DB.prepare(
    "SELECT * FROM provision_sessions WHERE id = ?"
  ).bind(id).first<ProvisionRow>();
  if (!row) return { error: err("provision_not_found", 404) };
  if (row.token_hash !== (await sha256hex(token))) return { error: err("unauthorized", 401) };
  if (row.expires_at <= Date.now()) return { error: err("provision_expired", 410) };
  return { row };
}

app.post("/api/provision/start", async (c) => {
  const b = await c.req.json<{
    ephemeralKey: string; device?: { name?: string; platform?: string };
  }>();
  if (!b.ephemeralKey) return err("bad_keys");
  const now = Date.now();
  // a code is only meaningful while its session lives, and the spent rows are
  // what a fresh code has to stay unique against
  await c.env.DB.prepare("DELETE FROM provision_sessions WHERE expires_at <= ?")
    .bind(now).run();
  const id = ulid(now);
  const token = newToken();
  const tokenHash = await sha256hex(token);
  // the code is unique among live sessions; a collision costs one more draw
  for (let attempt = 0; ; attempt++) {
    const code = provisionCode();
    try {
      await c.env.DB.prepare(
        `INSERT INTO provision_sessions
         (id, code, token_hash, ephemeral_key, device_name, platform, created_at, expires_at)
         VALUES (?,?,?,?,?,?,?,?)`
      ).bind(
        id, code, tokenHash, b.ephemeralKey,
        b.device?.name ?? null, b.device?.platform ?? null, now, now + PROVISION_TTL * 1000
      ).run();
      return json({
        ok: true, provisionId: id, code, provisionToken: token, expiresIn: PROVISION_TTL,
      });
    } catch (e) {
      if (attempt >= 4 || !String(e).includes("UNIQUE")) throw e;
    }
  }
});

// Polled by the device being linked until its owner approves on the other one.
app.get("/api/provision/:id", async (c) => {
  const s = await provisionSession(c.env, c.req.raw, c.req.param("id"));
  if ("error" in s) return s.error;
  if (s.row.claimed_at) return err("provision_claimed", 409);
  if (!s.row.envelope) return json({ ok: true, status: "pending" });
  return json({ ok: true, status: "approved", envelope: s.row.envelope });
});

// The device takes the account: its row, its identity keys and its prekeys go
// in together, and the session is spent.
app.post("/api/provision/:id/claim", async (c) => {
  const s = await provisionSession(c.env, c.req.raw, c.req.param("id"));
  if ("error" in s) return s.error;
  if (s.row.claimed_at) return err("provision_claimed", 409);
  if (!s.row.approved_by || !s.row.envelope) return err("provision_not_approved", 409);
  const b = await c.req.json<{
    identityKey: string; identitySignKey: string; identityKeySig: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekeys: Array<{ id: number; key: string }>;
    device?: { name?: string };
  }>();
  if (!b.identityKey || !b.identitySignKey || !b.identityKeySig || !b.signedPrekey?.key) {
    return err("bad_keys");
  }

  const userId = s.row.approved_by;
  // The identity belongs to the account, not to the device: a device that does
  // not present the account's own keys is not one this account authorised.
  const kd = await userStub(c.env, userId).fetch("https://do/keys-devices");
  const known = (await kd.json()) as {
    devices: Array<{ identityKey: string; identitySignKey: string }>;
  };
  if (!known.devices.length) return err("account_has_no_devices", 409);
  const matches = known.devices.every(
    (k) => k.identityKey === b.identityKey && k.identitySignKey === b.identitySignKey
  );
  if (!matches) return err("identity_mismatch", 409);

  const now = Date.now();
  const deviceId = ulid(now);
  const token = newToken();
  // Keys first, the device row second: a failed D1 write leaves the session
  // unclaimed and a retry repeats both, while the reverse order would mint a
  // device whose own /api/identity could never heal it.
  const kw = await userStub(c.env, userId).fetch("https://do/keys-register", {
    method: "POST",
    body: JSON.stringify({
      userId, deviceId,
      identityKey: b.identityKey, identitySignKey: b.identitySignKey,
      identityKeySig: b.identityKeySig, signedPrekey: b.signedPrekey,
      oneTimePrekeys: b.oneTimePrekeys ?? [], bump: true,
    }),
  });
  if (!kw.ok) return err("keys_write_failed", 500);
  await c.env.DB.batch([
    c.env.DB.prepare(
      "INSERT INTO devices (id, user_id, name, token_hash, created_at) VALUES (?,?,?,?,?)"
    ).bind(deviceId, userId, b.device?.name ?? s.row.device_name, await sha256hex(token), now),
    c.env.DB.prepare(
      "UPDATE provision_sessions SET claimed_at = ?, envelope = NULL WHERE id = ? AND claimed_at IS NULL"
    ).bind(now, s.row.id),
  ]);
  return json({ ok: true, userId, deviceId, token });
});

app.post("/api/provision/:id/cancel", async (c) => {
  const s = await provisionSession(c.env, c.req.raw, c.req.param("id"));
  if ("error" in s) return s.error;
  await c.env.DB.prepare("DELETE FROM provision_sessions WHERE id = ?").bind(s.row.id).run();
  return json({ ok: true });
});

// --- restoring from a backup (no auth: this device has no account yet, and no
// other device is asked to approve it — the nonce signature below stands in
// for that approval) ---

/// Life of a restore session, seconds. The nonce is signed and posted back in
/// one round trip, so this only has to outlast a slow network, not a person.
const RESTORE_TTL = 120;

interface RestoreRow {
  id: string; user_id: string; identity_key: string; identity_sign_key: string;
  nonce: string; expires_at: number; claimed_at: number | null;
}

app.post("/api/restore/start", async (c) => {
  const b = await c.req.json<{ username: string }>();
  if (!isValidUsername(b.username)) return err("bad_username");
  const ownerId = await resolveHandle(c.env, b.username);
  if (!ownerId) return err("account_not_found", 404);
  const user = { id: ownerId };
  const kd = await userStub(c.env, user.id).fetch("https://do/keys-devices");
  const known = (await kd.json()) as {
    devices: Array<{ identityKey: string; identitySignKey: string }>;
    account: { identityKey: string; identitySignKey: string } | null;
  };
  // The account identity outlives its devices: logging out everywhere is the
  // exact state a backup restore is for, so the check is against the account
  // record, not against a live device.
  const identity = known.account ?? known.devices[0];
  if (!identity) return err("account_has_no_devices", 409);
  const { identityKey, identitySignKey } = identity;
  const now = Date.now();
  await c.env.DB.prepare("DELETE FROM restore_sessions WHERE expires_at <= ?").bind(now).run();
  const id = ulid(now);
  const nonce = b64url(crypto.getRandomValues(new Uint8Array(32)));
  await c.env.DB.prepare(
    `INSERT INTO restore_sessions (id, user_id, identity_key, identity_sign_key, nonce, created_at, expires_at)
     VALUES (?,?,?,?,?,?,?)`
  ).bind(id, user.id, identityKey, identitySignKey, nonce, now, now + RESTORE_TTL * 1000).run();
  return json({ ok: true, restoreId: id, nonce, expiresIn: RESTORE_TTL });
});

// The device proves it holds the account's identity private key by signing
// the session's nonce; the server checks that signature against the identity
// key already on file, then adds this device exactly as a live approval would.
app.post("/api/restore/:id/claim", async (c) => {
  const row = await c.env.DB.prepare("SELECT * FROM restore_sessions WHERE id = ?")
    .bind(c.req.param("id")).first<RestoreRow>();
  if (!row) return err("restore_not_found", 404);
  if (row.claimed_at) return err("restore_claimed", 409);
  if (row.expires_at <= Date.now()) return err("restore_expired", 410);
  const b = await c.req.json<{
    identityKey: string; identitySignKey: string; identityKeySig: string; signature: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekeys: Array<{ id: number; key: string }>;
    device?: { name?: string };
  }>();
  if (!b.identityKey || !b.identitySignKey || !b.identityKeySig || !b.signature || !b.signedPrekey?.key) {
    return err("bad_keys");
  }
  if (b.identityKey !== row.identity_key || b.identitySignKey !== row.identity_sign_key) {
    return err("identity_mismatch", 409);
  }
  const nonceBytes = new TextEncoder().encode(row.nonce);
  if (!(await verifyEd25519(row.identity_sign_key, b.signature, nonceBytes))) {
    return err("bad_signature", 401);
  }

  const userId = row.user_id;
  const now = Date.now();
  const deviceId = ulid(now);
  const token = newToken();
  const kw = await userStub(c.env, userId).fetch("https://do/keys-register", {
    method: "POST",
    body: JSON.stringify({
      userId, deviceId,
      identityKey: b.identityKey, identitySignKey: b.identitySignKey,
      identityKeySig: b.identityKeySig,
      signedPrekey: b.signedPrekey, oneTimePrekeys: b.oneTimePrekeys ?? [], bump: true,
    }),
  });
  if (!kw.ok) return err("keys_write_failed", 500);
  await c.env.DB.batch([
    c.env.DB.prepare(
      "INSERT INTO devices (id, user_id, name, token_hash, created_at) VALUES (?,?,?,?,?)"
    ).bind(deviceId, userId, b.device?.name ?? null, await sha256hex(token), now),
    c.env.DB.prepare(
      "UPDATE restore_sessions SET claimed_at = ? WHERE id = ? AND claimed_at IS NULL"
    ).bind(now, row.id),
  ]);
  return json({ ok: true, userId, deviceId, token });
});

// --- everything below is authenticated ---
app.use("/api/*", async (c, next) => {
  const auth = await authenticate(c.env, c.req.raw);
  if (!auth) return err("unauthorized", 401);
  c.set("auth", auth);
  await next();
});

app.get("/api/me", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const u = await c.env.DB.prepare(
    `SELECT ${USER_CARD_COLUMNS} FROM users WHERE id = ?`
  ).bind(userId).first();
  return json({ ok: true, user: u, deviceId });
});

// --- active devices and token revocation ---

// Revoking a device also closes its sockets and forgets its APNs token.
//
// Its keys go with it. Senders hold the device list in a cache invalidated by
// the `devices` frame, so dropping the identity record and broadcasting the
// change is what actually stops the traffic: the peer's next send no longer
// builds a box for this device, and its prekeys stop being handed out for
// sessions nobody will ever open.
async function revokeDevice(env: Env, userId: string, deviceId: string) {
  // the token dies in D1, where auth reads it; the sockets, the keys, the
  // version bump and the fan-out all happen inside the user's object
  await env.DB.prepare(
    "UPDATE devices SET revoked_at = ?, apns_token = NULL, apns_env = NULL WHERE id = ? AND user_id = ?"
  ).bind(Date.now(), deviceId, userId).run();
  await userStub(env, userId).fetch("https://do/revoke-device", {
    method: "POST",
    body: JSON.stringify({ deviceId, userId }),
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

app.post("/api/logout", async (c) => {
  const { userId, deviceId } = c.get("auth");
  await revokeDevice(c.env, userId, deviceId);
  return json({ ok: true });
});

// Deleting the account whole. Groups are left so the members stop seeing the
// user; a direct peer keeps their copy of the history — it is theirs, and
// there is no key to read the deleted side's anyway. The handle is released
// outright, the card leaves the search index, and the user's object erases
// everything it holds: keys, sessions, flags, sounds, the address book, push
// tokens.
app.post("/api/account/delete", async (c) => {
  const { userId } = c.get("auth");
  const me = await c.env.DB.prepare("SELECT username FROM users WHERE id = ?")
    .bind(userId).first<{ username: string }>();
  if (me) await releaseHandle(c.env, me.username, userId, false);
  await directoryRemove(c.env, userId);
  const cr = await userStub(c.env, userId).fetch("https://do/chats", { method: "POST", body: "{}" });
  const cj = (await cr.json()) as { ok: boolean; chats?: Record<string, unknown> };
  for (const chatId of Object.keys(cj.chats ?? {})) {
    if (chatId.startsWith("direct:") || chatId.startsWith("self:")) continue;
    await convStub(c.env, chatId).fetch("https://do/leave", {
      method: "POST", body: JSON.stringify({ userId }),
    });
  }
  await userStub(c.env, userId).fetch("https://do/account-wipe", { method: "POST", body: "{}" });
  await c.env.DB.batch([
    c.env.DB.prepare("DELETE FROM privacy_exceptions WHERE user_id = ? OR peer_id = ?").bind(userId, userId),
    c.env.DB.prepare("DELETE FROM privacy_settings WHERE user_id = ?").bind(userId),
    c.env.DB.prepare("DELETE FROM blocks WHERE user_id = ? OR blocked_id = ?").bind(userId, userId),
    c.env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(userId),
    c.env.DB.prepare("DELETE FROM users WHERE id = ?").bind(userId),
  ]);
  return json({ ok: true });
});

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

// The code a device being linked shows, resolved to what has to be approved.
// Nothing here commits the account: it answers who is asking, so the owner can
// look at the name before letting it in.
app.post("/api/provision/lookup", async (c) => {
  const b = await c.req.json<{ code: string }>();
  const code = (b.code ?? "").trim().toUpperCase().replace(/[^0-9A-Z]/g, "");
  if (!code) return err("provision_not_found", 404);
  const row = await c.env.DB.prepare(
    "SELECT id, ephemeral_key, device_name, platform, expires_at, approved_by, claimed_at FROM provision_sessions WHERE code = ?"
  ).bind(code).first<{
    id: string; ephemeral_key: string; device_name: string | null;
    platform: string | null; expires_at: number;
    approved_by: string | null; claimed_at: number | null;
  }>();
  if (!row) return err("provision_not_found", 404);
  if (row.expires_at <= Date.now()) return err("provision_expired", 410);
  if (row.claimed_at || row.approved_by) return err("provision_claimed", 409);
  return json({
    ok: true, provisionId: row.id, ephemeralKey: row.ephemeral_key,
    device: { name: row.device_name, platform: row.platform },
    expiresIn: Math.max(0, Math.round((row.expires_at - Date.now()) / 1000)),
  });
});

// The owner said yes: the sealed account bundle is parked for the one device
// that holds the session's ephemeral private key.
app.post("/api/provision/:id/approve", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ envelope: string }>();
  if (!b.envelope) return err("bad_envelope");
  const row = await c.env.DB.prepare(
    "SELECT id, expires_at, approved_by, claimed_at FROM provision_sessions WHERE id = ?"
  ).bind(c.req.param("id")).first<{
    id: string; expires_at: number; approved_by: string | null; claimed_at: number | null;
  }>();
  if (!row) return err("provision_not_found", 404);
  if (row.expires_at <= Date.now()) return err("provision_expired", 410);
  if (row.claimed_at || row.approved_by) return err("provision_claimed", 409);
  const res = await c.env.DB.prepare(
    `UPDATE provision_sessions SET approved_by = ?, approved_at = ?, envelope = ?
     WHERE id = ? AND approved_by IS NULL AND claimed_at IS NULL`
  ).bind(userId, Date.now(), b.envelope, row.id).run();
  if (!res.meta.changes) return err("provision_claimed", 409);
  return json({ ok: true });
});

app.get("/api/users", async (c) => {
  // a username gets typed with a leading @ and stray spaces often enough
  const q = (c.req.query("q") ?? "").trim().replace(/^@+/, "");
  if (q.length < 2) return json({ ok: true, users: [] });
  // folded in JS, like the index itself: SQLite's LOWER folds ASCII only, and
  // display names are free Unicode
  const users = await directorySearch(c.env, q.toLowerCase());
  const { userId } = c.get("auth");
  const hidden = await hiddenAvatarOwners(c.env, userId, users.map((r) => r.id));
  for (const r of users) {
    if (hidden.has(r.id)) r.avatar_id = null;
  }
  return json({ ok: true, users });
});

// A user profile. Presence comes with it only for someone this user is already visible
// to: they share a direct chat and the target has accepted it. Until then the person who
// sent the request sees no presence, same as over WS.
app.get("/api/users/:id", async (c) => {
  const { userId } = c.get("auth");
  const targetId = c.req.param("id");
  const u = await c.env.DB.prepare(
    `SELECT ${USER_CARD_COLUMNS} FROM users WHERE id = ?`
  ).bind(targetId).first<PublicUser>();
  if (!u) return err("not_found", 404);
  if (userId !== targetId) {
    const tier = (await readPrivacy(c.env.DB, targetId)).avatar;
    if (!(await privacyAllows(c.env, targetId, userId, "avatar", tier))) {
      u.bio = null;
      u.avatar_id = null;
    }
  }
  let presence: { online: boolean; lastSeen: number } | null = null;
  if (await presenceVisible(c.env, userId, targetId)) {
    const p = await userStub(c.env, targetId).fetch("https://do/presence-info");
    presence = (await p.json()) as { online: boolean; lastSeen: number };
  }
  // whether the target's call tier lets this viewer ring them: the dial
  // button is not worth showing on a call that would only come back busy
  let canCall = true;
  if (userId !== targetId) {
    const callTier = (await readPrivacy(c.env.DB, targetId)).callPrivacy;
    canCall = await privacyAllows(c.env, targetId, userId, "call", callTier);
  }
  return json({ ok: true, user: u, presence, canCall });
});

// The caller's own call gate, asked by the callee's device when an offer
// arrives: whether this account's call tier lets `peerId` ring it. The
// signaling is E2EE, so this judgement cannot live on the send path.
app.get("/api/privacy/may-call/:peerId", async (c) => {
  const { userId } = c.get("auth");
  const peerId = c.req.param("peerId");
  const tier = (await readPrivacy(c.env.DB, userId)).callPrivacy;
  return json({ ok: true, allow: await privacyAllows(c.env, userId, peerId, "call", tier) });
});

/// Whether the viewer may see the target's presence: they share a direct chat the
/// target has accepted, the target has not hidden their last seen, and the viewer
/// has not hidden their own — hiding last seen takes the peer's away too, same as
/// hiding it removes what the viewer sees of everyone else's.
async function presenceVisible(env: Env, viewerId: string, targetId: string): Promise<boolean> {
  if (viewerId === targetId) return true;
  const r = await convStub(env, directChatName(viewerId, targetId)).fetch("https://do/state");
  const j = (await r.json()) as { ok: boolean; state?: ChatState };
  if (!j.ok || !j.state) return false;
  if (!j.state.members.some((m) => m.userId === targetId && m.accepted)) return false;
  const targetPrivacy = await readPrivacy(env.DB, targetId);
  if (!(await privacyAllows(env, targetId, viewerId, "last_seen", targetPrivacy.lastSeen))) {
    return false;
  }
  const viewerPrivacy = await readPrivacy(env.DB, viewerId);
  if (viewerPrivacy.lastSeen === "nobody") return false;
  return true;
}

// Devices and identity keys for a list of users (?ids=uid1,uid2). Consumes nothing,
// unlike /prekeys, which hands out a one-time prekey.
app.get("/api/devices", async (c) => {
  const ids = [...new Set((c.req.query("ids") ?? "").split(",").filter(Boolean))].slice(0, 100);
  if (!ids.length) return json({ ok: true, devices: [], versions: {} });
  // each user's list and the version stamped on it come from that user's
  // object in one answer, so per user they are one snapshot
  const perUser = await Promise.all(ids.map(async (id) => {
    const r = await userStub(c.env, id).fetch("https://do/keys-devices");
    const j = (await r.json()) as {
      devices?: Array<{
        deviceId: string; identityKey: string; identitySignKey: string; identityKeySig: string;
      }>;
      version?: number | null;
    };
    return { id, devices: j.devices ?? [], version: j.version ?? null };
  }));
  const versions: Record<string, number> = {};
  const devices: unknown[] = [];
  for (const u of perUser) {
    // a user whose object was never written to is unknown, not at version zero
    if (u.version !== null) versions[u.id] = u.version;
    for (const d of u.devices) devices.push({ userId: u.id, ...d });
  }
  return json({ ok: true, devices, versions });
});

// How many one-time prekeys this device has left; the client tops up below 20
app.get("/api/prekeys/count", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const r = await userStub(c.env, userId).fetch(`https://do/keys-count?deviceId=${deviceId}`);
  const j = (await r.json()) as { count?: number };
  return json({ ok: true, count: j.count ?? 0 });
});

// X3DH prekey bundles for every device of a user; a one-time prekey is handed
// out and deleted, and the object serializes the handout: two senders asking at
// once never draw the same key
app.get("/api/users/:id/prekeys", async (c) => {
  const targetId = c.req.param("id");
  const r = await userStub(c.env, targetId).fetch("https://do/keys-prekeys", { method: "POST" });
  const j = (await r.json()) as { bundles?: unknown[] };
  return json({ ok: true, userId: targetId, bundles: j.bundles ?? [] });
});

// The device publishes the identity it encrypts under: the X25519 key, the
// Ed25519 key and the signature binding them. A device that registered before
// the signature was part of registration has nothing a peer accepts, and this is
// how it heals itself instead of the person being told to register again.
app.post("/api/identity", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const b = await c.req.json<{
    identityKey?: string; identitySignKey?: string; identityKeySig?: string;
  }>();
  if (!b.identityKey || !b.identitySignKey || !b.identityKeySig) return err("bad_keys");
  const r = await userStub(c.env, userId).fetch("https://do/keys-update", {
    method: "POST",
    body: JSON.stringify({
      deviceId, identityKey: b.identityKey,
      identitySignKey: b.identitySignKey, identityKeySig: b.identityKeySig,
    }),
  });
  return new Response(r.body, r);
});

// The device republishes its whole prekey bundle: a fresh signed prekey and a
// fresh one-time set replace what the server held. This is the self-heal for a
// stale bundle — the device kept failing to open prekey envelopes addressed to
// it, which means the published halves no longer match its own store.
app.post("/api/prekeys/republish", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const b = await c.req.json<{
    signedPrekey?: { id: number; key: string; sig: string };
    oneTimePrekeys?: Array<{ id: number; key: string }>;
  }>();
  if (!b.signedPrekey) return err("bad_keys");
  const r = await userStub(c.env, userId).fetch("https://do/keys-republish", {
    method: "POST",
    body: JSON.stringify({
      deviceId, signedPrekey: b.signedPrekey, oneTimePrekeys: b.oneTimePrekeys ?? [],
    }),
  });
  return new Response(r.body, r);
});

app.post("/api/prekeys", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const b = await c.req.json<{ oneTimePrekeys: Array<{ id: number; key: string }> }>();
  await userStub(c.env, userId).fetch("https://do/keys-topup", {
    method: "POST",
    body: JSON.stringify({ deviceId, oneTimePrekeys: b.oneTimePrekeys }),
  });
  return json({ ok: true });
});

app.post("/api/profile", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ displayName?: string; bio?: string; avatarId?: string }>();
  if (b.displayName !== undefined && !isValidDisplayName(b.displayName)) return err("bad_name");
  await c.env.DB.prepare(
    `UPDATE users SET display_name = COALESCE(?, display_name),
     display_name_lc = COALESCE(?, display_name_lc),
     bio = COALESCE(?, bio), avatar_id = COALESCE(?, avatar_id) WHERE id = ?`
  ).bind(b.displayName?.trim() ?? null, b.displayName?.trim().toLowerCase() ?? null,
         b.bio ?? null, b.avatarId ?? null, userId).run();
  await indexUser(c.env, userId);
  await broadcastProfile(c.env, userId);
  return json({ ok: true });
});

// A rename. The handle is the one thing about a person that other people type,
// so it is checked by the same rule as at registration and taken from the same
// authority: the new handle's object grants the claim, the row is moved, and
// the old handle's object releases it into quarantine.
app.post("/api/username", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ username?: string }>();
  if (!isValidUsername(b.username)) return err("bad_username");

  const current = await c.env.DB.prepare("SELECT username FROM users WHERE id = ?")
    .bind(userId).first<{ username: string }>();
  if (!current) return err("not_found", 404);
  if (current.username.toLowerCase() === b.username.toLowerCase()) {
    // the same handle in another case: nothing to claim or free
    await c.env.DB.prepare("UPDATE users SET username = ? WHERE id = ?").bind(b.username, userId).run();
  } else {
    if (!(await claimHandle(c.env, b.username, userId))) return err("username_taken", 409);
    await c.env.DB.prepare("UPDATE users SET username = ? WHERE id = ?").bind(b.username, userId).run();
    await releaseHandle(c.env, current.username, userId, true);
  }
  await indexUser(c.env, userId);
  await broadcastProfile(c.env, userId);
  return json({ ok: true, username: b.username });
});

/// Tells everyone this user shares a chat with, and their own other devices,
/// that the card changed. The card is public — GET /api/users/:id serves it to
/// anyone — so the frame carries the whole row instead of asking for a refetch.
async function broadcastProfile(env: Env, userId: string) {
  const user = await env.DB.prepare(
    `SELECT ${USER_CARD_COLUMNS} FROM users WHERE id = ?`
  ).bind(userId).first<PublicUser>();
  if (!user) return;
  // peers get the card as they may see it: a hidden photo and bio travel only
  // to the user's own devices. The frame is one card for every peer, so the
  // "contacts" tier blanks it here too — a contact still gets the full card
  // from every pull path, and the bytes route answers them
  let peerUser = user;
  if ((await readPrivacy(env.DB, userId)).avatar !== "everyone") {
    peerUser = { ...user, bio: null, avatar_id: null };
  }
  await userStub(env, userId).fetch("https://do/profile-changed", {
    method: "POST",
    body: JSON.stringify({ user, peerUser }),
  });
}

/// Splits the users `actor` wants to put into a group by their group_invites
/// tier: the protected are not added — an invite link is all that reaches them.
async function addableToGroup(
  env: Env, actor: string, ids: string[]
): Promise<{ addable: string[]; invited: string[] }> {
  const addable: string[] = [];
  const invited: string[] = [];
  for (const id of ids) {
    if (id === actor) { addable.push(id); continue; }
    const tier = (await readPrivacy(env.DB, id)).groupInvites;
    if (await privacyAllows(env, id, actor, "group_invites", tier)) {
      addable.push(id);
    } else {
      invited.push(id);
    }
  }
  return { addable, invited };
}

// --- chats ---
app.post("/api/chats", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ kind: ChatKind; memberIds: string[]; title?: string }>();
  let members = [...new Set(b.memberIds)].filter((m) => m !== userId);
  if (b.kind === "direct" && members.length !== 1) return err("direct_needs_one_peer");
  if (b.kind === "self" && members.length !== 0) return err("self_has_no_peers");
  // a channel is a name before it is an audience: it opens with the owner alone
  if (b.kind === "channel" && !b.title?.trim()) return err("channel_needs_title");

  // a block in either direction forbids opening the direct chat
  if (b.kind === "direct") {
    const blocked = await c.env.DB.prepare(
      "SELECT 1 FROM blocks WHERE (user_id = ? AND blocked_id = ?) OR (user_id = ? AND blocked_id = ?)"
    ).bind(members[0], userId, userId, members[0]).first();
    if (blocked) return err("blocked", 403);
  }

  // one saved-messages chat per user, so creating it again opens the same one
  // whoever guards being added to groups is left out here; the creator's
  // client offers them the invite link instead
  let invited: string[] = [];
  if (b.kind === "group") {
    ({ addable: members, invited } = await addableToGroup(c.env, userId, members));
  }
  const chatId = b.kind === "direct" ? directChatName(userId, members[0])
    : b.kind === "self" ? "self:" + userId
    : ulid();
  const res = await convStub(c.env, chatId).fetch("https://do/create", {
    method: "POST",
    body: JSON.stringify({
      chatId, kind: b.kind, title: b.title ?? null, memberIds: members, createdBy: userId,
    }),
  });
  if (!res.ok || !invited.length) return new Response(res.body, res);
  const body = (await res.json()) as Record<string, unknown>;
  return json({ ...body, invited });
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
  const memberIds = [...new Set(states.flatMap((s) => s.state.members.map((m) => m.userId)))];
  let users: unknown[] = [];
  if (memberIds.length) {
    const placeholders = memberIds.map(() => "?").join(",");
    const rows = await c.env.DB.prepare(
      `SELECT ${USER_CARD_COLUMNS} FROM users WHERE id IN (${placeholders})`
    ).bind(...memberIds).all<PublicUser>();
    const hidden = await hiddenAvatarOwners(c.env, userId, memberIds);
    for (const u of rows.results) {
      if (hidden.has(u.id)) {
        u.bio = null;
        u.avatar_id = null;
      }
    }
    users = rows.results;
  }
  return json({ ok: true, chats: states, users });
});

app.get("/api/chats/:id/history", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.param("id");
  // membership is checked by the object itself on the read that serves the page:
  // asking for it first costs a second invocation on every page of history
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

// Dev hook for a stand whose accounts predate the handle and directory
// objects: every `users` row claims its handle and lands in the search index.
// Idempotent; a handle already held by someone else is reported, not taken.
app.post("/api/dev/reindex", async (c) => {
  const rows = await c.env.DB.prepare(
    "SELECT id, username, display_name, avatar_id, bot_owner, bot_commands FROM users"
  ).all<DirectoryCard>();
  const clashes: string[] = [];
  for (const card of rows.results) {
    if (!(await claimHandle(c.env, card.username, card.id))) clashes.push(card.username);
    await directoryPut(c.env, card);
  }
  return json({ ok: true, indexed: rows.results.length, clashes });
});

app.post("/api/chats/:id/members", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ add?: string[]; remove?: string[] }>();
  // whoever guards being added is left out; the adder's client offers the
  // invite link instead. Joining yourself by that link is not an add.
  const { addable, invited } = await addableToGroup(c.env, userId,
    [...new Set(b.add ?? [])].filter((u) => u !== userId));
  const selfJoin = (b.add ?? []).includes(userId) ? [userId] : [];
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/members", {
    method: "POST",
    body: JSON.stringify({ actor: userId, add: [...selfJoin, ...addable], remove: b.remove ?? [] }),
  });
  if (!r.ok || !invited.length) return new Response(r.body, r);
  const body = (await r.json()) as Record<string, unknown>;
  return json({ ...body, invited });
});

// The delivery receipt with no socket to send it on. The notification extension
// writes the message its push carried while the app is not running, and that is
// the moment the message reaches the device; the frame `{t:"recv"}` does the
// same thing over an open connection, and the object applies the same rules to
// both.
app.post("/api/chats/:id/recv", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ seqs?: number[] }>();
  const seqs = (b.seqs ?? []).filter((s) => Number.isFinite(s) && s > 0);
  if (!seqs.length) return err("bad_seqs");
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/recv", {
    method: "POST", body: JSON.stringify({ userId, seqs }),
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

// Deleting a chat is the caller's own act. A group is left, because the others
// have to stop seeing the member. A direct chat keeps its journal and its
// membership: the peer keeps his copy and is told nothing, and the chat only
// leaves this user's list. His read mark moves to the end first — messages he
// has just thrown away must not sit in his badge — and the chat comes back on
// the next message the peer sends.
app.post("/api/chats/:id/delete", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.param("id");
  const sr = await convStub(c.env, chatId).fetch("https://do/state");
  const sj = (await sr.json()) as { ok: boolean; state?: ChatState };
  if (!sj.ok || !sj.state?.members.some((m) => m.userId === userId))
    return err("not_member", 403);
  if (sj.state.kind === "group") {
    const r = await convStub(c.env, chatId).fetch("https://do/leave", {
      method: "POST", body: JSON.stringify({ userId }),
    });
    return new Response(r.body, r);
  }
  await convStub(c.env, chatId).fetch("https://do/read", {
    method: "POST", body: JSON.stringify({ userId, upToSeq: sj.state.lastSeq }),
  });
  const r = await userStub(c.env, userId).fetch("https://do/chat-removed", {
    method: "POST", body: JSON.stringify({ chatId }),
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

// --- bots ---
//
// A bot is an account with a token and no keys. It cannot encrypt, so every
// chat it is in travels in the clear, and the interface says so before the
// first word is typed. Its token is the whole of its authentication: it walks
// in through the same door as a device.

interface BotCommand { command: string; description: string }

/// A command is what the input offers after «/»: a bare word, so the list can
/// be matched against what is typed.
function cleanCommands(value: unknown): BotCommand[] | null {
  if (!Array.isArray(value)) return null;
  const out: BotCommand[] = [];
  for (const item of value.slice(0, 32)) {
    const cmd = (item as BotCommand)?.command;
    if (typeof cmd !== "string" || !/^[a-z0-9_]{1,32}$/.test(cmd)) return null;
    const desc = (item as BotCommand)?.description;
    out.push({ command: cmd, description: typeof desc === "string" ? desc.slice(0, 128) : "" });
  }
  return out;
}

app.post("/api/bots", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ username: string; displayName: string; commands?: unknown }>();
  if (!isValidUsername(b.username)) return err("bad_username");
  if (!isValidDisplayName(b.displayName)) return err("bad_name");
  const commands = b.commands === undefined ? [] : cleanCommands(b.commands);
  if (commands === null) return err("bad_commands");
  const now = Date.now();
  const botId = ulid(now);
  const deviceId = ulid(now);
  const token = newToken();
  if (!(await claimHandle(c.env, b.username, botId))) return err("username_taken", 409);
  try {
    await c.env.DB.batch([
      c.env.DB.prepare(
        `INSERT INTO users (id, username, display_name, display_name_lc, created_at,
                            bot_owner, bot_commands) VALUES (?,?,?,?,?,?,?)`
      ).bind(botId, b.username, b.displayName.trim(), b.displayName.trim().toLowerCase(),
             now, userId, JSON.stringify(commands)),
      c.env.DB.prepare(
        "INSERT INTO devices (id, user_id, name, token_hash, created_at) VALUES (?,?,?,?,?)"
      ).bind(deviceId, botId, "bot", await sha256hex(token), now),
    ]);
  } catch (e) {
    await releaseHandle(c.env, b.username, botId, false);
    throw e;
  }
  await indexUser(c.env, botId);
  return json({ ok: true, botId, token });
});

app.get("/api/bots", async (c) => {
  const { userId } = c.get("auth");
  const rows = await c.env.DB.prepare(
    "SELECT id, username, display_name, bot_commands FROM users WHERE bot_owner = ? ORDER BY created_at"
  ).bind(userId).all();
  return json({ ok: true, bots: rows.results });
});

/// The owner edits the bot's name and its command list, and asks for a fresh
/// token when the old one has been seen by the wrong eyes.
app.post("/api/bots/:id", async (c) => {
  const { userId } = c.get("auth");
  const botId = c.req.param("id");
  const b = await c.req.json<{ displayName?: string; commands?: unknown; newToken?: boolean }>();
  const bot = await c.env.DB.prepare(
    "SELECT id, bot_owner FROM users WHERE id = ?"
  ).bind(botId).first<{ bot_owner: string | null }>();
  if (!bot || bot.bot_owner !== userId) return err("not_owner", 403);
  if (b.displayName !== undefined) {
    if (!isValidDisplayName(b.displayName)) return err("bad_name");
    await c.env.DB.prepare(
      "UPDATE users SET display_name = ?, display_name_lc = ? WHERE id = ?"
    ).bind(b.displayName.trim(), b.displayName.trim().toLowerCase(), botId).run();
  }
  if (b.commands !== undefined) {
    const commands = cleanCommands(b.commands);
    if (commands === null) return err("bad_commands");
    await c.env.DB.prepare("UPDATE users SET bot_commands = ? WHERE id = ?")
      .bind(JSON.stringify(commands), botId).run();
  }
  if (b.displayName !== undefined || b.commands !== undefined) await indexUser(c.env, botId);
  let token: string | undefined;
  if (b.newToken) {
    token = newToken();
    await c.env.DB.prepare("UPDATE devices SET token_hash = ? WHERE user_id = ?")
      .bind(await sha256hex(token), botId).run();
  }
  return json({ ok: true, token });
});

app.post("/api/chats/:id/roles", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json();
  const r = await convStub(c.env, c.req.param("id")).fetch("https://do/roles", {
    method: "POST", body: JSON.stringify({ ...b, actor: userId }),
  });
  return new Response(r.body, r);
});

// A channel's posts are journaled in the clear, so its history is searched
// where it lies. Every other kind is E2EE and is searched on the device.
app.get("/api/chats/:id/search", async (c) => {
  const { userId } = c.get("auth");
  const qs = new URL(c.req.url).searchParams;
  qs.set("userId", userId);
  const r = await convStub(c.env, c.req.param("id")).fetch(`https://do/search?${qs.toString()}`);
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

// The user's default push sounds by chat shape; a chat's own sound (a flag)
// overrides them, and both resolve on the object that sends the push.
app.get("/api/notify-sounds", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).fetch("https://do/notify-sounds?read=1", {
    method: "POST", body: "{}",
  });
  return new Response(r.body, r);
});
// A person's own sound, applied to their messages wherever they write; a
// chat's explicit sound still wins inside that chat.
app.get("/api/notify-sounds/person/:id", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).fetch("https://do/person-sound", {
    method: "POST", body: JSON.stringify({ userId: c.req.param("id"), read: true }),
  });
  return new Response(r.body, r);
});
app.post("/api/notify-sounds/person/:id", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ sound?: string | null }>();
  const r = await userStub(c.env, userId).fetch("https://do/person-sound", {
    method: "POST", body: JSON.stringify({ userId: c.req.param("id"), sound: b.sound ?? null }),
  });
  return new Response(r.body, r);
});

app.post("/api/notify-sounds", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).fetch("https://do/notify-sounds", {
    method: "POST", body: JSON.stringify(await c.req.json()),
  });
  return new Response(r.body, r);
});

// Every chat and person with a sound of their own, for the settings list.
app.get("/api/notify-sounds/exceptions", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).fetch("https://do/sound-exceptions", {
    method: "POST", body: "{}",
  });
  return new Response(r.body, r);
});

app.get("/api/chats/:id/flags", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).fetch("https://do/flags-read", {
    method: "POST", body: JSON.stringify({ chatId: c.req.param("id") }),
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
  // only a member of the chat may mint an invite, and only while the group's
  // rights let them bring anyone in
  const sr = await convStub(c.env, chatId).fetch("https://do/state");
  const sj = (await sr.json()) as { ok: boolean; state?: ChatState };
  const me = sj.state?.members.find((m) => m.userId === userId);
  if (!sj.ok || !me) return err("not_member", 403);
  if (sj.state!.kind === "group" && sj.state!.invitePolicy === "admins" && me.role !== "admin")
    return err("not_allowed", 403);
  // a channel's link is what its audience arrives by, and it is the editors' to hand out
  if (sj.state!.kind === "channel" && me.role !== "owner" && me.role !== "editor")
    return err("not_allowed", 403);
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

// --- media (E2E: the server keeps ciphertext blobs and nothing else) ---
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
  // only a request that asked for a range gets a partial answer
  const wanted = c.req.raw.headers.get("range");
  const obj = await c.env.MEDIA.get(c.req.param("id"),
                                    wanted ? { range: c.req.raw.headers } : undefined);
  if (!obj) return err("not_found", 404);
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("accept-ranges", "bytes");
  if (wanted && obj.range && "offset" in obj.range) {
    const offset = obj.range.offset ?? 0;
    const length = obj.range.length ?? obj.size - offset;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${obj.size}`);
    return new Response(obj.body, { status: 206, headers });
  }
  return new Response(obj.body, { headers });
});

// Avatars are public, not E2E. Without ?chatId this is the caller's own profile, with it
// the chat avatar, under the same rights as /chats/:id/settings: in a group, admins only.
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
    await indexUser(c.env, userId);
    await broadcastProfile(c.env, userId);
  }
  return json({ ok: true, avatarId: mediaId });
});

app.get("/api/avatar/:id", async (c) => {
  // A user avatar whose owner hid it is withheld at the bytes too, not only by
  // blanking avatar_id in the cards: an id learned earlier must stop answering.
  // Chat avatars match no users row and stay open to any authenticated caller.
  const mediaId = c.req.param("id");
  const owner = await c.env.DB.prepare("SELECT id FROM users WHERE avatar_id = ?")
    .bind(mediaId).first<{ id: string }>();
  if (owner && owner.id !== c.get("auth").userId) {
    const tier = (await readPrivacy(c.env.DB, owner.id)).avatar;
    if (!(await privacyAllows(c.env, owner.id, c.get("auth").userId, "avatar", tier))) {
      return err("not_found", 404);
    }
  }
  const obj = await c.env.MEDIA.get(mediaId);
  if (!obj) return err("not_found", 404);
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set("cache-control", "public, max-age=86400");
  return new Response(obj.body, { headers });
});

// --- push tokens / blocks ---
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

/// Drops the matches their owners hide: `phone_discovery` "nobody" always,
/// "contacts" unless the found user lists the searcher in their own book —
/// you are findable by the people whose number you hold.
async function discoverableBy(
  env: Env, searcherId: string, ids: string[]
): Promise<Set<string>> {
  const allowed = new Set(ids);
  for (const id of ids) {
    if (id === searcherId) continue;
    const tier = (await readPrivacy(env.DB, id)).phoneDiscovery;
    if (!(await privacyAllows(env, id, searcherId, "phone_discovery", tier))) {
      allowed.delete(id);
    }
  }
  return allowed;
}

// contact discovery: the client sends SHA-256(E.164); the book lands in the
// caller's object as their contact set, and the answer is the registered
// matches their owners let this searcher see
app.post("/api/contacts/discover", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ hashes: string[]; remove?: string[] }>();
  const hashes = [...new Set(b.hashes)].slice(0, 5000);
  if (!hashes.length && !b.remove?.length) return json({ ok: true, matches: [] });
  await userStub(c.env, userId).fetch("https://do/contacts-sync", {
    method: "POST", body: JSON.stringify({ hashes, remove: b.remove }),
  });
  const matches: Array<{ id: string; avatar_id: string | null }> = [];
  for (let i = 0; i < hashes.length; i += 100) {
    const chunk = hashes.slice(i, i + 100);
    const placeholders = chunk.map(() => "?").join(",");
    const rows = await c.env.DB.prepare(
      `SELECT id, username, display_name, avatar_id, phone_hash FROM users WHERE phone_hash IN (${placeholders})`
    ).bind(...chunk).all<{ id: string; avatar_id: string | null }>();
    matches.push(...rows.results);
  }
  const discoverable = await discoverableBy(c.env, userId, matches.map((m) => m.id));
  const visible = matches.filter((m) => m.id === userId || discoverable.has(m.id));
  const hidden = await hiddenAvatarOwners(c.env, userId, visible.map((m) => m.id));
  for (const m of visible) {
    if (hidden.has(m.id)) m.avatar_id = null;
  }
  return json({ ok: true, matches: visible });
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
  // drop the cached block state in the pair's direct chat, which may not exist yet
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

const REPORT_REASONS = ["spam", "violence", "scam", "other"];

// A report of a chat or a message. The server cannot read messages, so the
// body carries only what the reporter chose to attach, decrypted on their
// device: excerpts of `{seq, senderId, text}`.
app.post("/api/report", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{
    chatId?: string; targetUserId?: string; reason: string; comment?: string;
    attached?: { seq?: number; senderId?: string; text?: string }[];
  }>();
  if (!REPORT_REASONS.includes(b.reason)) return json({ ok: false, error: "bad_reason" }, 400);
  if (!b.chatId && !b.targetUserId) return json({ ok: false, error: "no_target" }, 400);
  const attached = Array.isArray(b.attached) && b.attached.length
    ? JSON.stringify(b.attached.slice(0, 20).map((m) => ({
        seq: typeof m.seq === "number" ? m.seq : null,
        senderId: typeof m.senderId === "string" ? m.senderId : null,
        text: typeof m.text === "string" ? m.text.slice(0, 4096) : null,
      })))
    : null;
  await c.env.DB.prepare(
    "INSERT INTO reports (reporter_id, chat_id, target_user_id, reason, comment, attached, created_at) VALUES (?,?,?,?,?,?,?)"
  ).bind(userId, b.chatId ?? null, b.targetUserId ?? null, b.reason,
         b.comment ? String(b.comment).slice(0, 2048) : null, attached, Date.now()).run();
  return json({ ok: true });
});

const LAST_SEEN_VALUES: LastSeenVisibility[] = ["everyone", "contacts", "nobody"];

app.get("/api/privacy", async (c) => {
  const { userId } = c.get("auth");
  return json({ ok: true, privacy: await readPrivacy(c.env.DB, userId) });
});

const EXCEPTION_SETTINGS = ["last_seen", "avatar", "phone_discovery", "group_invites", "call"];

// Named-people overrides of the tiers: who is always shown the setting and
// who never is, whatever the tier says.
app.get("/api/privacy/exceptions", async (c) => {
  const { userId } = c.get("auth");
  const rows = await c.env.DB.prepare(
    `SELECT e.setting, e.peer_id, e.allow, u.username, u.display_name
     FROM privacy_exceptions e JOIN users u ON u.id = e.peer_id
     WHERE e.user_id = ?`
  ).bind(userId).all<{
    setting: string; peer_id: string; allow: number; username: string; display_name: string;
  }>();
  return json({ ok: true, exceptions: rows.results.map((r) => ({
    setting: r.setting, peerId: r.peer_id, allow: r.allow === 1,
    username: r.username, displayName: r.display_name,
  })) });
});

app.post("/api/privacy/exceptions", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ setting?: string; peerId?: string; allow?: boolean | null }>();
  if (!b.setting || !EXCEPTION_SETTINGS.includes(b.setting) || !b.peerId || b.peerId === userId) {
    return err("bad_exception");
  }
  const peer = await c.env.DB.prepare("SELECT 1 FROM users WHERE id = ?").bind(b.peerId).first();
  if (!peer) return err("not_found", 404);
  if (b.allow === null || b.allow === undefined) {
    await c.env.DB.prepare(
      "DELETE FROM privacy_exceptions WHERE user_id = ? AND setting = ? AND peer_id = ?"
    ).bind(userId, b.setting, b.peerId).run();
  } else {
    await c.env.DB.prepare(
      `INSERT INTO privacy_exceptions (user_id, setting, peer_id, allow) VALUES (?,?,?,?)
       ON CONFLICT(user_id, setting, peer_id) DO UPDATE SET allow = excluded.allow`
    ).bind(userId, b.setting, b.peerId, b.allow ? 1 : 0).run();
  }
  // an avatar override changes what this peer already holds from the last
  // profile frame; the broadcast is one card for all, so it only helps when
  // the change makes the card MORE hidden — an allowed peer refetches
  if (b.setting === "avatar") await broadcastProfile(c.env, userId);
  return json({ ok: true });
});

// The setting itself is what's enforced, not just hidden client-side: a hidden
// last seen never rides the presence frame (presenceVisible, ConversationDO
// /presence), and receipts/typing turned off never leave ConversationDO's
// /recv, /read and /typing handlers.
app.post("/api/privacy", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{
    lastSeen?: string; avatar?: string; phoneDiscovery?: string; groupInvites?: string;
    callPrivacy?: string; readReceipts?: boolean; typing?: boolean;
  }>();
  for (const tier of [b.lastSeen, b.avatar, b.phoneDiscovery, b.groupInvites, b.callPrivacy]) {
    if (tier !== undefined && !LAST_SEEN_VALUES.includes(tier as LastSeenVisibility)) {
      return err("bad_privacy");
    }
  }
  const current = await readPrivacy(c.env.DB, userId);
  const next = {
    lastSeen: (b.lastSeen as LastSeenVisibility | undefined) ?? current.lastSeen,
    avatar: (b.avatar as LastSeenVisibility | undefined) ?? current.avatar,
    phoneDiscovery: (b.phoneDiscovery as LastSeenVisibility | undefined) ?? current.phoneDiscovery,
    groupInvites: (b.groupInvites as LastSeenVisibility | undefined) ?? current.groupInvites,
    callPrivacy: (b.callPrivacy as LastSeenVisibility | undefined) ?? current.callPrivacy,
    readReceipts: b.readReceipts ?? current.readReceipts,
    typing: b.typing ?? current.typing,
  };
  await c.env.DB.prepare(
    `INSERT INTO privacy_settings (user_id, last_seen, avatar_visibility, phone_discovery,
       group_invites, call_privacy, read_receipts, typing, updated_at)
     VALUES (?,?,?,?,?,?,?,?,?)
     ON CONFLICT(user_id) DO UPDATE SET last_seen = excluded.last_seen,
       avatar_visibility = excluded.avatar_visibility,
       phone_discovery = excluded.phone_discovery,
       group_invites = excluded.group_invites,
       call_privacy = excluded.call_privacy,
       read_receipts = excluded.read_receipts, typing = excluded.typing,
       updated_at = excluded.updated_at`
  ).bind(userId, next.lastSeen, next.avatar, next.phoneDiscovery, next.groupInvites,
         next.callPrivacy, next.readReceipts ? 1 : 0, next.typing ? 1 : 0, Date.now()).run();
  // peers hold the card from the last profile frame, so a photo hidden or shown
  // again travels to them at once instead of waiting for a refetch
  if (next.avatar !== current.avatar) await broadcastProfile(c.env, userId);
  return json({ ok: true, privacy: next });
});

// --- stories ---
//
// A story is not end-to-end encrypted. Who may see one is an access rule, not a
// key: that is what lets it live for a day for a chosen audience, and what
// makes a public link possible at all. The composer says so before the story
// goes out.

interface StoryRow {
  id: string; author_id: string; created_at: number; expires_at: number;
  frames: string; audience: string;
  link_code: string | null; link_revoked: number; taken_down: number;
}

const STORY_AUDIENCES = ["everyone", "contacts"];
/// How long a story may be asked to live. A day is the default; a week is the
/// ceiling, so nothing published by accident stays for a month.
const STORY_MAX_HOURS = 24 * 7;

/// The frames as the composer built them: a media id per frame, and the text
/// laid over it. The server keeps them as they are — it renders the public
/// page from them and hands them to the app unchanged.
function cleanFrames(value: unknown): unknown[] | null {
  if (!Array.isArray(value) || value.length === 0 || value.length > 20) return null;
  for (const f of value) {
    const frame = f as { mediaId?: unknown; type?: unknown };
    if (typeof frame?.mediaId !== "string" || !frame.mediaId) return null;
    if (frame.type !== "photo" && frame.type !== "video") return null;
  }
  return value;
}

/// The people this user has a direct chat with. A direct chat's id is derived
/// from the two ids, so the list is read out of the chat list itself without
/// asking a single conversation object.
async function directPeers(env: Env, userId: string): Promise<string[]> {
  const r = await userStub(env, userId).fetch("https://do/chats");
  const { chats } = (await r.json()) as { chats: Record<string, unknown> };
  const peers: string[] = [];
  for (const chatId of Object.keys(chats)) {
    if (!chatId.startsWith("direct:")) continue;
    const [a, b] = chatId.slice("direct:".length).split(":");
    const peer = a === userId ? b : a;
    if (peer && peer !== userId) peers.push(peer);
  }
  return peers;
}

/// The address a story link is minted under. Behind the tunnel the worker sees
/// plain http, while the browser that opens the link came in over https.
function publicOrigin(c: { req: { url: string; header: (name: string) => string | undefined } }): string {
  const url = new URL(c.req.url);
  const proto = c.req.header("x-forwarded-proto");
  return `${proto ?? url.protocol.replace(":", "")}://${url.host}`;
}

app.post("/api/stories", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{
    frames: unknown; audience?: string; hours?: number; link?: boolean;
  }>();
  const frames = cleanFrames(b.frames);
  if (!frames) return err("bad_frames");
  const audience = b.audience ?? "contacts";
  if (!STORY_AUDIENCES.includes(audience)) return err("bad_audience");
  const hours = Math.min(Math.max(b.hours ?? 24, 1), STORY_MAX_HOURS);
  const now = Date.now();
  const id = ulid(now);
  const code = b.link ? b64url(crypto.getRandomValues(new Uint8Array(9))) : null;
  await c.env.DB.prepare(
    `INSERT INTO stories (id, author_id, created_at, expires_at, frames, audience, link_code)
     VALUES (?,?,?,?,?,?,?)`
  ).bind(id, userId, now, now + hours * 3600_000, JSON.stringify(frames), audience, code).run();
  return json({ ok: true, storyId: id, link: code ? `${publicOrigin(c)}/s/${code}` : null });
});

/// Everything this user may watch right now, newest author first, with their
/// own stories among them.
app.get("/api/stories", async (c) => {
  const { userId } = c.get("auth");
  const now = Date.now();
  const peers = await directPeers(c.env, userId);
  const ids = [...new Set([userId, ...peers])];
  const placeholders = ids.map(() => "?").join(",");
  const rows = await c.env.DB.prepare(
    `SELECT s.*, u.username, u.display_name, u.avatar_id
     FROM stories s JOIN users u ON u.id = s.author_id
     WHERE s.taken_down = 0 AND s.expires_at > ?
       AND (s.author_id IN (${placeholders}) OR s.audience = 'everyone')
     ORDER BY s.created_at`
  ).bind(now, ...ids).all<StoryRow & { username: string; display_name: string; avatar_id: string | null }>();
  const seen = await c.env.DB.prepare(
    "SELECT story_id FROM story_views WHERE viewer_id = ?"
  ).bind(userId).all<{ story_id: string }>();
  const watched = new Set(seen.results.map((r) => r.story_id));
  const blocked = await c.env.DB.prepare(
    "SELECT user_id, blocked_id FROM blocks WHERE user_id = ? OR blocked_id = ?"
  ).bind(userId, userId).all<{ user_id: string; blocked_id: string }>();
  const hidden = new Set(blocked.results.flatMap((r) => [r.user_id, r.blocked_id]));
  const stories = rows.results
    .filter((r) => !hidden.has(r.author_id) || r.author_id === userId)
    .map((r) => ({
      id: r.id, authorId: r.author_id, username: r.username, displayName: r.display_name,
      avatarId: r.avatar_id, createdAt: r.created_at, expiresAt: r.expires_at,
      frames: JSON.parse(r.frames), audience: r.audience,
      link: r.link_code && !r.link_revoked ? `${publicOrigin(c)}/s/${r.link_code}` : null,
      seen: watched.has(r.id),
    }));
  return json({ ok: true, stories });
});

app.post("/api/stories/:id/seen", async (c) => {
  const { userId } = c.get("auth");
  // the author looking at their own story is not a viewer
  const own = await c.env.DB.prepare(
    "SELECT 1 FROM stories WHERE id = ? AND author_id = ?"
  ).bind(c.req.param("id"), userId).first();
  if (own) return json({ ok: true });
  await c.env.DB.prepare(
    `INSERT INTO story_views (story_id, viewer_id, seen_at) VALUES (?,?,?)
     ON CONFLICT(story_id, viewer_id) DO NOTHING`
  ).bind(c.req.param("id"), userId, Date.now()).run();
  return json({ ok: true });
});

/// Who watched. The creator's alone: nobody else is told, and the public page
/// is not counted at all.
app.get("/api/stories/:id/viewers", async (c) => {
  const { userId } = c.get("auth");
  const story = await c.env.DB.prepare(
    "SELECT author_id FROM stories WHERE id = ?"
  ).bind(c.req.param("id")).first<{ author_id: string }>();
  if (!story) return err("not_found", 404);
  if (story.author_id !== userId) return err("not_author", 403);
  const rows = await c.env.DB.prepare(
    `SELECT v.viewer_id, v.seen_at, u.username, u.display_name, u.avatar_id
     FROM story_views v JOIN users u ON u.id = v.viewer_id
     WHERE v.story_id = ? ORDER BY v.seen_at DESC`
  ).bind(c.req.param("id")).all();
  return json({ ok: true, viewers: rows.results });
});

/// Taking it down, and minting or revoking its public link.
app.post("/api/stories/:id", async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");
  const b = await c.req.json<{ takeDown?: boolean; link?: boolean }>();
  const story = await c.env.DB.prepare(
    "SELECT * FROM stories WHERE id = ?"
  ).bind(id).first<StoryRow>();
  if (!story) return err("not_found", 404);
  if (story.author_id !== userId) return err("not_author", 403);
  if (b.takeDown) {
    await c.env.DB.prepare("UPDATE stories SET taken_down = 1 WHERE id = ?").bind(id).run();
    return json({ ok: true });
  }
  if (b.link === true) {
    // a revoked link is never handed out again: a new one is a new code
    const code = story.link_code && !story.link_revoked
      ? story.link_code
      : b64url(crypto.getRandomValues(new Uint8Array(9)));
    await c.env.DB.prepare(
      "UPDATE stories SET link_code = ?, link_revoked = 0 WHERE id = ?"
    ).bind(code, id).run();
    return json({ ok: true, link: `${publicOrigin(c)}/s/${code}` });
  }
  if (b.link === false) {
    await c.env.DB.prepare("UPDATE stories SET link_revoked = 1 WHERE id = ?").bind(id).run();
    return json({ ok: true, link: null });
  }
  return err("nothing_to_do");
});

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (!env.PERF_LOG) return handle(req, env, ctx);
    const t0 = Date.now();
    const counters = newCounters();
    const res = await handle(req, { ...env, DB: wrapDB(env.DB, counters) }, ctx);
    // 101 has no body to read, and reading one would consume the socket
    let size = 0;
    let out = res;
    if (res.status !== 101 && res.body) {
      const body = await res.clone().arrayBuffer();
      size = body.byteLength;
      out = new Response(body, res);
    }
    const u = new URL(req.url);
    console.log(`HTTP ${JSON.stringify({
      method: req.method, path: u.pathname, query: u.search.slice(1),
      status: res.status, down: size, ms: Date.now() - t0, d1: counters.d1,
    })}`);
    return out;
  },
};

async function handle(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  {
    const url = new URL(req.url);

    // WS: authenticated here, the upgrade itself is done by UserDO
    if (url.pathname === "/ws") {
      if (req.headers.get("upgrade")?.toLowerCase() !== "websocket")
        return err("expected_websocket", 426);
      // the client version is read before auth: a socket this server can no
      // longer serve gets a stated refusal instead of a silent drop
      const clientProtocol = Number(url.searchParams.get("v") ?? "0");
      if (!Number.isFinite(clientProtocol) || clientProtocol < MIN_CLIENT_PROTOCOL) {
        return json(
          {
            ok: false,
            error: "client_too_old",
            protocol: PROTOCOL_VERSION,
            minProtocol: MIN_CLIENT_PROTOCOL,
          },
          426
        );
      }
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
  }
}
