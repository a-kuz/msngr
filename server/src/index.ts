import { Hono } from "hono";
import type { Env, AuthCtx, ChatState, ChatKind, PublicUser, PrivacySettings, StoryItem } from "./types";
import { authenticate } from "./auth";
import {
  ulid, newToken, sha256hex, json, err, directChatName, b64url, provisionCode,
  isValidUsername, isValidDisplayName, verifyEd25519, readPrivacy, userStub,
  privacyAllows, privacyChecks, cardFor, cardsFor, userAvatarId, avatarOwner, DOError,
} from "./util";
import type { LastSeenVisibility } from "./types";
import { PROTOCOL_VERSION, MIN_CLIENT_PROTOCOL } from "./version";
import { claimHandle, releaseHandle, resolveHandle } from "./do/HandleDO";
import {
  directoryPut, directoryRemove, directorySearch, phoneIndexPut, phoneIndexFind,
} from "./do/DirectoryDO";
import {
  lookupPut, lookupClaim, lookupGet, lookupPatch, lookupDelete,
} from "./do/LookupDO";
import { PRESENCE_GROUP_MAX } from "./presence";
import { roomToken, sfuConfigured, ROOM_TOKEN_TTL_SEC } from "./calls/livekit";
import { wrapStub } from "./perf";

export { UserDO } from "./do/UserDO";
export { ConversationDO } from "./do/ConversationDO";
export { ApnsTokenDO } from "./do/ApnsTokenDO";
export { HandleDO } from "./do/HandleDO";
export { DirectoryDO } from "./do/DirectoryDO";
export { StoriesDO } from "./do/StoriesDO";
export { LookupDO } from "./do/LookupDO";
import { storiesStub, authorOf, authorOfLink } from "./do/StoriesDO";

type Vars = { auth: AuthCtx };
const app = new Hono<{ Bindings: Env; Variables: Vars }>();

// A refusal an RPC method throws (DOError) answers exactly as the same
// refusal did over `fetch`: the same code and status, `{ ok: false, error }`.
app.onError((e) => {
  const d = DOError.from(e);
  if (d) return err(d.error, d.status);
  throw e;
});

function convStub(env: Env, chatId: string) {
  return wrapStub(env.CONV_DO.get(env.CONV_DO.idFromName(chatId)));
}

/// The chat's state, or the same not_member refusal a chat that never
/// existed used to answer with over `fetch` (`state()` throws
/// chat_not_found where a caller only ever distinguished "not a member").
async function chatStateOrNotMember(env: Env, chatId: string): Promise<ChatState> {
  try {
    return (await convStub(env, chatId).state()).state;
  } catch {
    throw new DOError("not_member", 403);
  }
}

/// The account's card as the account itself holds it: the row every pull path
/// starts from, before any viewer's rule is applied to it.
async function ownProfile(
  env: Env, userId: string,
): Promise<(PublicUser & { phone_hash: string | null }) | null> {
  try {
    return (await userStub(env, userId).profileRead()).profile as
      PublicUser & { phone_hash: string | null };
  } catch {
    return null;
  }
}

/// Copies the account's card into the people-search index, from the object
/// where a profile change lands first.
async function indexUser(env: Env, userId: string): Promise<void> {
  const p = await ownProfile(env, userId);
  if (p) {
    await directoryPut(env, {
      id: p.id, username: p.username, display_name: p.display_name,
      avatar_id: p.avatar_id, bot_owner: p.bot_owner ?? null,
      bot_commands: p.bot_commands ?? null,
    });
  }
}

/// Whether a block stands between the two, either way. Both objects hold the
/// pair, so the one already at hand answers it.
async function blockedPair(env: Env, a: string, b: string): Promise<boolean> {
  const { byMe, byPeer } = await userStub(env, a).blockPair(b);
  return byMe || byPeer;
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

/// The frames behind a public link, from the author's object the code names.
/// A link that was revoked, a story taken down and a story whose day is over
/// all read the same from outside: there is nothing here any more.
async function publicFrames(env: Env, code: string): Promise<Array<{
  mediaId: string; type: string; text?: string; textColor?: string; plateColor?: string;
  tx?: number; ty?: number;
}> | null> {
  const author = await authorOfLink(env, code);
  if (!author) return null;
  try {
    const r = await storiesStub(env, author).publicFrames(code) as { frames: unknown[] };
    return r.frames as Array<{ mediaId: string; type: string }>;
  } catch {
    return null;
  }
}

app.get("/s/:code", async (c) => {
  const frames = await publicFrames(c.env, c.req.param("code"));
  if (!frames) {
    return storyPage("msngr", `<p class="note">Эта ссылка больше не открывается.</p>`);
  }
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
  const frames = await publicFrames(c.env, c.req.param("code"));
  if (!frames) return err("not_found", 404);
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
  const token = newToken(userId);
  const tokenHash = await sha256hex(token);

  // The handle object is the authority: the claim is the one step that can
  // lose to someone else, so it goes first and nothing is written for a
  // handle that was not won.
  if (!(await claimHandle(c.env, b.username, userId))) return err("username_taken", 409);

  // The keys, the card and the first session are one write inside the object:
  // an account is either whole or was never opened.
  try {
    await userStub(c.env, userId).keysRegister({
      userId, deviceId,
      identityKey: b.identityKey, identitySignKey: b.identitySignKey,
      identityKeySig: b.identityKeySig, signedPrekey: b.signedPrekey,
      oneTimePrekeys: b.oneTimePrekeys,
      profile: {
        id: userId, username: b.username, display_name: b.displayName.trim(),
        bio: null, avatar_id: null, bot_owner: null, bot_commands: null,
        phone_hash: b.phoneHash ?? null, created_at: now,
      },
      device: { deviceId, name: b.device?.name ?? null, tokenHash },
    });
  } catch {
    await releaseHandle(c.env, b.username, userId, false);
    return err("keys_write_failed", 500);
  }
  await indexUser(c.env, userId);
  if (b.phoneHash) await phoneIndexPut(c.env, b.phoneHash, userId);
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

interface ProvisionRec {
  id: string; code: string; tokenHash: string; ephemeralKey: string;
  deviceName: string | null; platform: string | null;
  expiresAt: number; approvedBy: string | null; envelope: string | null;
  claimedAt: number | null;
}

/// The session named by the path, once its token matches and it is still alive.
async function provisionSession(
  env: Env, req: Request, id: string
): Promise<{ rec: ProvisionRec } | { error: Response }> {
  const token = req.headers.get("x-provision-token");
  if (!token) return { error: err("unauthorized", 401) };
  const rec = await lookupGet<ProvisionRec>(env, "prov", id);
  if (!rec) return { error: err("provision_not_found", 404) };
  if (rec.tokenHash !== (await sha256hex(token))) return { error: err("unauthorized", 401) };
  if (rec.expiresAt <= Date.now()) return { error: err("provision_expired", 410) };
  return { rec };
}

app.post("/api/provision/start", async (c) => {
  const b = await c.req.json<{
    ephemeralKey: string; device?: { name?: string; platform?: string };
  }>();
  if (!b.ephemeralKey) return err("bad_keys");
  const now = Date.now();
  const id = ulid(now);
  const provisionToken = newToken(id);
  const tokenHash = await sha256hex(provisionToken);
  const expiresAt = now + PROVISION_TTL * 1000;
  // the code names an object of its own, so a code still in use is one the
  // claim loses to; a collision costs one more draw
  for (let attempt = 0; ; attempt++) {
    const code = provisionCode();
    if (await lookupClaim(c.env, "pcode", code, { id, expiresAt })) {
      await lookupPut(c.env, "prov", id, {
        id, code, tokenHash, ephemeralKey: b.ephemeralKey,
        deviceName: b.device?.name ?? null, platform: b.device?.platform ?? null,
        expiresAt, approvedBy: null, envelope: null, claimedAt: null,
      } satisfies ProvisionRec);
      return json({
        ok: true, provisionId: id, code, provisionToken, expiresIn: PROVISION_TTL,
      });
    }
    if (attempt >= 4) return err("provision_code_unavailable", 503);
  }
});

// Polled by the device being linked until its owner approves on the other one.
app.get("/api/provision/:id", async (c) => {
  const s = await provisionSession(c.env, c.req.raw, c.req.param("id"));
  if ("error" in s) return s.error;
  if (s.rec.claimedAt) return err("provision_claimed", 409);
  if (!s.rec.envelope) return json({ ok: true, status: "pending" });
  return json({ ok: true, status: "approved", envelope: s.rec.envelope });
});

// The device takes the account: its row, its identity keys and its prekeys go
// in together, and the session is spent.
app.post("/api/provision/:id/claim", async (c) => {
  const s = await provisionSession(c.env, c.req.raw, c.req.param("id"));
  if ("error" in s) return s.error;
  if (s.rec.claimedAt) return err("provision_claimed", 409);
  if (!s.rec.approvedBy || !s.rec.envelope) return err("provision_not_approved", 409);
  const b = await c.req.json<{
    identityKey: string; identitySignKey: string; identityKeySig: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekeys: Array<{ id: number; key: string }>;
    device?: { name?: string };
  }>();
  if (!b.identityKey || !b.identitySignKey || !b.identityKeySig || !b.signedPrekey?.key) {
    return err("bad_keys");
  }

  const userId = s.rec.approvedBy;
  // The identity belongs to the account, not to the device: a device that does
  // not present the account's own keys is not one this account authorised.
  const known = await userStub(c.env, userId).keysDevices();
  if (!known.devices.length) return err("account_has_no_devices", 409);
  const matches = known.devices.every(
    (k) => k.identityKey === b.identityKey && k.identitySignKey === b.identitySignKey
  );
  if (!matches) return err("identity_mismatch", 409);

  const now = Date.now();
  const deviceId = ulid(now);
  const token = newToken(userId);
  // The session is spent first: it is the one step two racing claims can only
  // win once, and the keys and the device go in together after it.
  const spent = await lookupPatch<ProvisionRec>(
    c.env, "prov", s.rec.id, { claimedAt: now, envelope: null }, ["claimedAt"]);
  if (!spent) return err("provision_claimed", 409);
  try {
    await userStub(c.env, userId).keysRegister({
      userId, deviceId,
      identityKey: b.identityKey, identitySignKey: b.identitySignKey,
      identityKeySig: b.identityKeySig, signedPrekey: b.signedPrekey,
      oneTimePrekeys: b.oneTimePrekeys ?? [], bump: true,
      device: {
        deviceId, name: b.device?.name ?? s.rec.deviceName,
        tokenHash: await sha256hex(token),
      },
    });
  } catch {
    return err("keys_write_failed", 500);
  }
  return json({ ok: true, userId, deviceId, token });
});

app.post("/api/provision/:id/cancel", async (c) => {
  const s = await provisionSession(c.env, c.req.raw, c.req.param("id"));
  if ("error" in s) return s.error;
  await lookupDelete(c.env, "prov", s.rec.id);
  await lookupDelete(c.env, "pcode", s.rec.code);
  return json({ ok: true });
});

// --- restoring from a backup (no auth: this device has no account yet, and no
// other device is asked to approve it — the nonce signature below stands in
// for that approval) ---

/// Life of a restore session, seconds. The nonce is signed and posted back in
/// one round trip, so this only has to outlast a slow network, not a person.
const RESTORE_TTL = 120;

interface RestoreRec {
  id: string; userId: string; identityKey: string; identitySignKey: string;
  nonce: string; expiresAt: number; claimedAt: number | null;
}

app.post("/api/restore/start", async (c) => {
  const b = await c.req.json<{ username: string }>();
  if (!isValidUsername(b.username)) return err("bad_username");
  const ownerId = await resolveHandle(c.env, b.username);
  if (!ownerId) return err("account_not_found", 404);
  const user = { id: ownerId };
  const known = await userStub(c.env, user.id).keysDevices();
  // The account identity outlives its devices: logging out everywhere is the
  // exact state a backup restore is for, so the check is against the account
  // record, not against a live device.
  const identity = known.account ?? known.devices[0];
  if (!identity) return err("account_has_no_devices", 409);
  const { identityKey, identitySignKey } = identity;
  const now = Date.now();
  const id = ulid(now);
  const nonce = b64url(crypto.getRandomValues(new Uint8Array(32)));
  await lookupPut(c.env, "rest", id, {
    id, userId: user.id, identityKey, identitySignKey, nonce,
    expiresAt: now + RESTORE_TTL * 1000, claimedAt: null,
  } satisfies RestoreRec);
  return json({ ok: true, restoreId: id, nonce, expiresIn: RESTORE_TTL });
});

// The device proves it holds the account's identity private key by signing
// the session's nonce; the server checks that signature against the identity
// key already on file, then adds this device exactly as a live approval would.
app.post("/api/restore/:id/claim", async (c) => {
  const row = await lookupGet<RestoreRec>(c.env, "rest", c.req.param("id"));
  if (!row) return err("restore_not_found", 404);
  if (row.claimedAt) return err("restore_claimed", 409);
  if (row.expiresAt <= Date.now()) return err("restore_expired", 410);
  const b = await c.req.json<{
    identityKey: string; identitySignKey: string; identityKeySig: string; signature: string;
    signedPrekey: { id: number; key: string; sig: string };
    oneTimePrekeys: Array<{ id: number; key: string }>;
    device?: { name?: string };
  }>();
  if (!b.identityKey || !b.identitySignKey || !b.identityKeySig || !b.signature || !b.signedPrekey?.key) {
    return err("bad_keys");
  }
  if (b.identityKey !== row.identityKey || b.identitySignKey !== row.identitySignKey) {
    return err("identity_mismatch", 409);
  }
  const nonceBytes = new TextEncoder().encode(row.nonce);
  if (!(await verifyEd25519(row.identitySignKey, b.signature, nonceBytes))) {
    return err("bad_signature", 401);
  }

  const userId = row.userId;
  const now = Date.now();
  const deviceId = ulid(now);
  const token = newToken(userId);
  const spent = await lookupPatch<RestoreRec>(
    c.env, "rest", row.id, { claimedAt: now }, ["claimedAt"]);
  if (!spent) return err("restore_claimed", 409);
  try {
    await userStub(c.env, userId).keysRegister({
      userId, deviceId,
      identityKey: b.identityKey, identitySignKey: b.identitySignKey,
      identityKeySig: b.identityKeySig,
      signedPrekey: b.signedPrekey, oneTimePrekeys: b.oneTimePrekeys ?? [], bump: true,
      device: {
        deviceId, name: b.device?.name ?? null, tokenHash: await sha256hex(token),
      },
    });
  } catch {
    return err("keys_write_failed", 500);
  }
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
  const p = await ownProfile(c.env, userId);
  if (!p) return err("not_found", 404);
  const { phone_hash, ...user } = p;
  return json({ ok: true, user, deviceId });
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
  // the token, the sockets, the keys, the version bump and the fan-out are one
  // act inside the user's object
  await userStub(env, userId).revokeDevice(deviceId, userId);
}

/// The account's live sessions, as its own object lists them.
async function sessionsOf(env: Env, userId: string): Promise<Array<{
  deviceId: string; name: string | null; createdAt: number;
  lastSeen: number | null; hasPushToken: boolean;
}>> {
  return (await userStub(env, userId).sessions()).sessions;
}

app.get("/api/sessions", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const sessions = await sessionsOf(c.env, userId);
  return json({
    ok: true,
    sessions: sessions.map((s) => ({ ...s, current: s.deviceId === deviceId })),
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
  const me = await ownProfile(c.env, userId);
  if (me) await releaseHandle(c.env, me.username, userId, false);
  if (me?.phone_hash) await phoneIndexPut(c.env, me.phone_hash, null);
  await directoryRemove(c.env, userId);
  const { chats } = await userStub(c.env, userId).chats();
  for (const chatId of Object.keys(chats ?? {})) {
    if (chatId.startsWith("direct:") || chatId.startsWith("self:")) continue;
    await convStub(c.env, chatId).leave(userId);
  }
  await userStub(c.env, userId).accountWipe();
  await storiesStub(c.env, userId).wipe();
  return json({ ok: true });
});

app.post("/api/sessions/:deviceId/revoke", async (c) => {
  const { userId } = c.get("auth");
  const target = c.req.param("deviceId");
  const sessions = await sessionsOf(c.env, userId);
  if (!sessions.some((s) => s.deviceId === target)) return err("device_not_found", 404);
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
  const named = await lookupGet<{ id: string }>(c.env, "pcode", code);
  const row = named ? await lookupGet<ProvisionRec>(c.env, "prov", named.id) : null;
  if (!row) return err("provision_not_found", 404);
  if (row.expiresAt <= Date.now()) return err("provision_expired", 410);
  if (row.claimedAt || row.approvedBy) return err("provision_claimed", 409);
  return json({
    ok: true, provisionId: row.id, ephemeralKey: row.ephemeralKey,
    device: { name: row.deviceName, platform: row.platform },
    expiresIn: Math.max(0, Math.round((row.expiresAt - Date.now()) / 1000)),
  });
});

// The owner said yes: the sealed account bundle is parked for the one device
// that holds the session's ephemeral private key.
app.post("/api/provision/:id/approve", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ envelope: string }>();
  if (!b.envelope) return err("bad_envelope");
  const row = await lookupGet<ProvisionRec>(c.env, "prov", c.req.param("id"));
  if (!row) return err("provision_not_found", 404);
  if (row.expiresAt <= Date.now()) return err("provision_expired", 410);
  const approved = await lookupPatch<ProvisionRec>(
    c.env, "prov", row.id,
    { approvedBy: userId, approvedAt: Date.now(), envelope: b.envelope },
    ["approvedBy", "claimedAt"]);
  if (!approved) return err("provision_claimed", 409);
  return json({ ok: true });
});

/// Cuts a string to at most `maxBytes` of UTF-8, never splitting a code point.
/// DirectoryDO's LIKE pattern is capped at 50 bytes by the SQLite backend; the
/// query travels lowercased, and folding can grow a character's byte length
/// (a Cyrillic capital folds to a same-length lowercase, but the margin below
/// 50 is kept deliberately wide), so the cut happens here, before the fold.
function cutUtf8Bytes(s: string, maxBytes: number): string {
  const bytes = new TextEncoder().encode(s);
  if (bytes.length <= maxBytes) return s;
  let end = maxBytes;
  // back off out of the middle of a multi-byte code point (continuation
  // bytes are 10xxxxxx)
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end--;
  return new TextDecoder().decode(bytes.subarray(0, end));
}

app.get("/api/users", async (c) => {
  // a username gets typed with a leading @ and stray spaces often enough
  const q = cutUtf8Bytes((c.req.query("q") ?? "").trim().replace(/^@+/, ""), 40);
  if (q.length < 2) return json({ ok: true, users: [] });
  // folded in JS, like the index itself: SQLite's LOWER folds ASCII only, and
  // display names are free Unicode
  const found = await directorySearch(c.env, q.toLowerCase());
  const { userId } = c.get("auth");
  // the index holds one card for everyone; the photo is each owner's to show,
  // so the row this caller sees comes from that owner's own object
  const cards = await cardsFor(c.env, userId, found.map((r) => r.id));
  const users = found.map((r) => cards.get(r.id) ?? { ...r, bio: null });
  return json({ ok: true, users });
});

// A user profile. Presence comes with it only as the target lets this viewer
// see it: the viewer's own object holds a copy of what the target's object has
// pushed to it (a shared chat the target has accepted, the target's last-seen
// tier), and a viewer who hid their own last seen sees nobody's.
app.get("/api/users/:id", async (c) => {
  const { userId } = c.get("auth");
  const targetId = c.req.param("id");
  // the card is the target's to hand out: their object blanks what their own
  // photo rule closes to this viewer, and answers the call rule in the same
  // breath — the dial button is not worth showing on a call that would only
  // come back busy
  const u = await cardFor(c.env, userId, targetId);
  if (!u) return err("not_found", 404);
  const canCall = userId === targetId
    || (await privacyAllows(c.env, targetId, userId, "call"));
  let presence: { online: boolean; lastSeen: number } | null = null;
  if (userId === targetId) {
    presence = await userStub(c.env, targetId).presenceInfo();
  } else {
    // a viewer who hid their own last seen holds no copies at all, so the
    // read below simply finds nothing
    presence = (await userStub(c.env, userId).peerPresenceRead(targetId)).presence;
  }
  return json({ ok: true, user: u, presence, canCall });
});

// The caller's own call gate, asked by the callee's device when an offer
// arrives: whether this account's call tier lets `peerId` ring it. The
// signaling is E2EE, so this judgement cannot live on the send path.
app.get("/api/privacy/may-call/:peerId", async (c) => {
  const { userId } = c.get("auth");
  const peerId = c.req.param("peerId");
  return json({ ok: true, allow: await privacyAllows(c.env, userId, peerId, "call") });
});

// The ticket into a group call's room on the SFU: the caller must be a
// member of the chat the call belongs to, and the room is the call's id.
// The frame key is not here — it travels inside the E2EE `room` invite and
// the live card — so the ticket only gates who may load the SFU at all.
app.post("/api/calls/room", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ callId?: string; chatId?: string }>();
  if (!b.callId || !/^[A-Za-z0-9_-]{8,64}$/.test(b.callId) || !b.chatId) return err("bad_request");
  if (!sfuConfigured(c.env)) return err("sfu_unavailable", 503);
  // the chat records who was ticketed into which room: a member removed
  // while the call goes on is taken out of the room by the chat itself
  const m = await convStub(c.env, b.chatId).roomTicket(userId, b.callId, ROOM_TOKEN_TTL_SEC);
  if (!m.member) return err("not_member", 403);
  const me = await ownProfile(c.env, userId);
  const token = await roomToken(c.env, { userId, name: me?.display_name ?? "", room: b.callId });
  return json({ ok: true, url: c.env.LIVEKIT_URL, token, ttl: ROOM_TOKEN_TTL_SEC });
});

// Devices and identity keys for a list of users (?ids=uid1,uid2). Consumes nothing,
// unlike /prekeys, which hands out a one-time prekey.
app.get("/api/devices", async (c) => {
  const ids = [...new Set((c.req.query("ids") ?? "").split(",").filter(Boolean))].slice(0, 100);
  if (!ids.length) return json({ ok: true, devices: [], versions: {} });
  // each user's list and the version stamped on it come from that user's
  // object in one answer, so per user they are one snapshot
  const perUser = await Promise.all(ids.map(async (id) => {
    const j = await userStub(c.env, id).keysDevices();
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
  const j = await userStub(c.env, userId).keysCount(deviceId);
  return json({ ok: true, count: j.count ?? 0 });
});

// X3DH prekey bundles for every device of a user; a one-time prekey is handed
// out and deleted, and the object serializes the handout: two senders asking at
// once never draw the same key
app.get("/api/users/:id/prekeys", async (c) => {
  const targetId = c.req.param("id");
  const j = await userStub(c.env, targetId).keysPrekeys();
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
  const r = await userStub(c.env, userId).keysUpdate({
    deviceId, identityKey: b.identityKey,
    identitySignKey: b.identitySignKey, identityKeySig: b.identityKeySig,
  });
  return json({ ok: true, ...r });
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
  const r = await userStub(c.env, userId).keysRepublish({
    deviceId, signedPrekey: b.signedPrekey, oneTimePrekeys: b.oneTimePrekeys ?? [],
  });
  return json({ ok: true, ...r });
});

app.post("/api/prekeys", async (c) => {
  const { userId, deviceId } = c.get("auth");
  const b = await c.req.json<{ oneTimePrekeys: Array<{ id: number; key: string }> }>();
  await userStub(c.env, userId).keysTopup(deviceId, b.oneTimePrekeys);
  return json({ ok: true });
});

app.post("/api/profile", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ displayName?: string; bio?: string; avatarId?: string }>();
  if (b.displayName !== undefined && !isValidDisplayName(b.displayName)) return err("bad_name");
  await userStub(c.env, userId).profileWrite({
    displayName: b.displayName, bio: b.bio, avatarId: b.avatarId,
  });
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

  const current = await ownProfile(c.env, userId);
  if (!current) return err("not_found", 404);
  const write = () => userStub(c.env, userId).profileWrite({ username: b.username });
  if (current.username.toLowerCase() === b.username.toLowerCase()) {
    // the same handle in another case: nothing to claim or free
    await write();
  } else {
    if (!(await claimHandle(c.env, b.username, userId))) return err("username_taken", 409);
    await write();
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
  const p = await ownProfile(env, userId);
  if (!p) return;
  const { phone_hash, ...user } = p;
  // peers get the card as they may see it: a hidden photo and bio travel only
  // to the user's own devices. The frame is one card for every peer, so the
  // "contacts" tier blanks it here too — a contact still gets the full card
  // from every pull path, and the bytes route answers them
  let peerUser: PublicUser = user;
  if ((await readPrivacy(env, userId)).avatar !== "everyone") {
    peerUser = { ...user, bio: null, avatar_id: null };
  }
  await userStub(env, userId).profileChanged(user, peerUser);
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
    if (await privacyAllows(env, id, actor, "group_invites")) {
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
  if (b.kind === "direct" && (await blockedPair(c.env, userId, members[0]))) {
    return err("blocked", 403);
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
  const res = await convStub(c.env, chatId).create({
    chatId, kind: b.kind, title: b.title ?? null, memberIds: members, createdBy: userId,
  });
  if (!invited.length) return json({ ok: true, ...res });
  return json({ ok: true, ...res, invited });
});

app.get("/api/chats", async (c) => {
  const { userId } = c.get("auth");
  const { chats } = await userStub(c.env, userId).chats();
  const states: Array<{ flags: unknown; state: ChatState; users: PublicUser[] }> = [];
  await Promise.all(
    Object.entries(chats).map(async ([chatId, flags]) => {
      try {
        const sj = await convStub(c.env, chatId).state();
        states.push({ flags, state: sj.state, users: sj.users ?? [] });
      } catch { /* the chat is gone */ }
    })
  );
  const memberIds = [...new Set(states.flatMap((s) => s.state.members.map((m) => m.userId)))];
  // The names come free with the chats: each conversation holds its roster's
  // public cards. The photo and the bio are per-viewer, and this caller's own
  // object holds them — a copy each peer pushed as that peer lets this one see
  // it. Anybody left over (a roster too large for presence relations to be
  // built over) is asked directly.
  const cards = new Map<string, PublicUser>();
  for (const s of states) for (const u of s.users) cards.set(u.id, u);
  for (const u of (await userStub(c.env, userId).peerCards()).cards) cards.set(u.id, u);
  const own = await ownProfile(c.env, userId);
  if (own) {
    const { phone_hash, ...card } = own;
    cards.set(userId, card);
  }
  const unknown = memberIds.filter((id) => !cards.has(id));
  for (const [id, card] of await cardsFor(c.env, userId, unknown)) cards.set(id, card);
  const users = memberIds.flatMap((id) => (cards.has(id) ? [cards.get(id)!] : []));
  return json({
    ok: true,
    chats: states.map((s) => ({ flags: s.flags, state: s.state })),
    users,
  });
});

app.get("/api/chats/:id/history", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.param("id");
  // membership is checked by the object itself on the read that serves the page:
  // asking for it first costs a second invocation on every page of history
  const qs = new URL(c.req.url).searchParams;
  const r = await convStub(c.env, chatId).history({
    userId,
    fromSeq: qs.has("fromSeq") ? Number(qs.get("fromSeq")) : undefined,
    toSeq: qs.has("toSeq") ? Number(qs.get("toSeq")) : undefined,
    limit: qs.has("limit") ? Number(qs.get("limit")) : undefined,
    dir: qs.get("dir") === "back" ? "back" : undefined,
  }) as { msgs: unknown[]; scanned: number; lastScannedSeq: number | null };
  return json({ ok: true, ...r });
});

// Fanout queue of the chat: depth and the head job's delivery cursor.
app.get("/api/chats/:id/fanout", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.param("id");
  const state = await chatStateOrNotMember(c.env, chatId);
  if (!state.members.some((m) => m.userId === userId))
    return err("not_member", 403);
  const r = await convStub(c.env, chatId).fanoutState();
  return json({ ok: true, ...r });
});

// Dev test hook: the caller's own session object rejects the next n frame
// deliveries, which exercises the fanout retry path end to end.
app.post("/api/dev/fault", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ failEvents: number }>();
  const r = await userStub(c.env, userId).devFault(b.failEvents);
  return json({ ok: true, ...r });
});

// Dev hook for a stand whose chats predate presence subscriptions: the
// caller's object is told every chat it is in with the current roster, which
// builds its relations and pushes its presence to the peers. Each account
// relinks for itself; the peers' own relations come from their own call.
// Dev test hook: the caller's own session object drains its push queue at
// once, standing in for an alarm that fires a second time.
app.post("/api/dev/drain-pushes", async (c) => {
  const { userId } = c.get("auth");
  await userStub(c.env, userId).devDrainPushes();
  return json({ ok: true });
});

app.post("/api/dev/relink", async (c) => {
  const { userId } = c.get("auth");
  const { chats } = await userStub(c.env, userId).chats();
  let relinked = 0;
  for (const chatId of Object.keys(chats)) {
    let sj: { state: ChatState };
    try {
      sj = await convStub(c.env, chatId).state();
    } catch {
      continue;
    }
    const me = sj.state.members.find((m) => m.userId === userId);
    if (!me) continue;
    const peers = sj.state.members.map((m) => m.userId).filter((id) => id !== userId);
    await userStub(c.env, userId).chatAdded(
      chatId, me.accepted, peers.length < PRESENCE_GROUP_MAX ? peers : []);
    relinked++;
  }
  return json({ ok: true, relinked });
});

app.post("/api/chats/:id/members", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ add?: string[]; remove?: string[] }>();
  // whoever guards being added is left out; the adder's client offers the
  // invite link instead. Joining yourself by that link is not an add.
  const { addable, invited } = await addableToGroup(c.env, userId,
    [...new Set(b.add ?? [])].filter((u) => u !== userId));
  const selfJoin = (b.add ?? []).includes(userId) ? [userId] : [];
  await convStub(c.env, c.req.param("id")).members({
    actor: userId, add: [...selfJoin, ...addable], remove: b.remove ?? [],
  });
  return json({ ok: true, ...(invited.length ? { invited } : {}) });
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
  await convStub(c.env, c.req.param("id")).recv(userId, seqs);
  return json({ ok: true });
});

app.post("/api/chats/:id/accept", async (c) => {
  const { userId } = c.get("auth");
  await convStub(c.env, c.req.param("id")).accept(userId);
  return json({ ok: true });
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
  const state = await chatStateOrNotMember(c.env, chatId);
  if (!state.members.some((m) => m.userId === userId))
    return err("not_member", 403);
  if (state.kind === "group") {
    await convStub(c.env, chatId).leave(userId);
    return json({ ok: true });
  }
  await convStub(c.env, chatId).read(userId, state.lastSeq);
  await userStub(c.env, userId).chatRemoved(chatId);
  return json({ ok: true });
});

app.post("/api/chats/:id/settings", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json();
  await convStub(c.env, c.req.param("id")).settings({ ...b, actor: userId });
  return json({ ok: true });
});

app.post("/api/chats/:id/admins", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ userId: string; admin: boolean }>();
  await convStub(c.env, c.req.param("id")).admins(userId, b.userId, b.admin);
  return json({ ok: true });
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
  const token = newToken(botId);
  if (!(await claimHandle(c.env, b.username, botId))) return err("username_taken", 409);
  // a bot is an account: its own object, its own card, its own session — it
  // simply has no keys, which is what makes its chats readable
  try {
    await userStub(c.env, botId).botRegister({
      userId: botId,
      profile: {
        id: botId, username: b.username, display_name: b.displayName.trim(),
        bio: null, avatar_id: null, bot_owner: userId,
        bot_commands: JSON.stringify(commands), phone_hash: null, created_at: now,
      },
      device: { deviceId, name: "bot", tokenHash: await sha256hex(token) },
    });
  } catch {
    await releaseHandle(c.env, b.username, botId, false);
    return err("bot_write_failed", 500);
  }
  // the owner's own object lists what they run: there is no index from an
  // owner back to their bots anywhere else
  await userStub(c.env, userId).botOwnedWrite(botId, true);
  await indexUser(c.env, botId);
  return json({ ok: true, botId, token });
});

app.get("/api/bots", async (c) => {
  const { userId } = c.get("auth");
  const { botIds } = await userStub(c.env, userId).botOwnedRead();
  const cards = await Promise.all(botIds.map((id) => ownProfile(c.env, id)));
  const bots = cards.flatMap((p) => (p ? [{
    id: p.id, username: p.username, display_name: p.display_name,
    bot_commands: p.bot_commands ?? null,
  }] : []));
  return json({ ok: true, bots });
});

/// The owner edits the bot's name and its command list, and asks for a fresh
/// token when the old one has been seen by the wrong eyes.
app.post("/api/bots/:id", async (c) => {
  const { userId } = c.get("auth");
  const botId = c.req.param("id");
  const b = await c.req.json<{ displayName?: string; commands?: unknown; newToken?: boolean }>();
  const bot = await ownProfile(c.env, botId);
  if (!bot || bot.bot_owner !== userId) return err("not_owner", 403);
  if (b.displayName !== undefined && !isValidDisplayName(b.displayName)) return err("bad_name");
  let commandsJson: string | undefined;
  if (b.commands !== undefined) {
    const commands = cleanCommands(b.commands);
    if (commands === null) return err("bad_commands");
    commandsJson = JSON.stringify(commands);
  }
  if (b.displayName !== undefined || commandsJson !== undefined) {
    await userStub(c.env, botId).profileWrite({
      displayName: b.displayName, botCommands: commandsJson,
    });
    await indexUser(c.env, botId);
  }
  let token: string | undefined;
  if (b.newToken) {
    token = newToken(botId);
    await userStub(c.env, botId).deviceRetoken(undefined, await sha256hex(token));
  }
  return json({ ok: true, token });
});

app.post("/api/chats/:id/roles", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ userId: string; role: "editor" | "reader" }>();
  await convStub(c.env, c.req.param("id")).roles(userId, b.userId, b.role);
  return json({ ok: true });
});

// A channel's posts are journaled in the clear, so its history is searched
// where it lies. Every other kind is E2EE and is searched on the device.
app.get("/api/chats/:id/search", async (c) => {
  const { userId } = c.get("auth");
  const qs = new URL(c.req.url).searchParams;
  const r = await convStub(c.env, c.req.param("id")).search(
    userId, qs.get("q") ?? "", qs.has("limit") ? Number(qs.get("limit")) : undefined);
  return json({ ok: true, ...r });
});

app.post("/api/chats/:id/pin-message", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ seq?: number | null; pinned?: boolean }>();
  await convStub(c.env, c.req.param("id")).pinMessage(userId, b.seq, b.pinned);
  return json({ ok: true });
});

// The user's default push sounds by chat shape; a chat's own sound (a flag)
// overrides them, and both resolve on the object that sends the push.
app.get("/api/notify-sounds", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).notifySoundsRead();
  return json({ ok: true, ...r });
});
// A person's own sound, applied to their messages wherever they write; a
// chat's explicit sound still wins inside that chat.
app.get("/api/notify-sounds/person/:id", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).personSound(c.req.param("id"), undefined, true);
  return json({ ok: true, ...r });
});
app.post("/api/notify-sounds/person/:id", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ sound?: string | null }>();
  await userStub(c.env, userId).personSound(c.req.param("id"), b.sound ?? null);
  return json({ ok: true });
});

app.post("/api/notify-sounds", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ direct?: string | null; group?: string | null }>();
  const r = await userStub(c.env, userId).notifySoundsWrite(b);
  return json({ ok: true, ...r });
});

// Every chat and person with a sound of their own, for the settings list.
app.get("/api/notify-sounds/exceptions", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).soundExceptions();
  return json({ ok: true, ...r });
});

app.get("/api/chats/:id/flags", async (c) => {
  const { userId } = c.get("auth");
  const r = await userStub(c.env, userId).flagsRead(c.req.param("id"));
  return json({ ok: true, ...r });
});

app.post("/api/chats/:id/flags", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json();
  await userStub(c.env, userId).flags({ ...b, chatId: c.req.param("id") });
  return json({ ok: true });
});

// --- invite links ---
app.post("/api/chats/:id/invite", async (c) => {
  const { userId } = c.get("auth");
  const chatId = c.req.param("id");
  // only a member of the chat may mint an invite, and only while the group's
  // rights let them bring anyone in
  const state = await chatStateOrNotMember(c.env, chatId);
  const me = state.members.find((m) => m.userId === userId);
  if (!me) return err("not_member", 403);
  if (state.kind === "group" && state.invitePolicy === "admins" && me.role !== "admin")
    return err("not_allowed", 403);
  // a channel's link is what its audience arrives by, and it is the editors' to hand out
  if (state.kind === "channel" && me.role !== "owner" && me.role !== "editor")
    return err("not_allowed", 403);
  const code = b64url(crypto.getRandomValues(new Uint8Array(9)));
  await lookupPut(c.env, "inv", code, { chatId, createdBy: userId, createdAt: Date.now() });
  return json({ ok: true, code, link: `msngr://join/${code}` });
});

app.post("/api/join/:code", async (c) => {
  const { userId } = c.get("auth");
  const inv = await lookupGet<{ chatId: string }>(c.env, "inv", c.req.param("code"));
  if (!inv) return err("invalid_invite", 404);
  await convStub(c.env, inv.chatId).members({
    actor: userId, add: [userId], remove: [], viaInvite: true,
  });
  return json({ ok: true, chatId: inv.chatId });
});

// --- media (E2E: the server keeps ciphertext blobs and nothing else) ---
app.post("/api/media", async (c) => {
  const mediaId = ulid();
  const body = c.req.raw.body;
  if (!body) return err("empty_body");
  await c.env.MEDIA.put(mediaId, body, {
    httpMetadata: { contentType: "application/octet-stream" },
  });
  const head = await c.env.MEDIA.head(mediaId);
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
    const state = await chatStateOrNotMember(c.env, chatId);
    const me = state.members.find((m) => m.userId === userId);
    if (!me) return err("not_member", 403);
    if (state.kind === "group" && me.role !== "admin") return err("not_admin", 403);
  }
  // a user avatar carries its owner in its id; a chat avatar has no owner
  const mediaId = chatId ? "avatar-" + ulid() : userAvatarId(userId);
  const body = c.req.raw.body;
  if (!body) return err("empty_body");
  await c.env.MEDIA.put(mediaId, body, {
    httpMetadata: { contentType: c.req.header("content-type") ?? "image/jpeg" },
  });
  if (chatId) {
    await convStub(c.env, chatId).settings({ actor: userId, avatarId: mediaId });
  } else {
    await userStub(c.env, userId).profileWrite({ avatarId: mediaId });
    await indexUser(c.env, userId);
    await broadcastProfile(c.env, userId);
  }
  return json({ ok: true, avatarId: mediaId });
});

app.get("/api/avatar/:id", async (c) => {
  // A user avatar whose owner hid it is withheld at the bytes too, not only by
  // blanking avatar_id in the cards: an id learned earlier must stop answering.
  // The id names its owner, so the rule is asked of the right object without an
  // index from a blob back to an account. A chat avatar names none and stays
  // open to any authenticated caller.
  const mediaId = c.req.param("id");
  const owner = avatarOwner(mediaId);
  if (owner && !(await privacyAllows(c.env, owner, c.get("auth").userId, "avatar"))) {
    return err("not_found", 404);
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
  await userStub(c.env, userId).pushToken(deviceId, b.apnsToken, b.env, userId);
  return json({ ok: true });
});

/// Drops the matches their owners hide: `phone_discovery` "nobody" always,
/// "contacts" unless the found user lists the searcher in their own book —
/// you are findable by the people whose number you hold.
async function discoverableBy(
  env: Env, searcherId: string, ids: string[]
): Promise<Set<string>> {
  const allowed = new Set(ids);
  await Promise.all(ids.map(async (id) => {
    if (id === searcherId) return;
    if (!(await privacyAllows(env, id, searcherId, "phone_discovery"))) allowed.delete(id);
  }));
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
  await userStub(c.env, userId).contactsSync(hashes, b.remove);
  const found = await phoneIndexFind(c.env, hashes);
  const ids = [...new Set(found.values())];
  const discoverable = await discoverableBy(c.env, userId, ids);
  const visible = ids.filter((id) => id === userId || discoverable.has(id));
  const cards = await cardsFor(c.env, userId, visible);
  // the hash comes back with the match: it is what the caller's address book
  // is keyed by, and the name in the book is the one the list shows
  const hashOf = new Map([...found].map(([hash, id]) => [id, hash]));
  const matches = visible.flatMap((id) => {
    const card = cards.get(id);
    return card ? [{ ...card, phone_hash: hashOf.get(id)! }] : [];
  });
  return json({ ok: true, matches });
});

app.post("/api/phone", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ phoneHash: string | null }>();
  const { was } = await userStub(c.env, userId).phone(b.phoneHash);
  // the reverse index follows: the number that was there stops answering for
  // this account, and the new one starts
  if (was && was !== b.phoneHash) await phoneIndexPut(c.env, was, null);
  if (b.phoneHash) await phoneIndexPut(c.env, b.phoneHash, userId);
  return json({ ok: true });
});

app.post("/api/block", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ userId: string; blocked: boolean }>();
  // the block is written in this user's object and mirrored into the peer's,
  // and the presences stop flowing between the two, or start again
  await userStub(c.env, userId).block(b.userId, b.blocked);
  return json({ ok: true });
});

app.get("/api/blocked", async (c) => {
  const { userId } = c.get("auth");
  const { blocked } = await userStub(c.env, userId).blocks();
  return json({ ok: true, blocked });
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
  await userStub(c.env, userId).report({
    reporterId: userId, chatId: b.chatId ?? null,
    targetUserId: b.targetUserId ?? null, reason: b.reason,
    comment: b.comment ? String(b.comment).slice(0, 2048) : null,
    attached, createdAt: Date.now(),
  });
  return json({ ok: true });
});

const LAST_SEEN_VALUES: LastSeenVisibility[] = ["everyone", "contacts", "nobody"];

app.get("/api/privacy", async (c) => {
  const { userId } = c.get("auth");
  return json({ ok: true, privacy: await readPrivacy(c.env, userId) });
});

const EXCEPTION_SETTINGS = ["last_seen", "avatar", "phone_discovery", "group_invites", "call"];

// Named-people overrides of the tiers: who is always shown the setting and
// who never is, whatever the tier says.
app.get("/api/privacy/exceptions", async (c) => {
  const { userId } = c.get("auth");
  const { exceptions } = await userStub(c.env, userId).privacyExceptions();
  // the list is shown by name, and a name is its owner's to hand out
  const cards = await cardsFor(c.env, userId, [...new Set(exceptions.map((e) => e.peerId))]);
  return json({ ok: true, exceptions: exceptions.flatMap((e) => {
    const card = cards.get(e.peerId);
    return card ? [{ ...e, username: card.username, displayName: card.display_name }] : [];
  }) });
});

app.post("/api/privacy/exceptions", async (c) => {
  const { userId } = c.get("auth");
  const b = await c.req.json<{ setting?: string; peerId?: string; allow?: boolean | null }>();
  if (!b.setting || !EXCEPTION_SETTINGS.includes(b.setting) || !b.peerId || b.peerId === userId) {
    return err("bad_exception");
  }
  if (!(await ownProfile(c.env, b.peerId))) return err("not_found", 404);
  await userStub(c.env, userId).privacyException(b.setting, b.peerId, b.allow ?? null);
  // an avatar override changes what this peer already holds from the last
  // profile frame; the broadcast is one card for all, so it only helps when
  // the change makes the card MORE hidden — an allowed peer refetches
  if (b.setting === "avatar") await broadcastProfile(c.env, userId);
  // a last-seen override changes what this peer may hold: the user's object
  // pushes the presence or takes the copy back
  if (b.setting === "last_seen") {
    await userStub(c.env, userId).presencePolicyChanged();
  }
  return json({ ok: true });
});

// The setting itself is what's enforced, not just hidden client-side: a hidden
// last seen never leaves the user's own object (its presence pushes go only to
// the subscribers the tier allows, and a tightened tier takes the copies back),
// and receipts/typing turned off never leave ConversationDO's /recv, /read and
// /typing handlers.
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
  const wanted: Partial<PrivacySettings> = {};
  if (b.lastSeen !== undefined) wanted.lastSeen = b.lastSeen as LastSeenVisibility;
  if (b.avatar !== undefined) wanted.avatar = b.avatar as LastSeenVisibility;
  if (b.phoneDiscovery !== undefined) wanted.phoneDiscovery = b.phoneDiscovery as LastSeenVisibility;
  if (b.groupInvites !== undefined) wanted.groupInvites = b.groupInvites as LastSeenVisibility;
  if (b.callPrivacy !== undefined) wanted.callPrivacy = b.callPrivacy as LastSeenVisibility;
  if (b.readReceipts !== undefined) wanted.readReceipts = b.readReceipts;
  if (b.typing !== undefined) wanted.typing = b.typing;
  const res = await userStub(c.env, userId).privacyWrite(wanted);
  // peers hold the card from the last profile frame, so a photo hidden or shown
  // again travels to them at once instead of waiting for a refetch
  if (res.avatarChanged) await broadcastProfile(c.env, userId);
  if (res.lastSeenChanged) {
    await userStub(c.env, userId).presencePolicyChanged();
  }
  return json({ ok: true, privacy: res.privacy });
});

// --- stories ---
//
// A story is not end-to-end encrypted. Who may see one is an access rule, not a
// key: that is what lets it live for a day for a chosen audience, and what
// makes a public link possible at all. The composer says so before the story
// goes out. The stories themselves, the watches and the hearts live in the
// author's StoriesDO; the Worker decides who may ask it and joins the names.

/// A story as the author's object hands it out.
/// `contacts`: the people the author shares a direct chat with at the moment
/// of publishing. There is no wider audience — a story is delivered to a
/// named set of people, never offered to whoever comes along.
const STORY_AUDIENCES = ["contacts"];
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
  const { chats } = await userStub(env, userId).chats();
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
  // who gets it is decided once, here: the author and everyone they share a
  // direct chat with, minus anyone with a block between them. The author's
  // object delivers to each of them from its queue
  const peers = await directPeers(c.env, userId);
  const bj = await userStub(c.env, userId).blocks();
  const hidden = new Set([...bj.blocked, ...bj.blockedBy]);
  const recipients = [userId, ...peers.filter((p) => !hidden.has(p))];
  const author = await cardFor(c.env, userId, userId);
  const j = await storiesStub(c.env, userId).publish({
    authorId: userId, frames, audience, hours, link: b.link === true,
    recipients, author, origin: publicOrigin(c),
  });
  return json({ ok: true, storyId: j.id, link: j.code ? `${publicOrigin(c)}/s/${j.code}` : null });
});

/// Whether this user may act on the story: it was delivered into their own
/// inbox — that is the whole of the right — and no block has come between
/// them and the author since. The author's own stories are always theirs.
async function canWatchStory(env: Env, userId: string, authorId: string, storyId: string): Promise<boolean> {
  if (authorId === userId) return true;
  if (await blockedPair(env, userId, authorId)) return false;
  return (await userStub(env, userId).storyHas(storyId)).has;
}

/// The story a request names, from its author's object, with the access rule
/// applied: null when there is nothing this user may act on.
async function watchableStory(env: Env, userId: string, authorId: string, storyId: string) {
  let j: { audience: string };
  try {
    j = await storiesStub(env, authorId).story(storyId);
  } catch {
    return null;
  }
  return (await canWatchStory(env, userId, authorId, storyId)) ? j : null;
}

/// Everything this user may watch right now, newest author first, with their
/// own stories among them.
app.get("/api/stories", async (c) => {
  const { userId } = c.get("auth");
  // the list is this user's own inbox: every story delivered to them, kept
  // by their own object as the authors' objects pushed it. Nobody else is
  // asked; a block that came after the delivery hides the row here
  const [inbox, bj] = await Promise.all([
    userStub(c.env, userId).storiesInbox() as Promise<{ stories: StoryItem[] }>,
    userStub(c.env, userId).blocks(),
  ]);
  const hidden = new Set([...bj.blocked, ...bj.blockedBy]);
  const stories = inbox.stories.filter((s) => s.authorId === userId || !hidden.has(s.authorId));
  return json({ ok: true, stories });
});

app.post("/api/stories/:id/seen", async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");
  const authorId = authorOf(id);
  if (!authorId) return err("not_found", 404);
  // the author looking at their own story is not a viewer
  if (authorId === userId) return json({ ok: true });
  if (!(await watchableStory(c.env, userId, authorId, id))) return err("not_found", 404);
  await storiesStub(c.env, authorId).seen(id, userId);
  // the viewer's own copy remembers it, and their other devices hear it
  await userStub(c.env, userId).storyMark(id, true);
  return json({ ok: true });
});

/// A heart on a story, put on or taken off. Liking is watching, so the like
/// also counts as a view; the author cannot like their own.
app.post("/api/stories/:id/like", async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");
  const b = await c.req.json<{ on?: boolean }>();
  const authorId = authorOf(id);
  if (!authorId) return err("not_found", 404);
  if (authorId === userId) return err("own_story");
  if (!(await watchableStory(c.env, userId, authorId, id))) return err("not_found", 404);
  const liked = (await storiesStub(c.env, authorId).like(id, userId, b.on !== false)).liked;
  await userStub(c.env, userId).storyMark(id, true, liked);
  return json({ ok: true, liked });
});

/// Who watched, and who of them left a heart. The creator's alone: nobody
/// else is told, and the public page is not counted at all.
app.get("/api/stories/:id/viewers", async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");
  const authorId = authorOf(id);
  if (!authorId) return err("not_found", 404);
  if (authorId !== userId) return err("not_author", 403);
  const j = await storiesStub(c.env, userId).viewers(id);
  const cards = await cardsFor(c.env, userId, [...new Set(j.viewers.map((v) => v.viewer_id))]);
  const viewers = j.viewers.flatMap((v) => {
    const card = cards.get(v.viewer_id);
    return card ? [{ ...v, username: card.username, display_name: card.display_name, avatar_id: card.avatar_id }] : [];
  });
  return json({ ok: true, viewers });
});

/// Taking it down, and minting or revoking its public link.
app.post("/api/stories/:id", async (c) => {
  const { userId } = c.get("auth");
  const id = c.req.param("id");
  const b = await c.req.json<{ takeDown?: boolean; link?: boolean }>();
  const authorId = authorOf(id);
  if (!authorId) return err("not_found", 404);
  if (authorId !== userId) return err("not_author", 403);
  const j = await storiesStub(c.env, userId).update({
    authorId: userId, storyId: id, takeDown: b.takeDown, link: b.link,
  });
  if (b.takeDown) return json({ ok: true });
  const link = j.code ? `${publicOrigin(c)}/s/${j.code}` : null;
  // the author's own copy carries the link they see in the list
  await userStub(c.env, userId).storyMark(id, undefined, undefined, link);
  return json({ ok: true, link });
});

export default {
  async fetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (!env.PERF_LOG) return handle(req, env, ctx);
    const t0 = Date.now();
    const res = await handle(req, env, ctx);
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
      status: res.status, down: size, ms: Date.now() - t0,
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
      return stub.fetch(fwd);
    }

    return app.fetch(req, env, ctx);
  }
}
