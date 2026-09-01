// Integration smoke: users, direct chat, WS exchange, receipts, sync, groups,
// blocks, logout, pushes.
// The push checks need wrangler dev to point APNS_HOST at the smoke's own
// receiver: http://localhost:9871 by default (.dev.vars), otherwise PUSH_PORT=<port>.
import http from "node:http";
import { createHash } from "node:crypto";
import WebSocket from "ws";
import { shouldArmAlarm } from "../src/util.ts";

const BASE = process.env.BASE_URL ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
// Port of the push receiver: has to match APNS_HOST of the wrangler dev under test.
const PUSH_PORT = Number(process.env.PUSH_PORT ?? 9871);
let failures = 0;

function check(name, cond, extra = "") {
  if (cond) console.log(`ok   ${name}`);
  else { failures++; console.log(`FAIL ${name} ${extra}`); }
}

async function apiRaw(path, { token, body, method } = {}) {
  return fetch(BASE + path, {
    method: method ?? (body !== undefined ? "POST" : "GET"),
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
}

async function api(path, opts) {
  return (await apiRaw(path, opts)).json();
}

function fakeKeys(n) {
  return {
    identityKey: "ik_" + n,
    identitySignKey: "isk_" + n,
    identityKeySig: "iksig_" + n,
    signedPrekey: { id: 1, key: "spk_" + n, sig: "sig_" + n },
    oneTimePrekeys: [{ id: 1, key: "otp1_" + n }, { id: 2, key: "otp2_" + n }],
  };
}

/// Protocol version the client states in the upgrade: the smoke goes through
/// the same door as the app.
const PROTOCOL = 1;

class Client {
  constructor(name, token, protocol = PROTOCOL) {
    this.name = name;
    this.token = token;
    this.protocol = protocol;
    this.frames = [];
  }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`${WS_BASE}/ws?token=${this.token}&v=${this.protocol}`);
      // at: when the frame arrived, used to compare the order of an ack and a push
      this.ws.on("message", (d) =>
        this.frames.push({ ...JSON.parse(d.toString()), at: Date.now() }));
      this.ws.on("open", resolve);
      this.ws.on("error", reject);
    });
  }
  send(frame) { this.ws.send(JSON.stringify(frame)); }
  async waitFor(pred, ms = 4000) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      const f = this.frames.find(pred);
      if (f) return f;
      await new Promise((r) => setTimeout(r, 50));
    }
    return null;
  }
  /// Position in the frame log: waitAfter searches from it, and a round's slice
  /// is cut at it.
  mark() { return this.frames.length; }
  async waitAfter(mark, pred, ms = 4000) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      const f = this.frames.slice(mark).find(pred);
      if (f) return f;
      await new Promise((r) => setTimeout(r, 50));
    }
    return null;
  }
}

/// Catch-up in portions, the way the client drives it: sync → msg frames,
/// syncState per chat, syncDone; then catchup for the chats still behind until
/// more goes false. Returns the rounds with each one's syncState slice.
async function catchUp(client, cursors, { rounds = 200, ms = 30000 } = {}) {
  let asked = { ...cursors };
  let t = "sync";
  const portions = [];
  for (let i = 0; i < rounds; i++) {
    const mark = client.mark();
    client.send({ t, cursors: asked });
    const done = await client.waitAfter(mark, (f) => f.t === "syncDone", ms);
    if (!done) return { done: false, portions };
    portions.push({
      states: client.frames.slice(mark).filter((f) => f.t === "syncState"),
      more: done.more,
      asked,
    });
    if (!done.more) return { done: true, portions };
    const next = {};
    for (const [chatId, from] of Object.entries(asked)) {
      const st = portions[portions.length - 1].states.find((s) => s.chatId === chatId);
      if (!st) next[chatId] = from;        // the portion never reached this chat
      else if (st.more) next[chatId] = st.cursor;
    }
    if (!Object.keys(next).length) return { done: true, portions };
    asked = next;
    t = "catchup";
  }
  return { done: false, portions };
}

const suffix = Math.random().toString(36).slice(2, 8);

// 1. Registration
const alice = await api("/api/register", { body: {
  username: "alice_" + suffix, displayName: "Alice", ...fakeKeys("a") } });
const bob = await api("/api/register", { body: {
  username: "bob_" + suffix, displayName: "Bob", ...fakeKeys("b") } });
const carol = await api("/api/register", { body: {
  username: "carol_" + suffix, displayName: "Carol", ...fakeKeys("c") } });
check("register", alice.ok && bob.ok && carol.ok, JSON.stringify(alice));

const dupe = await api("/api/register", { body: {
  username: "alice_" + suffix, displayName: "X", ...fakeKeys("x") } });
check("username uniqueness", !dupe.ok && dupe.error === "username_taken");

// 2. Search and prekeys
const found = await api(`/api/users?q=bob_${suffix}`, { token: alice.token });
check("user search", found.ok && found.users.length === 1);

// Case folding beyond ASCII: a Cyrillic display name is found by a query in
// the other case.
const cyrUser = await api("/api/register", { body: {
  username: "cyr_" + suffix, displayName: `Икфмц ${suffix}`, ...fakeKeys("cy") } });
const foundCyr = await api(
  `/api/users?q=${encodeURIComponent(`икфмц ${suffix}`)}`, { token: alice.token });
check("user search folds Cyrillic case",
  cyrUser.ok && foundCyr.ok && foundCyr.users.length === 1
  && foundCyr.users[0].id === cyrUser.userId, JSON.stringify(foundCyr));

const bundle = await api(`/api/users/${bob.userId}/prekeys`, { token: alice.token });
check("prekey bundle", bundle.ok && bundle.bundles[0].oneTimePrekey?.key === "otp1_b");
const bundle2 = await api(`/api/users/${bob.userId}/prekeys`, { token: alice.token });
check("one-time prekey consumed", bundle2.bundles[0].oneTimePrekey?.key === "otp2_b");

// A device that keeps failing to open prekey envelopes republishes its bundle
// whole: the signed prekey is replaced and the stale one-times are dropped.
const repub = await api("/api/prekeys/republish", { token: bob.token, body: {
  signedPrekey: { id: 2, key: "spk2_b", sig: "sig2_b" },
  oneTimePrekeys: [{ id: 10, key: "otp10_b" }],
} });
check("prekey republish accepted", repub.ok === true, JSON.stringify(repub));
const bundle3 = await api(`/api/users/${bob.userId}/prekeys`, { token: alice.token });
check("republished bundle carries the new signed prekey",
  bundle3.bundles[0].signedPrekey?.key === "spk2_b", JSON.stringify(bundle3.bundles));
check("republished bundle hands out the new one-time",
  bundle3.bundles[0].oneTimePrekey?.key === "otp10_b");
const bundle4 = await api(`/api/users/${bob.userId}/prekeys`, { token: alice.token });
check("stale one-times are gone after the republish",
  bundle4.bundles[0].oneTimePrekey === null, JSON.stringify(bundle4.bundles));
// top the count back up so later checks see a live bundle
await api("/api/prekeys", { token: bob.token, body: {
  oneTimePrekeys: [{ id: 11, key: "otp11_b" }, { id: 12, key: "otp12_b" }] } });

// 3. Direct chat (+ dedupe)
const chat = await api("/api/chats", { token: alice.token,
  body: { kind: "direct", memberIds: [bob.userId] } });
check("create direct", chat.ok, JSON.stringify(chat));
const chatDupe = await api("/api/chats", { token: bob.token,
  body: { kind: "direct", memberIds: [alice.userId] } });
check("direct dedupe", chatDupe.chatId === chat.chatId);

// 4. WS: Alice online, Bob online
const ca = new Client("alice", alice.token);
const cb = new Client("bob", bob.token);
await ca.connect(); await cb.connect();
const hello = await ca.waitFor((f) => f.t === "hello");
check("ws hello", !!hello);

// 4a. Handshake: protocol version
const ver = await api("/api/version");
check("version endpoint", ver.ok && ver.protocol >= ver.minProtocol, JSON.stringify(ver));
check("hello states both versions",
  hello.protocol === ver.protocol && hello.minProtocol === ver.minProtocol,
  JSON.stringify(hello));
check("smoke speaks a supported version", PROTOCOL >= ver.minProtocol);

/// An upgrade the server did not accept: ws hands back an HTTP response
/// instead of a socket.
function upgrade(token, query) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${WS_BASE}/ws?token=${token}${query}`);
    let answered = false;
    ws.on("open", () => { answered = true; ws.close(); resolve({ status: 101 }); });
    ws.on("unexpected-response", (_req, res) => {
      answered = true;
      let body = "";
      res.on("data", (d) => (body += d));
      res.on("end", () => {
        let parsed = null;
        try { parsed = JSON.parse(body); } catch { /* not json: hand the body back as it came */ }
        resolve({ status: res.statusCode, body: parsed ?? body });
      });
    });
    ws.on("error", (e) => { if (!answered) resolve({ status: 0, error: String(e) }); });
  });
}

const tooOld = await upgrade(alice.token, `&v=${ver.minProtocol - 1}`);
check("upgrade of an old client is refused",
  tooOld.status === 426 && tooOld.body?.error === "client_too_old", JSON.stringify(tooOld));
check("refusal names the supported range",
  tooOld.body?.minProtocol === ver.minProtocol && tooOld.body?.protocol === ver.protocol,
  JSON.stringify(tooOld.body));
const noVersion = await upgrade(alice.token, "");
check("upgrade without a version is refused",
  noVersion.status === 426 && noVersion.body?.error === "client_too_old",
  JSON.stringify(noVersion));
const supported = await upgrade(alice.token, `&v=${ver.protocol}`);
check("upgrade of a current client is accepted", supported.status === 101, JSON.stringify(supported));

// 5. Sending a message
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: { [`${bob.userId}/${bob.deviceId}`]: { type: "dr", c: "ZmFrZQ" } } } });
const sent = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-1");
check("sent ack", !!sent && sent.seq === 1, JSON.stringify(sent));
const gotMsg = await cb.waitFor((f) => f.t === "msg" && f.chatId === chat.chatId);
check("bob receives msg", !!gotMsg && gotMsg.from === alice.userId);
const aliceEcho = await ca.waitFor((f) =>
  f.t === "msg" && f.chatId === sent.chatId && f.seq === sent.seq);
check("alice gets own echo", !!aliceEcho);

// idempotency
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-1", sentAt: Date.now(), body: {} });
const sent2 = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-1" && f !== sent);
check("idempotent resend same seq", !!sent2 && sent2.seq === 1 && sent2.seq === sent.seq);

// 6. Message request: Bob has not accepted the chat yet → no read receipt goes out
const st0 = await api(`/api/chats/${chat.chatId}/history?fromSeq=0`, { token: bob.token });
void st0;
const stateRes = await fetch(BASE + "/api/chats", { headers: { authorization: `Bearer ${bob.token}` } }).then(r => r.json());
const dchat = stateRes.chats.find((c2) => c2.state.chatId === chat.chatId);
check("direct starts as request", dchat.state.members.find((m) => m.userId === bob.userId).accepted === false
  && dchat.state.members.find((m) => m.userId === alice.userId).accepted === true);

cb.send({ t: "read", chatId: chat.chatId, upToSeq: 1 });
cb.send({ t: "typing", chatId: chat.chatId, kind: "text" });
await new Promise((r) => setTimeout(r, 600));
check("no read receipt before accept", !ca.frames.some((f) => f.t === "receipt" && f.kind === "read"));
check("no typing before accept", !ca.frames.some((f) => f.t === "typing" && f.from === bob.userId));

// the recipient's presence is not visible to the requester, not even via the profile
const profBefore = await api(`/api/users/${bob.userId}`, { token: alice.token });
check("no presence before accept", profBefore.ok && profBefore.presence === null,
  JSON.stringify(profBefore.presence));

const acc = await api(`/api/chats/${chat.chatId}/accept`, { token: bob.token, body: {} });
check("accept request", acc.ok);

const profAfter = await api(`/api/users/${bob.userId}`, { token: alice.token });
check("presence after accept", profAfter.ok && !!profAfter.presence,
  JSON.stringify(profAfter.presence));

// Receipts after accept
cb.send({ t: "recv", chatId: chat.chatId, seqs: [1] });
const delivered = await ca.waitFor((f) => f.t === "receipt" && f.kind === "delivered");
check("delivered receipt", !!delivered && delivered.by === bob.userId);
cb.send({ t: "read", chatId: chat.chatId, upToSeq: 1 });
const read = await ca.waitFor((f) => f.t === "receipt" && f.kind === "read");
check("read receipt after accept", !!read && read.upToSeq === 1);

// 7. Typing
cb.send({ t: "typing", chatId: chat.chatId, kind: "text" });
const typing = await ca.waitFor((f) => f.t === "typing" && f.from === bob.userId);
check("typing", !!typing);

// 7b. The ephemeral call relay: the envelope reaches the peer's live socket
// with its addressing, and leaves nothing in the journal
cb.send({ t: "callRelay", chatId: chat.chatId, sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const relayed = await ca.waitFor((f) => f.t === "callRelay" && f.chatId === chat.chatId);
check("call relay reaches the peer", !!relayed
  && relayed.from === bob.userId && !!relayed.fromDevice && !!relayed.body);
{
  const before = (await api(`/api/chats/${chat.chatId}/history?fromSeq=0`,
    { token: alice.token })).msgs.length;
  const relayMark = ca.mark();
  cb.send({ t: "callRelay", chatId: chat.chatId, sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  await ca.waitAfter(relayMark, (f) => f.t === "callRelay" && f.chatId === chat.chatId);
  const after = (await api(`/api/chats/${chat.chatId}/history?fromSeq=0`,
    { token: alice.token })).msgs.length;
  check("call relay is not journaled", before === after, `${before} -> ${after}`);
}

// 7a. A changed card reaches the people who see it, over the socket
const renameMark = ca.mark();
const renamed = await api("/api/profile", { token: bob.token, body: { displayName: "Bob Renamed" } });
check("profile update", renamed.ok);
const nameFrame = await ca.waitAfter(renameMark, (f) => f.t === "profile" && f.user?.id === bob.userId);
check("rename reaches the peer", !!nameFrame && nameFrame.user.display_name === "Bob Renamed",
  JSON.stringify(nameFrame));

// A renamed display name keeps the Unicode fold: the new Cyrillic name is
// found case-insensitively and the old one is not found at all.
const cyrRename = await api("/api/profile", { token: bob.token,
  body: { displayName: `Цфмки ${suffix}` } });
const foundRenamed = await api(
  `/api/users?q=${encodeURIComponent(`цфмки ${suffix}`)}`, { token: alice.token });
check("renamed Cyrillic name found case-insensitively",
  cyrRename.ok && foundRenamed.ok && foundRenamed.users.length === 1
  && foundRenamed.users[0].id === bob.userId, JSON.stringify(foundRenamed));

check("empty name refused on profile",
  (await api("/api/profile", { token: bob.token, body: { displayName: "  " } })).error === "bad_name");
check("empty name refused at registration",
  (await api("/api/register", { body: {
    username: "noname_" + suffix, displayName: "", ...fakeKeys("n") } })).error === "bad_name");

// the avatar blob sits behind the device token, and the frame carries its id
const avatarMark = ca.mark();
const upload = await (await fetch(BASE + "/api/avatar", {
  method: "POST",
  headers: { authorization: `Bearer ${bob.token}`, "content-type": "image/jpeg" },
  body: Buffer.from("not-a-real-jpeg-but-bytes"),
})).json();
check("avatar upload", upload.ok && upload.avatarId.startsWith("avatar-"), JSON.stringify(upload));
const avatarFrame = await ca.waitAfter(avatarMark, (f) => f.t === "profile" && f.user?.id === bob.userId);
check("avatar reaches the peer", !!avatarFrame && avatarFrame.user.avatar_id === upload.avatarId,
  JSON.stringify(avatarFrame));
check("avatar blob needs a token",
  (await fetch(BASE + "/api/avatar/" + upload.avatarId)).status === 401);
const avatarBytes = await fetch(BASE + "/api/avatar/" + upload.avatarId,
  { headers: { authorization: `Bearer ${alice.token}` } });
check("peer reads the avatar blob with theirs", avatarBytes.status === 200);

// 7b. Renaming the handle: the new one is taken and the old one freed by the
// same statement, under the index that already guards registration
const oldHandle = "bob_" + suffix;
const newHandle = "bobby_" + suffix;
check("username taken by someone else is refused",
  (await api("/api/username", { token: bob.token, body: { username: "alice_" + suffix } }))
    .error === "username_taken");
check("bad username refused",
  (await api("/api/username", { token: bob.token, body: { username: "no" } })).error === "bad_username");
check("username changed", (await api("/api/username", { token: bob.token, body: { username: newHandle } })).ok);
check("found under the new handle",
  (await api(`/api/users?q=${newHandle}`, { token: alice.token })).users.length === 1);
check("gone from the old handle",
  (await api(`/api/users?q=${oldHandle}`, { token: alice.token })).users.length === 0);
const reuse = await api("/api/register", { body: {
  username: oldHandle, displayName: "Someone Else", ...fakeKeys("r") } });
check("a freshly freed handle is quarantined, not free",
  !reuse.ok && reuse.error === "username_taken", JSON.stringify(reuse));
check("a stranger can't rename into a quarantined handle either",
  (await api("/api/username", { token: carol.token, body: { username: oldHandle } }))
    .error === "username_taken");
check("the owner can take their own freed handle straight back",
  (await api("/api/username", { token: bob.token, body: { username: oldHandle } })).ok);
check("the freed handle is bob's again",
  (await api(`/api/users?q=${oldHandle}`, { token: alice.token })).users.length === 1);
check("newHandle, freed in turn, is quarantined for a stranger's register",
  (await api("/api/register", { body: {
    username: newHandle, displayName: "Someone Else Too", ...fakeKeys("s") } }))
    .error === "username_taken");

// 8. Offline → sync: Bob disconnects, Alice sends, Bob comes back with a cursor
cb.ws.close();
await new Promise((r) => setTimeout(r, 300));
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-2");
const cb2 = new Client("bob2", bob.token);
await cb2.connect();
cb2.send({ t: "sync", cursors: { [chat.chatId]: 1 } });
const missed = await cb2.waitFor((f) => f.t === "msg" && f.seq === 2);
check("sync backfill", !!missed);

// 8a. Catching up on a foreign chat: the id of a direct chat is derived from the two
// user ids, so anyone can name a cursor for it. The journal is not served for it.
const outsider = new Client("carol-outsider", carol.token);
await outsider.connect();
const outsiderMark = outsider.mark();
outsider.send({ t: "sync", cursors: { [chat.chatId]: 0 } });
await outsider.waitAfter(outsiderMark, (f) => f.t === "syncDone");
const leaked = outsider.frames.slice(outsiderMark)
  .filter((f) => (f.t === "msg" || f.t === "deleted" || f.t === "receipt")
    && f.chatId === chat.chatId);
check("catch-up of a foreign chat leaks nothing", leaked.length === 0,
  JSON.stringify(leaked.slice(0, 2)));
const outsiderHist = await api(`/api/chats/${chat.chatId}/history?fromSeq=0`,
  { token: carol.token });
check("history of a foreign chat is refused",
  !outsiderHist.ok && outsiderHist.error === "not_member", JSON.stringify(outsiderHist));
outsider.ws.close();

// 9. Group
const grp = await api("/api/chats", { token: alice.token,
  body: { kind: "group", memberIds: [bob.userId], title: "Team" } });
check("create group", grp.ok);
const grpAdd = await api(`/api/chats/${grp.chatId}/members`, { token: alice.token,
  body: { add: [carol.userId], remove: [] } });
check("admin adds member", grpAdd.ok, JSON.stringify(grpAdd));
const carolAdd = await api(`/api/chats/${grp.chatId}/members`, { token: carol.token,
  body: { add: [], remove: [bob.userId] } });
check("non-admin cannot remove", !carolAdd.ok);

const chatEvt = await cb2.waitFor((f) => f.t === "chat" && f.chatId === grp.chatId);
check("bob got group chat event", !!chatEvt && chatEvt.state.members.length >= 2);
// the frame names its roster, so a client shows named rows without a fetch;
// bio and avatar stay out — they are per-viewer private and this frame fans out
const aliceCard = (chatEvt.users ?? []).find((u) => u.id === alice.userId);
check("chat frame carries roster names",
  !!aliceCard && aliceCard.username === "alice_" + suffix
  && !!aliceCard.display_name && aliceCard.bio === null && aliceCard.avatar_id === null,
  JSON.stringify(chatEvt.users));

// group message w/ sender-key envelope
ca.send({ t: "send", chatId: grp.chatId, clientMsgId: "cm-g1", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
const gmsg = await cb2.waitFor((f) => f.t === "msg" && f.chatId === grp.chatId);
check("group message delivered", !!gmsg);

// 10. Chats snapshot
const snap = await api("/api/chats", { token: bob.token });
check("chats snapshot", snap.ok && snap.chats.length === 2 && snap.users.length >= 3);

// 10a. A roster change missed while offline. The live chat frame about a member
// leaving reaches only those connected; the rest learn about it on catch-up, or
// whoever stayed would keep encrypting into a chain the departed member holds.
const mgrp = await api("/api/chats", { token: alice.token,
  body: { kind: "group", memberIds: [bob.userId, carol.userId], title: "Roster" } });
check("create roster group", mgrp.ok, JSON.stringify(mgrp));
ca.send({ t: "send", chatId: mgrp.chatId, clientMsgId: "cm-r1", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-r1");

const rm = await api(`/api/chats/${mgrp.chatId}/members`, { token: alice.token,
  body: { add: [], remove: [carol.userId] } });
check("admin removes member", rm.ok, JSON.stringify(rm));

// the remaining member catches up: the roster arrives with the tail of the chat
const cbR = new Client("bob-roster", bob.token);
await cbR.connect();
const bobRosterMark = cbR.mark();
cbR.send({ t: "sync", cursors: { [mgrp.chatId]: 1 } });
await cbR.waitAfter(bobRosterMark, (f) => f.t === "syncDone");
const rosterFrame = cbR.frames.slice(bobRosterMark)
  .find((f) => f.t === "chat" && f.chatId === mgrp.chatId);
check("catch-up replays the roster", !!rosterFrame?.state, JSON.stringify(rosterFrame ?? null));
check("replayed roster has the removed member out",
  !rosterFrame?.state?.members.some((m) => m.userId === carol.userId),
  JSON.stringify(rosterFrame?.state?.members ?? null));
cbR.ws.close();

// the removed member learns about it on catch-up, and gets no roster
const ccR = new Client("carol-roster", carol.token);
await ccR.connect();
const carolRosterMark = ccR.mark();
ccR.send({ t: "sync", cursors: { [mgrp.chatId]: 0 } });
await ccR.waitAfter(carolRosterMark, (f) => f.t === "syncDone");
const removedFrame = ccR.frames.slice(carolRosterMark)
  .find((f) => f.t === "chat" && f.chatId === mgrp.chatId);
check("catch-up tells the removed member", removedFrame?.event === "removed",
  JSON.stringify(removedFrame ?? null));
check("removal carries no roster", removedFrame && removedFrame.state === undefined);
check("removed member gets no history",
  !ccR.frames.slice(carolRosterMark).some((f) => f.t === "msg" && f.chatId === mgrp.chatId));
ccR.ws.close();

// 11. delete for all
ca.send({ t: "delete", chatId: chat.chatId, seqs: [sent.seq], forAll: true });
const del = await cb2.waitFor((f) => f.t === "deleted");
check("delete for all", !!del && del.seqs.includes(sent.seq));
const hist = await api(`/api/chats/${chat.chatId}/history?fromSeq=0`, { token: bob.token });
const tomb = hist.msgs.find((m) => m.seq === sent.seq);
check("tombstoned on server", tomb && tomb.deleted === true && tomb.body === null);

// 11a. Delete for all does not touch someone else's message: no tombstone, no fanout
cb2.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-bob-own", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const bobOwn = await cb2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-bob-own");
ca.send({ t: "delete", chatId: chat.chatId, seqs: [bobOwn.seq], forAll: true });
const foreignDel = await cb2.waitFor((f) => f.t === "deleted" && f.seqs.includes(bobOwn.seq), 1500);
check("no fanout deleting someone else's message", foreignDel === null);
const hist2 = await api(`/api/chats/${chat.chatId}/history?fromSeq=0`, { token: bob.token });
const keptMsg = hist2.msgs.find((m) => m.seq === bobOwn.seq);
check("someone else's message survives delete for all",
  keptMsg && !keptMsg.deleted && keptMsg.body !== null);

// 12. Chat flags (pin/mute/archive)
const fl = await api(`/api/chats/${chat.chatId}/flags`, { token: alice.token,
  body: { pinned: true, muted: true } });
check("chat flags", fl.ok);

// 12a. Pinned messages: several at once, by seq
const pinState = async () => {
  const s = await api("/api/chats", { token: alice.token });
  const row = s.chats.find((x) => x.state.chatId === chat.chatId);
  return row?.state.pinnedSeqs ?? [];
};
await api(`/api/chats/${chat.chatId}/pin-message`, { token: alice.token, body: { seq: 1 } });
await api(`/api/chats/${chat.chatId}/pin-message`, { token: alice.token, body: { seq: 2 } });
check("two messages pinned", JSON.stringify(await pinState()) === "[1,2]");
const pinFrame = await cb2.waitFor((f) => f.t === "chat" && f.event === "pinned", 1500);
check("pin fans the chat state out", !!pinFrame && Array.isArray(pinFrame.state.pinnedSeqs));
await api(`/api/chats/${chat.chatId}/pin-message`, { token: alice.token,
  body: { seq: 1, pinned: false } });
check("one pin removed keeps the other", JSON.stringify(await pinState()) === "[2]");
await api(`/api/chats/${chat.chatId}/pin-message`, { token: alice.token, body: { seq: 1 } });
check("re-pin lands newest-last", JSON.stringify(await pinState()) === "[2,1]");
await api(`/api/chats/${chat.chatId}/pin-message`, { token: alice.token, body: {} });
check("absent seq clears all pins", JSON.stringify(await pinState()) === "[]");

// 13. Blocking
const bl = await api("/api/block", { token: bob.token, body: { userId: carol.userId, blocked: true } });
const tryChat = await api("/api/chats", { token: carol.token,
  body: { kind: "direct", memberIds: [bob.userId] } });
check("blocked direct rejected", bl.ok && !tryChat.ok && tryChat.error === "blocked");

// 13x. Reporting: an attached excerpt is accepted, garbage reasons are not
const rep = await api("/api/report", { token: carol.token, body: {
  chatId: chat.chatId, targetUserId: bob.userId, reason: "spam",
  comment: "unsolicited ads",
  attached: [{ seq: 1, senderId: bob.userId, text: "buy now" }] } });
check("report accepted", rep.ok === true, JSON.stringify(rep));
const repBad = await api("/api/report", { token: carol.token, body: {
  chatId: chat.chatId, reason: "just_bad_vibes" } });
check("report with unknown reason rejected", repBad.ok === false && repBad.error === "bad_reason");
const repEmpty = await api("/api/report", { token: carol.token, body: { reason: "spam" } });
check("report with no target rejected", repEmpty.ok === false && repEmpty.error === "no_target");

// 13a. Blocking inside an existing chat: the send succeeds, the delivery does not happen
const frank = await api("/api/register", { body: {
  username: "frank_" + suffix, displayName: "Frank", ...fakeKeys("f") } });
const grace = await api("/api/register", { body: {
  username: "grace_" + suffix, displayName: "Grace", ...fakeKeys("g") } });
const fgChat = await api("/api/chats", { token: frank.token,
  body: { kind: "direct", memberIds: [grace.userId] } });
await api(`/api/chats/${fgChat.chatId}/accept`, { token: grace.token, body: {} });
const cf = new Client("frank", frank.token);
const cg = new Client("grace", grace.token);
await cf.connect();
await cg.connect();

cg.send({ t: "send", chatId: fgChat.chatId, clientMsgId: "cm-fg1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
check("delivery before block", !!(await cf.waitFor((f) => f.t === "msg" && f.chatId === fgChat.chatId)));

await api("/api/block", { token: frank.token, body: { userId: grace.userId, blocked: true } });
cg.send({ t: "send", chatId: fgChat.chatId, clientMsgId: "cm-fg2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const fg2 = await cg.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-fg2");
check("blocked sender still gets ack", !!fg2);
check("blocked message not delivered",
  !(await cf.waitFor((f) => f.t === "msg" && f.chatId === fgChat.chatId && f.seq === fg2?.seq, 1200)));

// the other direction: the blocker cannot write into this chat and gets told so,
// the server answers with an explicit error instead of a silent "sent"
cf.send({ t: "send", chatId: fgChat.chatId, clientMsgId: "cm-fg3", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const fg3err = await cf.waitFor((f) => f.t === "error", 1500);
check("blocker gets explicit error", fg3err?.error === "blocked", JSON.stringify(fg3err));
check("no ack for the blocked direction",
  !(await cf.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-fg3", 500)));

// the blocker's unread does not grow on messages they never see
const fgState = await api("/api/chats", { token: frank.token });
const fgEntry = fgState.chats.find((e) => e.state.chatId === fgChat.chatId);
check("read mark covers blocked messages",
  !!fgEntry && (fgEntry.state.readMarks[frank.userId] ?? 0) >= fg2.seq,
  JSON.stringify(fgEntry?.state.readMarks));

await api("/api/block", { token: frank.token, body: { userId: grace.userId, blocked: false } });
cg.send({ t: "send", chatId: fgChat.chatId, clientMsgId: "cm-fg4", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const fg4 = await cg.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-fg4");
check("delivery resumes after unblock",
  !!(await cf.waitFor((f) => f.t === "msg" && f.chatId === fgChat.chatId && f.seq === fg4?.seq)));

// 14. Media: upload/download with range
const blob = new Uint8Array(1024 * 64).fill(7);
const up = await fetch(BASE + "/api/media", {
  method: "POST",
  headers: { authorization: `Bearer ${alice.token}` },
  body: blob,
});
const upJson = await up.json();
check("media upload", upJson.ok && upJson.size === blob.length);
const dl = await fetch(`${BASE}/api/media/${upJson.mediaId}`, {
  headers: { authorization: `Bearer ${bob.token}`, range: "bytes=0-1023" },
});
check("media range download", dl.status === 206 && (await dl.arrayBuffer()).byteLength === 1024);

// 15. Contact discovery by phone hashes
const ph = await api("/api/phone", { token: bob.token, body: { phoneHash: "hash_" + suffix } });
const disc = await api("/api/contacts/discover", { token: alice.token,
  body: { hashes: ["hash_" + suffix, "nonexistent"] } });
check("contact discovery", ph.ok && disc.ok && disc.matches.length === 1
  && disc.matches[0].id === bob.userId);

// 15a. Contact-ness reads the current state at the moment of the question:
// a number that registers later needs no propagation into anyone's book
const laterHash = "hash_later_" + suffix;
await api("/api/contacts/discover", { token: alice.token, body: { hashes: [laterHash] } });
const noraA = await api("/api/register", { body: {
  username: "nora_" + suffix, displayName: "Nora", phoneHash: laterHash, ...fakeKeys("n") } });
check("register with a phone hash", noraA.ok);
// nora hides discovery behind her contacts; alice holds nora's number but
// nora does not hold alice's, so alice no longer finds her
await api("/api/privacy", { token: noraA.token, body: { phoneDiscovery: "contacts" } });
const noraHidden = await api("/api/contacts/discover", { token: alice.token,
  body: { hashes: [laterHash] } });
check("contacts-tier discovery hides from a stranger",
  noraHidden.ok && noraHidden.matches.length === 0, JSON.stringify(noraHidden.matches));
// nora lists alice's number: alice becomes nora's contact the moment the
// check asks, because the check reads alice's current hash
const aliceHash = "hash_alice_" + suffix;
await api("/api/phone", { token: alice.token, body: { phoneHash: aliceHash } });
await api("/api/contacts/discover", { token: noraA.token, body: { hashes: [aliceHash] } });
const noraVisible = await api("/api/contacts/discover", { token: alice.token,
  body: { hashes: [laterHash] } });
check("contacts-tier discovery opens to a contact",
  noraVisible.ok && noraVisible.matches.length === 1 && noraVisible.matches[0].id === noraA.userId,
  JSON.stringify(noraVisible.matches));
// 15b. The contacts tier of the profile card reads the same book: nora's bio
// shows to alice (whose number nora holds) and blanks to bob (a stranger)
await api("/api/profile", { token: noraA.token, body: { bio: "ask my contacts" } });
await api("/api/privacy", { token: noraA.token, body: { avatar: "contacts" } });
const noraToAlice = await api("/api/users/" + noraA.userId, { token: alice.token });
const noraToBob = await api("/api/users/" + noraA.userId, { token: bob.token });
check("contacts-tier bio shows to a contact",
  noraToAlice.ok && noraToAlice.user.bio === "ask my contacts",
  JSON.stringify(noraToAlice.user));
check("contacts-tier bio blanks to a stranger",
  noraToBob.ok && noraToBob.user.bio === null, JSON.stringify(noraToBob.user));

// 15b2. Named exceptions override the tiers in both directions
// deny: alice is nora's contact, yet an avatar deny row blanks the bio to her
await api("/api/privacy/exceptions", { token: noraA.token,
  body: { setting: "avatar", peerId: alice.userId, allow: false } });
const deniedCard = await api("/api/users/" + noraA.userId, { token: alice.token });
check("a deny exception beats the contacts tier",
  deniedCard.ok && deniedCard.user.bio === null, JSON.stringify(deniedCard.user));
await api("/api/privacy/exceptions", { token: noraA.token,
  body: { setting: "avatar", peerId: alice.userId, allow: null } });
const restoredCard = await api("/api/users/" + noraA.userId, { token: alice.token });
check("clearing the exception returns to the tier",
  restoredCard.ok && restoredCard.user.bio === "ask my contacts",
  JSON.stringify(restoredCard.user));
// allow: bob is a stranger, yet a discovery allow row lets him find her
await api("/api/privacy", { token: noraA.token, body: { phoneDiscovery: "nobody" } });
await api("/api/privacy/exceptions", { token: noraA.token,
  body: { setting: "phone_discovery", peerId: bob.userId, allow: true } });
const foundByBob = await api("/api/contacts/discover", { token: bob.token,
  body: { hashes: [laterHash] } });
check("an allow exception beats the nobody tier",
  foundByBob.ok && foundByBob.matches.length === 1 && foundByBob.matches[0].id === noraA.userId,
  JSON.stringify(foundByBob.matches));
await api("/api/privacy/exceptions", { token: noraA.token,
  body: { setting: "phone_discovery", peerId: bob.userId, allow: null } });
await api("/api/privacy", { token: noraA.token, body: { phoneDiscovery: "everyone" } });

// 15c. Who can add me to a group: the protected are not added, the response
// names them so the client can offer the invite link instead
await api("/api/privacy", { token: noraA.token, body: { groupInvites: "nobody" } });
const gByBob = await api("/api/chats", { token: bob.token,
  body: { kind: "group", memberIds: [noraA.userId, alice.userId], title: "no nora" } });
check("group create leaves the protected out and names them",
  gByBob.ok && gByBob.invited?.length === 1 && gByBob.invited[0] === noraA.userId,
  JSON.stringify(gByBob));
const gByBobState = await api("/api/chats", { token: bob.token });
const noNora = gByBobState.chats.find((ch) => ch.state.chatId === gByBob.chatId);
check("the protected user is really not a member",
  noNora && !noNora.state.members.some((m) => m.userId === noraA.userId),
  JSON.stringify(noNora?.state.members?.map((m) => m.userId)));
// contacts: nora holds alice's number, so alice may add her
await api("/api/privacy", { token: noraA.token, body: { groupInvites: "contacts" } });
const gByAlice = await api("/api/chats", { token: alice.token,
  body: { kind: "group", memberIds: [noraA.userId], title: "with nora" } });
check("a contact adds the protected user straight in",
  gByAlice.ok && !gByAlice.invited,
  JSON.stringify(gByAlice));

// nobody: not even a contact finds her
await api("/api/privacy", { token: noraA.token, body: { phoneDiscovery: "nobody" } });
const noraGone = await api("/api/contacts/discover", { token: alice.token,
  body: { hashes: [laterHash] } });
check("nobody-tier discovery hides from everyone",
  noraGone.ok && noraGone.matches.length === 0, JSON.stringify(noraGone.matches));

// 16. Invite link: only a member can create one, joining by code works
const dave = await api("/api/register", { body: {
  username: "dave_" + suffix, displayName: "Dave", ...fakeKeys("d") } });
check("register dave", dave.ok);

const invByStranger = await api(`/api/chats/${grp.chatId}/invite`, { token: dave.token, body: {} });
check("invite by non-member rejected", !invByStranger.ok && invByStranger.error === "not_member");

const inv = await api(`/api/chats/${grp.chatId}/invite`, { token: alice.token, body: {} });
check("invite created", inv.ok && inv.code);

const badJoin = await api("/api/join/nonexistent-code", { token: dave.token, body: {} });
check("invalid invite rejected", !badJoin.ok && badJoin.error === "invalid_invite");

const join = await api(`/api/join/${inv.code}`, { token: dave.token, body: {} });
check("join via invite", join.ok && join.chatId === grp.chatId, JSON.stringify(join));
const joinAgain = await api(`/api/join/${inv.code}`, { token: dave.token, body: {} });
check("join idempotent", joinAgain.ok);

const daveChats = await api("/api/chats", { token: dave.token });
const daveGrp = daveChats.chats?.find((c2) => c2.state.chatId === grp.chatId);
check("dave is member after join", !!daveGrp
  && daveGrp.state.members.some((m) => m.userId === dave.userId));

// an invite does not let anyone join a direct chat
const dinv = await api(`/api/chats/${chat.chatId}/invite`, { token: alice.token, body: {} });
const djoin = await api(`/api/join/${dinv.code}`, { token: dave.token, body: {} });
check("join into direct rejected", !djoin.ok && djoin.error === "not_group");

// 16a. Group settings: only an admin changes the title and avatar, members see a chat frame
const titleByMember = await api(`/api/chats/${grp.chatId}/settings`, { token: dave.token,
  body: { title: "Hijacked" } });
check("group title by non-admin rejected",
  !titleByMember.ok && titleByMember.error === "not_admin");

const newTitle = "Team " + suffix;
const titleByAdmin = await api(`/api/chats/${grp.chatId}/settings`, { token: alice.token,
  body: { title: newTitle } });
const titleFrame = await cb2.waitFor((f) =>
  f.t === "chat" && f.chatId === grp.chatId && f.state.title === newTitle);
check("group title by admin", titleByAdmin.ok && !!titleFrame);

async function uploadAvatar(token, query = "") {
  const res = await fetch(`${BASE}/api/avatar${query}`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "image/jpeg" },
    body: new Uint8Array([0xff, 0xd8, 0xff, 0xdb, 1, 2, 3]),
  });
  return res.json();
}
const avByMember = await uploadAvatar(dave.token, `?chatId=${grp.chatId}`);
check("group avatar by non-admin rejected", !avByMember.ok && avByMember.error === "not_admin");

const avByAdmin = await uploadAvatar(alice.token, `?chatId=${grp.chatId}`);
const avFrame = await cb2.waitFor((f) =>
  f.t === "chat" && f.chatId === grp.chatId && f.state.avatarId === avByAdmin.avatarId);
check("group avatar by admin", avByAdmin.ok && !!avFrame);

const meAfter = await api("/api/me", { token: alice.token });
check("group avatar does not touch profile", meAfter.user.avatar_id !== avByAdmin.avatarId);

const ownAvatar = await uploadAvatar(alice.token);
const meOwn = await api("/api/me", { token: alice.token });
check("own avatar still updates profile",
  ownAvatar.ok && meOwn.user.avatar_id === ownAvatar.avatarId);

// 16b. Member rights: who may write and who may bring people in. Its own group,
// because the checks below count the frames of grp.
const rgrp = await api("/api/chats", { token: alice.token,
  body: { kind: "group", memberIds: [bob.userId, dave.userId], title: "Rights" } });
check("create rights group", rgrp.ok, JSON.stringify(rgrp));

const policyByMember = await api(`/api/chats/${rgrp.chatId}/settings`, { token: dave.token,
  body: { sendPolicy: "admins" } });
check("group rights by non-admin rejected",
  !policyByMember.ok && policyByMember.error === "not_admin");

const cdave = new Client("dave-rights", dave.token);
await cdave.connect();
const daveOpen = cdave.mark();
cdave.send({ t: "send", chatId: rgrp.chatId, clientMsgId: "cm-open-1", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
check("member writes while the group is open",
  !!(await cdave.waitAfter(daveOpen, (f) => f.t === "sent" && f.clientMsgId === "cm-open-1")));

const readOnly = await api(`/api/chats/${rgrp.chatId}/settings`, { token: alice.token,
  body: { sendPolicy: "admins" } });
const readOnlyFrame = await cb2.waitFor((f) =>
  f.t === "chat" && f.chatId === rgrp.chatId && f.state.sendPolicy === "admins");
check("admin makes the group read-only", readOnly.ok && !!readOnlyFrame);

const daveMuted = cdave.mark();
cdave.send({ t: "send", chatId: rgrp.chatId, clientMsgId: "cm-muted-1", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
const muteErr = await cdave.waitAfter(daveMuted,
  (f) => f.t === "error" && f.clientMsgId === "cm-muted-1");
check("member cannot write in a read-only group",
  !!muteErr && muteErr.error === "not_allowed", JSON.stringify(muteErr));

// the crypto keeps working: a key handout, a repair, an ack are service frames
const daveService = cdave.mark();
cdave.send({ t: "send", chatId: rgrp.chatId, clientMsgId: "cm-muted-skd", sentAt: Date.now(),
  service: true, body: { v: 1, mode: "skd", c: "c2tk" } });
check("service frames pass in a read-only group",
  !!(await cdave.waitAfter(daveService, (f) => f.t === "sent" && f.clientMsgId === "cm-muted-skd")));

const adminWrite = ca.mark();
ca.send({ t: "send", chatId: rgrp.chatId, clientMsgId: "cm-muted-admin", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
check("admin writes in a read-only group",
  !!(await ca.waitAfter(adminWrite, (f) => f.t === "sent" && f.clientMsgId === "cm-muted-admin")));

await api(`/api/chats/${rgrp.chatId}/settings`, { token: alice.token, body: { sendPolicy: "all" } });
const daveAgain = cdave.mark();
cdave.send({ t: "send", chatId: rgrp.chatId, clientMsgId: "cm-open-2", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
check("the group opens again",
  !!(await cdave.waitAfter(daveAgain, (f) => f.t === "sent" && f.clientMsgId === "cm-open-2")));

// inviting: open by default, admins only once the policy says so
const guest = await api("/api/register", { body: {
  username: "guest" + suffix, displayName: "Guest", device: { name: "iPhone" }, ...fakeKeys("g1") } });
const addByMember = await api(`/api/chats/${rgrp.chatId}/members`, { token: dave.token,
  body: { add: [guest.userId], remove: [] } });
check("member adds a member while inviting is open", addByMember.ok, JSON.stringify(addByMember));
const invByMember = await api(`/api/chats/${rgrp.chatId}/invite`, { token: dave.token, body: {} });
check("member mints an invite while inviting is open", invByMember.ok);

const lockInvites = await api(`/api/chats/${rgrp.chatId}/settings`, { token: alice.token,
  body: { invitePolicy: "admins" } });
check("admin locks inviting", lockInvites.ok);
const guest2 = await api("/api/register", { body: {
  username: "guesttwo" + suffix, displayName: "Guest Two", device: { name: "iPhone" }, ...fakeKeys("g2") } });
const addByMemberLocked = await api(`/api/chats/${rgrp.chatId}/members`, { token: dave.token,
  body: { add: [guest2.userId], remove: [] } });
check("member cannot add once inviting is locked",
  !addByMemberLocked.ok && addByMemberLocked.error === "not_allowed",
  JSON.stringify(addByMemberLocked));
const invLocked = await api(`/api/chats/${rgrp.chatId}/invite`, { token: dave.token, body: {} });
check("member cannot mint an invite once inviting is locked",
  !invLocked.ok && invLocked.error === "not_allowed", JSON.stringify(invLocked));
const invByAdmin = await api(`/api/chats/${rgrp.chatId}/invite`, { token: alice.token, body: {} });
check("admin mints an invite in a locked group", invByAdmin.ok);
// a member still leaves a group they cannot write in: leaving is not a send
const rightsLeave = await api(`/api/chats/${rgrp.chatId}/delete`, { token: dave.token, body: {} });
check("member leaves a locked group", rightsLeave.ok, JSON.stringify(rightsLeave));
cdave.ws.close();
// alice never read this group, and the badge checks further down count her unread
// over every chat she is in
const rgrpEntry = (await api("/api/chats", { token: alice.token }))
  .chats.find((e) => e.state.chatId === rgrp.chatId);
ca.send({ t: "read", chatId: rgrp.chatId, upToSeq: rgrpEntry.state.lastSeq });
await new Promise((r) => setTimeout(r, 300));
const rgrpRead = (await api("/api/chats", { token: alice.token }))
  .chats.find((e) => e.state.chatId === rgrp.chatId);
check("the rights group leaves no unread behind",
  (rgrpRead.state.readMarks[alice.userId] ?? 0) >= rgrpRead.state.lastSeq,
  JSON.stringify(rgrpRead.state.readMarks));

// 17. Service frame: the flag reaches the recipient, dedupe by clientMsgId works
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-skd-1", sentAt: Date.now(),
  service: true, body: { v: 1, mode: "skd", c: "c2tk" } });
const svc = await cb2.waitFor((f) => f.t === "msg" && f.chatId === chat.chatId && f.service === true);
check("service flag delivered", !!svc);
const svcAck1 = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-skd-1");
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-skd-1", sentAt: Date.now(),
  service: true, body: { v: 1, mode: "skd", c: "c2tk" } });
const svcAck2 = await ca.waitFor((f) =>
  f.t === "sent" && f.clientMsgId === "cm-skd-1" && f !== svcAck1);
check("service dedupe by clientMsgId", !!svcAck2 && svcAck2.seq === svcAck1.seq);

// 18. Sync replays tombstones and read marks
ca.send({ t: "read", chatId: chat.chatId, upToSeq: 2 });
await new Promise((r) => setTimeout(r, 300));
const cb3 = new Client("bob3", bob.token);
await cb3.connect();
cb3.send({ t: "sync", cursors: { [chat.chatId]: svc.seq } });
const syncTomb = await cb3.waitFor((f) => f.t === "deleted" && f.seqs.includes(sent.seq));
check("sync replays tombstone", !!syncTomb);
const syncRead = await cb3.waitFor((f) =>
  f.t === "receipt" && f.kind === "read" && f.by === alice.userId && f.upToSeq === 2);
check("sync replays read mark", !!syncRead);

// 19. Catch-up in portions: the cursor moves, "there is more" goes out, nothing is lost
const N = 210;
for (let i = 0; i < N; i++) {
  ca.send({ t: "send", chatId: grp.chatId, clientMsgId: `cm-bulk-${i}`, sentAt: Date.now(),
    body: { v: 1, mode: "skm", c: "Zg" } });
}
const lastBulk = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === `cm-bulk-${N - 1}`, 30000);
check("bulk send acked", !!lastBulk);
const cb4 = new Client("bob4", bob.token);
await cb4.connect();
const walk = await catchUp(cb4, { [grp.chatId]: 1 });
check("catch-up finishes", walk.done, JSON.stringify(walk.portions.map((p) => p.more)));
const bulkGot = cb4.frames.filter((f) => f.t === "msg" && f.chatId === grp.chatId && f.seq > 1);
check("catch-up backfills the whole backlog", bulkGot.length === N, `got ${bulkGot.length}`);
const grpStates = walk.portions.map((p) => p.states.find((s) => s.chatId === grp.chatId));
check("catch-up goes in portions", walk.portions.length > 1 && grpStates.every(Boolean),
  `${walk.portions.length} portion(s)`);
check("catch-up cursor moves forward",
  grpStates.every((s, i) => i === 0 || s.cursor > grpStates[i - 1].cursor),
  JSON.stringify(grpStates.map((s) => s?.cursor)));
check("catch-up portion is bounded",
  cb4.frames.filter((f) => f.t === "msg" && f.chatId === grp.chatId
    && f.at <= grpStates[0].at).length <= 128);
check("catch-up ends with no more",
  grpStates.slice(0, -1).every((s) => s.more) && grpStates[grpStates.length - 1].more === false);

// 19a. Between portions the object still answers everything else: a ping sent
// right after sync gets its pong before the catch-up reaches the end
const cb5 = new Client("bob5", bob.token);
await cb5.connect();
cb5.send({ t: "sync", cursors: { [grp.chatId]: 1 } });
cb5.send({ t: "ping" });
const pongMid = await cb5.waitFor((f) => f.t === "pong", 15000);
const deliveredByPong = cb5.frames.filter(
  (f) => f.t === "msg" && f.chatId === grp.chatId && f.at <= pongMid?.at).length;
check("live traffic is answered mid catch-up", !!pongMid && deliveredByPong < N,
  `${deliveredByPong} of ${N} delivered by the pong`);

// 19b. A drop in the middle of a catch-up: the next connection continues from
// the cursor rather than from zero
const cb6 = new Client("bob6", bob.token);
await cb6.connect();
cb6.send({ t: "sync", cursors: { [grp.chatId]: 1 } });
const firstState = await cb6.waitAfter(0, (f) => f.t === "syncState" && f.chatId === grp.chatId, 15000);
check("interrupted catch-up has a confirmed cursor", !!firstState && firstState.more);
cb6.ws.close();
await new Promise((r) => setTimeout(r, 300));
const cb7 = new Client("bob7", bob.token);
await cb7.connect();
const resumed = await catchUp(cb7, { [grp.chatId]: firstState.cursor });
const resumedMsgs = cb7.frames.filter((f) => f.t === "msg" && f.chatId === grp.chatId);
check("interrupted catch-up resumes from the cursor",
  resumed.done && !resumedMsgs.some((f) => f.seq <= firstState.cursor)
  && resumedMsgs.some((f) => f.seq === lastBulk.seq),
  `${resumedMsgs.length} msg(s) after seq ${firstState.cursor}`);
// replayed frames name the outbox row they answer, the way live echoes do:
// an author offline at a deferred deadline finalizes from this very path
check("catch-up msg frames carry the clientMsgId",
  resumedMsgs.length > 0 && resumedMsgs.every((f) => typeof f.clientMsgId === "string"),
  JSON.stringify(resumedMsgs[0]));

// 20. Blocking inside an existing chat
const henry = await api("/api/register", { body: {
  username: "henry_" + suffix, displayName: "Henry", ...fakeKeys("h") } });
const iris = await api("/api/register", { body: {
  username: "iris_" + suffix, displayName: "Iris", ...fakeKeys("i") } });
const bchat = await api("/api/chats", { token: henry.token,
  body: { kind: "direct", memberIds: [iris.userId] } });
check("block: chat created", bchat.ok, JSON.stringify(bchat));
await api(`/api/chats/${bchat.chatId}/accept`, { token: iris.token, body: {} });

const ch = new Client("henry", henry.token);
const ci = new Client("iris", iris.token);
await ch.connect(); await ci.connect();

// before the block the exchange runs as usual
ch.send({ t: "send", chatId: bchat.chatId, clientMsgId: "cm-b0", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const b0 = await ch.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-b0");
check("block: msg before block delivered",
  !!(await ci.waitFor((f) => f.t === "msg" && f.chatId === bchat.chatId && f.seq === b0.seq)));

// Iris blocks Henry
check("block: applied", (await api("/api/block", { token: iris.token,
  body: { userId: henry.userId, blocked: true } })).ok);

// (a) Henry writes: the ack arrives as usual, nothing reaches Iris
ch.send({ t: "send", chatId: bchat.chatId, clientMsgId: "cm-b1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const b1 = await ch.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-b1");
check("block: sender still gets sent ack", !!b1 && b1.seq === b0.seq + 1, JSON.stringify(b1));
check("block: no error frame to sender",
  !ch.frames.some((f) => f.t === "error" && f.clientMsgId === "cm-b1"));
check("block: msg not delivered",
  !(await ci.waitFor((f) => f.t === "msg" && f.chatId === bchat.chatId && f.seq === b1.seq, 1200)));
check("block: own echo still delivered",
  !!(await ch.waitFor((f) => f.t === "msg" && f.chatId === bchat.chatId && f.seq === b1.seq)));

// (b) the blocked message is absent from the blocker's history and present in the sender's
const irisHist = await api(`/api/chats/${bchat.chatId}/history?fromSeq=0`, { token: iris.token });
check("block: hidden from blocker history",
  !irisHist.msgs.some((m) => m.seq === b1.seq)
  && irisHist.msgs.some((m) => m.seq === b0.seq), JSON.stringify(irisHist.msgs.length));
const henryHist = await api(`/api/chats/${bchat.chatId}/history?fromSeq=0`, { token: henry.token });
check("block: visible in sender history",
  henryHist.msgs.some((m) => m.seq === b1.seq));

// (c) the blocker's sync does not replay the blocked message
const ci2 = new Client("iris2", iris.token);
await ci2.connect();
ci2.send({ t: "sync", cursors: { [bchat.chatId]: 0 } });
await ci2.waitFor((f) => f.t === "msg" && f.chatId === bchat.chatId && f.seq === b0.seq);
await new Promise((r) => setTimeout(r, 500));
check("block: sync skips blocked msg",
  !ci2.frames.some((f) => f.t === "msg" && f.chatId === bchat.chatId && f.seq === b1.seq));

// (d) receipts and typing from the blocked user never reach the blocker
ch.send({ t: "read", chatId: bchat.chatId, upToSeq: b1.seq });
ch.send({ t: "typing", chatId: bchat.chatId, kind: "text" });
await new Promise((r) => setTimeout(r, 700));
check("block: no receipt to blocker",
  !ci.frames.some((f) => f.t === "receipt" && f.by === henry.userId));
check("block: no typing to blocker",
  !ci.frames.some((f) => f.t === "typing" && f.from === henry.userId));

// (e) the blocker writes to the blocked user: an explicit machine-readable refusal
ci.send({ t: "send", chatId: bchat.chatId, clientMsgId: "cm-b2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const bErr = await ci.waitFor((f) => f.t === "error" && f.clientMsgId === "cm-b2");
check("block: blocker gets error code", !!bErr && bErr.error === "blocked", JSON.stringify(bErr));
check("block: blocker msg not delivered",
  !(await ch.waitFor((f) => f.t === "msg" && f.from === iris.userId, 1200)));

// (f) unblocking brings delivery back; messages from the blocked period stay hidden
check("block: released", (await api("/api/block", { token: iris.token,
  body: { userId: henry.userId, blocked: false } })).ok);
ch.send({ t: "send", chatId: bchat.chatId, clientMsgId: "cm-b3", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const b3 = await ch.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-b3");
check("block: delivery resumes after unblock",
  !!b3 && !!(await ci.waitFor((f) => f.t === "msg" && f.chatId === bchat.chatId && f.seq === b3.seq)));
const irisHist2 = await api(`/api/chats/${bchat.chatId}/history?fromSeq=0`, { token: iris.token });
check("block: blocked msg stays hidden after unblock",
  !irisHist2.msgs.some((m) => m.seq === b1.seq)
  && irisHist2.msgs.some((m) => m.seq === b3?.seq));
ch.ws.close(); ci.ws.close(); ci2.ws.close();

// 21. Privacy: last seen, read receipts, typing — each enforced by the server,
// not just hidden client-side, and reciprocal: hiding your own also blinds you
// to everyone else's.
{
  const priya = await api("/api/register", { body: {
    username: "priya_" + suffix, displayName: "Priya", ...fakeKeys("k1") } });
  const milo = await api("/api/register", { body: {
    username: "milo_" + suffix, displayName: "Milo", ...fakeKeys("l1") } });
  const pchat = await api("/api/chats", { token: priya.token,
    body: { kind: "direct", memberIds: [milo.userId] } });
  await api(`/api/chats/${pchat.chatId}/accept`, { token: milo.token, body: {} });

  const defaults = await api("/api/privacy", { token: priya.token });
  check("privacy defaults", defaults.ok && defaults.privacy.lastSeen === "everyone"
    && defaults.privacy.avatar === "everyone"
    && defaults.privacy.readReceipts === true && defaults.privacy.typing === true,
    JSON.stringify(defaults));

  const ck = new Client("priya", priya.token);
  const cl = new Client("milo", milo.token);
  await ck.connect(); await cl.connect();

  // -- read receipts --
  ck.send({ t: "send", chatId: pchat.chatId, clientMsgId: "cm-p0", sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  const p0 = await ck.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p0");
  await cl.waitFor((f) => f.t === "msg" && f.chatId === pchat.chatId && f.seq === p0.seq);

  cl.send({ t: "read", chatId: pchat.chatId, upToSeq: p0.seq });
  check("read receipt reaches the sender by default",
    !!(await ck.waitFor((f) => f.t === "receipt" && f.kind === "read" && f.by === milo.userId)));

  check("readReceipts off", (await api("/api/privacy", { token: milo.token,
    body: { readReceipts: false } })).ok);
  ck.send({ t: "send", chatId: pchat.chatId, clientMsgId: "cm-p1", sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  const p1 = await ck.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p1");
  await cl.waitFor((f) => f.t === "msg" && f.chatId === pchat.chatId && f.seq === p1.seq);
  const ckMark = ck.mark();
  cl.send({ t: "read", chatId: pchat.chatId, upToSeq: p1.seq });
  await new Promise((r) => setTimeout(r, 700));
  check("read receipt off: not sent to the peer",
    !ck.frames.slice(ckMark).some((f) => f.t === "receipt" && f.by === milo.userId));

  // milo's own read cursor still moves — the receipt is what's suppressed, not his mark
  const pstate = await api("/api/chats", { token: milo.token });
  const pc = pstate.chats.find((c2) => c2.state.chatId === pchat.chatId);
  check("read mark still recorded for the reader with receipts off",
    pc?.state.readMarks[milo.userId] === p1.seq, JSON.stringify(pc?.state.readMarks));

  check("readReceipts back on", (await api("/api/privacy", { token: milo.token,
    body: { readReceipts: true } })).ok);
  check("readReceipts off on the other side too", (await api("/api/privacy", { token: priya.token,
    body: { readReceipts: false } })).ok);
  ck.send({ t: "send", chatId: pchat.chatId, clientMsgId: "cm-p2", sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  const p2 = await ck.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p2");
  await cl.waitFor((f) => f.t === "msg" && f.chatId === pchat.chatId && f.seq === p2.seq);
  const ckMark2 = ck.mark();
  cl.send({ t: "read", chatId: pchat.chatId, upToSeq: p2.seq });
  await new Promise((r) => setTimeout(r, 700));
  check("read receipt off reciprocally: a peer with it off gets none either",
    !ck.frames.slice(ckMark2).some((f) => f.t === "receipt" && f.by === milo.userId));
  check("readReceipts restored", (await api("/api/privacy", { token: priya.token,
    body: { readReceipts: true } })).ok);

  // -- typing --
  check("typing off", (await api("/api/privacy", { token: priya.token,
    body: { typing: false } })).ok);
  const clMark = cl.mark();
  ck.send({ t: "typing", chatId: pchat.chatId, kind: "text" });
  await new Promise((r) => setTimeout(r, 700));
  check("typing off: not sent at all",
    !cl.frames.slice(clMark).some((f) => f.t === "typing" && f.from === priya.userId));

  check("typing back on", (await api("/api/privacy", { token: priya.token,
    body: { typing: true } })).ok);
  check("typing off on the recipient", (await api("/api/privacy", { token: milo.token,
    body: { typing: false } })).ok);
  const clMark2 = cl.mark();
  ck.send({ t: "typing", chatId: pchat.chatId, kind: "text" });
  await new Promise((r) => setTimeout(r, 700));
  check("typing off reciprocally: a peer with it off receives none either",
    !cl.frames.slice(clMark2).some((f) => f.t === "typing" && f.from === priya.userId));
  check("typing restored", (await api("/api/privacy", { token: milo.token,
    body: { typing: true } })).ok);

  // -- last seen --
  const beforeHide = await api(`/api/users/${priya.userId}`, { token: milo.token });
  check("last seen visible by default", beforeHide.ok && beforeHide.presence !== null,
    JSON.stringify(beforeHide));

  const clMark3 = cl.mark();
  ck.send({ t: "fg" });
  check("presence frame reaches the peer by default",
    !!(await cl.waitAfter(clMark3, (f) => f.t === "presence" && f.userId === priya.userId)));

  check("lastSeen hidden", (await api("/api/privacy", { token: priya.token,
    body: { lastSeen: "nobody" } })).ok);
  const hiddenFromPeer = await api(`/api/users/${priya.userId}`, { token: milo.token });
  check("last seen hidden from the peer over REST",
    hiddenFromPeer.ok && hiddenFromPeer.presence === null, JSON.stringify(hiddenFromPeer));
  const hiddenFromSelf = await api(`/api/users/${milo.userId}`, { token: priya.token });
  check("hiding your own last seen blinds you to everyone else's",
    hiddenFromSelf.ok && hiddenFromSelf.presence === null, JSON.stringify(hiddenFromSelf));

  const clMark4 = cl.mark();
  ck.send({ t: "bg" });
  await new Promise((r) => setTimeout(r, 200));
  ck.send({ t: "fg" });
  await new Promise((r) => setTimeout(r, 700));
  check("presence frame withheld once last seen is hidden",
    !cl.frames.slice(clMark4).some((f) => f.t === "presence" && f.userId === priya.userId));

  check("lastSeen restored", (await api("/api/privacy", { token: priya.token,
    body: { lastSeen: "everyone" } })).ok);
  const restored = await api(`/api/users/${priya.userId}`, { token: milo.token });
  check("last seen visible again after restoring", restored.ok && restored.presence !== null,
    JSON.stringify(restored));

  // -- avatar and bio --
  const avUpload = await (await fetch(BASE + "/api/avatar", {
    method: "POST",
    headers: { authorization: `Bearer ${priya.token}`, "content-type": "image/png" },
    body: new Uint8Array([0x89, 0x50, 0x4e, 0x47]),
  })).json();
  check("avatar uploaded for the privacy check", avUpload.ok, JSON.stringify(avUpload));
  check("bio set", (await api("/api/profile", { token: priya.token,
    body: { bio: "reachable by pigeon" } })).ok);

  const cardOpen = await api(`/api/users/${priya.userId}`, { token: milo.token });
  check("avatar and bio visible by default", cardOpen.ok
    && cardOpen.user.avatar_id === avUpload.avatarId && cardOpen.user.bio === "reachable by pigeon",
    JSON.stringify(cardOpen));

  const clMark5 = cl.mark();
  check("avatar hidden", (await api("/api/privacy", { token: priya.token,
    body: { avatar: "nobody" } })).ok);
  check("hiding pushes the blanked card to the peer",
    !!(await cl.waitAfter(clMark5, (f) => f.t === "profile" && f.user.id === priya.userId
      && f.user.avatar_id === null && f.user.bio === null)));
  const cardHidden = await api(`/api/users/${priya.userId}`, { token: milo.token });
  check("hidden avatar and bio withheld from the peer", cardHidden.ok
    && cardHidden.user.avatar_id === null && cardHidden.user.bio === null,
    JSON.stringify(cardHidden));
  check("the name stays visible with the avatar hidden",
    cardHidden.user.display_name === "Priya", JSON.stringify(cardHidden));
  check("hidden avatar bytes answer 404 to the peer",
    (await fetch(BASE + "/api/avatar/" + avUpload.avatarId,
      { headers: { authorization: `Bearer ${milo.token}` } })).status === 404);
  const cardOwn = await api(`/api/users/${priya.userId}`, { token: priya.token });
  check("hidden avatar and bio still served to the owner", cardOwn.ok
    && cardOwn.user.avatar_id === avUpload.avatarId && cardOwn.user.bio === "reachable by pigeon",
    JSON.stringify(cardOwn));
  check("hidden avatar bytes still served to the owner",
    (await fetch(BASE + "/api/avatar/" + avUpload.avatarId,
      { headers: { authorization: `Bearer ${priya.token}` } })).status === 200);
  const searchHidden = await api(`/api/users?q=priya_${suffix}`, { token: milo.token });
  check("hidden avatar blank in search results", searchHidden.ok
    && searchHidden.users.some((u) => u.id === priya.userId && u.avatar_id === null),
    JSON.stringify(searchHidden));
  const chatsHidden = await api("/api/chats", { token: milo.token });
  const priyaInChats = chatsHidden.users.find((u) => u.id === priya.userId);
  check("hidden avatar and bio blank in the chat list card",
    priyaInChats && priyaInChats.avatar_id === null && priyaInChats.bio === null,
    JSON.stringify(priyaInChats));

  check("avatar restored", (await api("/api/privacy", { token: priya.token,
    body: { avatar: "everyone" } })).ok);
  const cardBack = await api(`/api/users/${priya.userId}`, { token: milo.token });
  check("avatar and bio visible again after restoring", cardBack.ok
    && cardBack.user.avatar_id === avUpload.avatarId && cardBack.user.bio === "reachable by pigeon",
    JSON.stringify(cardBack));
  check("avatar bytes served again after restoring",
    (await fetch(BASE + "/api/avatar/" + avUpload.avatarId,
      { headers: { authorization: `Bearer ${milo.token}` } })).status === 200);

  ck.ws.close(); cl.ws.close();
}

// 22. Logout and device revocation
const logoutUser = await api("/api/register", { body: {
  username: "logout_" + suffix, displayName: "Frank", ...fakeKeys("f") } });
const logoutSess0 = await api("/api/sessions", { token: logoutUser.token });
check("sessions lists current device", logoutSess0.ok && logoutSess0.sessions.length === 1
  && logoutSess0.sessions[0].deviceId === logoutUser.deviceId && logoutSess0.sessions[0].current === true,
  JSON.stringify(logoutSess0));

const lg_cLogout = new Client("logout", logoutUser.token);
await lg_cLogout.connect();
check("logoutUser ws before logout", !!(await lg_cLogout.waitFor((f) => f.t === "hello")));

const lg_out = await api("/api/logout", { token: logoutUser.token, body: {} });
check("logout ok", lg_out.ok, JSON.stringify(lg_out));

const lg_meAfter = await apiRaw("/api/me", { token: logoutUser.token });
check("lg_revoked token rejected on api", lg_meAfter.status === 401
  && (await lg_meAfter.json()).error === "unauthorized");

// the server sends close frame 4401 immediately; wrangler dev tears the TCP tail
// down with a delay, so the check is that the socket has left OPEN
await new Promise((r) => setTimeout(r, 400));
check("lg_revoked token closes live socket", lg_cLogout.ws.readyState !== 1,
  `readyState=${lg_cLogout.ws.readyState}`);

const lg_wsAfter = await new Promise((r) => {
  const ws = new WebSocket(`${WS_BASE}/ws?token=${logoutUser.token}`);
  ws.on("open", () => { ws.close(); r("open"); });
  ws.on("error", () => r("error"));
});
check("lg_revoked token rejected on ws upgrade", lg_wsAfter === "error");

// revoking one specific device from the list
const lg_gina = await api("/api/register", { body: {
  username: "gina_" + suffix, displayName: "Gina", ...fakeKeys("g") } });
const lg_alien = await api(`/api/sessions/${alice.deviceId}/revoke`, { token: lg_gina.token, body: {} });
check("cannot revoke foreign device", !lg_alien.ok && lg_alien.error === "device_not_found");
const lg_revoked = await api(`/api/sessions/${lg_gina.deviceId}/revoke`, { token: lg_gina.token, body: {} });
check("revoke device by id", lg_revoked.ok, JSON.stringify(lg_revoked));
const lg_ginaAfter = await apiRaw("/api/me", { token: lg_gina.token });
check("lg_revoked device token dead", lg_ginaAfter.status === 401);
const lg_aliceStill = await api("/api/me", { token: alice.token });
check("foreign device untouched", lg_aliceStill.ok && lg_aliceStill.user.id === alice.userId);

// 21b. Linking a second device
//
// The server carries the sealed bundle without reading it, so the checks are
// about the state machine: who may look a code up, who may approve, who may
// claim, and that the account's keys are what a claimed device must present.
async function provisionStart(name = "iPhone", platform = "ios", key = "eph_pub") {
  return api("/api/provision/start", { body: { ephemeralKey: key, device: { name, platform } } });
}
async function provisionGet(id, provisionToken) {
  return (await fetch(`${BASE}/api/provision/${id}`, {
    headers: { "x-provision-token": provisionToken },
  })).json();
}
async function provisionPost(id, path, provisionToken, body) {
  return (await fetch(`${BASE}/api/provision/${id}/${path}`, {
    method: "POST",
    headers: { "x-provision-token": provisionToken, "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  })).json();
}

const lk_owner = await api("/api/register", { body: {
  username: "link_" + suffix, displayName: "Hana", ...fakeKeys("h") } });
const lk_ownerKeys = fakeKeys("h");

const lk_start = await provisionStart();
check("provision session opens without auth",
  lk_start.ok && !!lk_start.provisionId && !!lk_start.provisionToken
  && lk_start.code?.length === 8, JSON.stringify(lk_start));
check("provision session starts pending",
  (await provisionGet(lk_start.provisionId, lk_start.provisionToken)).status === "pending");
const lk_wrongToken = await provisionGet(lk_start.provisionId, "not-the-token");
check("provision status needs the session token", lk_wrongToken.error === "unauthorized");

const lk_look = await api("/api/provision/lookup", {
  token: lk_owner.token, body: { code: lk_start.code.toLowerCase() } });
check("lookup resolves the code to the waiting device",
  lk_look.ok && lk_look.provisionId === lk_start.provisionId
  && lk_look.ephemeralKey === "eph_pub" && lk_look.device.name === "iPhone",
  JSON.stringify(lk_look));
const lk_lookMiss = await api("/api/provision/lookup", {
  token: lk_owner.token, body: { code: "ZZZZZZZZ" } });
check("unknown code is not found", lk_lookMiss.error === "provision_not_found");

const lk_claimEarly = await provisionPost(lk_start.provisionId, "claim", lk_start.provisionToken,
  { ...lk_ownerKeys, device: { name: "iPhone" } });
check("claim before approval is refused", lk_claimEarly.error === "provision_not_approved");

const lk_approve = await api(`/api/provision/${lk_start.provisionId}/approve`, {
  token: lk_owner.token, body: { envelope: "sealed-bundle" } });
check("approve accepted", lk_approve.ok, JSON.stringify(lk_approve));
const lk_status = await provisionGet(lk_start.provisionId, lk_start.provisionToken);
check("approved session hands the envelope to the new device",
  lk_status.status === "approved" && lk_status.envelope === "sealed-bundle",
  JSON.stringify(lk_status));
const lk_reapprove = await api(`/api/provision/${lk_start.provisionId}/approve`, {
  token: alice.token, body: { envelope: "someone-elses-bundle" } });
check("an approved session cannot be approved again",
  lk_reapprove.error === "provision_claimed", JSON.stringify(lk_reapprove));
check("lookup no longer resolves an approved session",
  (await api("/api/provision/lookup", { token: alice.token, body: { code: lk_start.code } }))
    .error === "provision_claimed");

const lk_alienKeys = fakeKeys("zz");
const lk_alienClaim = await provisionPost(lk_start.provisionId, "claim", lk_start.provisionToken,
  { ...lk_alienKeys, device: { name: "iPhone" } });
check("a device presenting other identity keys is refused",
  lk_alienClaim.error === "identity_mismatch", JSON.stringify(lk_alienClaim));

const lk_claim = await provisionPost(lk_start.provisionId, "claim", lk_start.provisionToken,
  { ...lk_ownerKeys, device: { name: "iPhone" } });
check("claim mints a device on the approving account",
  lk_claim.ok && lk_claim.userId === lk_owner.userId && !!lk_claim.deviceId
  && lk_claim.deviceId !== lk_owner.deviceId && !!lk_claim.token, JSON.stringify(lk_claim));
check("the new token is the account's",
  (await api("/api/me", { token: lk_claim.token })).user.id === lk_owner.userId);
const lk_sessions = await api("/api/sessions", { token: lk_owner.token });
check("both devices are listed", lk_sessions.sessions.length === 2, JSON.stringify(lk_sessions));
const lk_devices = await api(`/api/devices?ids=${lk_owner.userId}`, { token: alice.token });
check("a peer sees both devices under one identity key",
  lk_devices.devices.length === 2
  && new Set(lk_devices.devices.map((d) => d.identitySignKey)).size === 1,
  JSON.stringify(lk_devices));
check("linking bumped the device-set version",
  lk_devices.versions[lk_owner.userId] === 2, JSON.stringify(lk_devices.versions));

// the identity heal rotates a device's keys in place: peers cache the device
// set by version, so a rotation that left the version alone would keep TOFU
// trusting the replaced key until an unrelated cache drop
const lk_heal = await api("/api/identity", { token: lk_owner.token, body: {
  identityKey: "ik_rotated", identitySignKey: "isk_rotated", identityKeySig: "iksig_rotated",
} });
check("identity heal accepted", lk_heal.ok === true, JSON.stringify(lk_heal));
const lk_devices2 = await api(`/api/devices?ids=${lk_owner.userId}`, { token: alice.token });
check("identity heal bumped the device-set version",
  lk_devices2.versions[lk_owner.userId] === 3, JSON.stringify(lk_devices2.versions));
check("the rotated key is what peers now read",
  lk_devices2.devices.some((d) => d.identitySignKey === "isk_rotated"),
  JSON.stringify(lk_devices2.devices.map((d) => d.identitySignKey)));
check("a spent session cannot be claimed twice",
  (await provisionPost(lk_start.provisionId, "claim", lk_start.provisionToken,
    { ...lk_ownerKeys })).error === "provision_claimed");

// cancel takes the session down before anyone approves it
const lk_cancelled = await provisionStart("Mac", "macos");
check("cancel drops the session",
  (await provisionPost(lk_cancelled.provisionId, "cancel", lk_cancelled.provisionToken)).ok);
check("a cancelled code resolves to nothing",
  (await api("/api/provision/lookup", { token: lk_owner.token, body: { code: lk_cancelled.code } }))
    .error === "provision_not_found");

// revocation takes the device's keys with it: the peer stops addressing it
const lk_revoke = await api(`/api/sessions/${lk_claim.deviceId}/revoke`, {
  token: lk_owner.token, body: {} });
check("second device revoked", lk_revoke.ok, JSON.stringify(lk_revoke));
const lk_devicesAfter = await api(`/api/devices?ids=${lk_owner.userId}`, { token: alice.token });
check("a revoked device leaves the peer's device list",
  lk_devicesAfter.devices.length === 1
  && lk_devicesAfter.devices[0].deviceId === lk_owner.deviceId,
  JSON.stringify(lk_devicesAfter));
check("revocation bumped the version again",
  lk_devicesAfter.versions[lk_owner.userId] === 4, JSON.stringify(lk_devicesAfter.versions));
const lk_bundlesAfter = await api(`/api/users/${lk_owner.userId}/prekeys`, { token: alice.token });
check("a revoked device hands out no more prekey bundles",
  lk_bundlesAfter.bundles.length === 1
  && lk_bundlesAfter.bundles[0].deviceId === lk_owner.deviceId,
  JSON.stringify(lk_bundlesAfter));
check("the revoked device's token is dead",
  (await apiRaw("/api/me", { token: lk_claim.token })).status === 401);
check("the remaining device is untouched",
  (await api("/api/me", { token: lk_owner.token })).ok);

// the reconnect reconciliation: a version the client held is answered with the
// current one, and a user nobody ever registered is left out of the answer
const cver = new Client("alice-ver", alice.token);
await cver.connect();
cver.send({ t: "sync", cursors: {},
  deviceVersions: { [lk_owner.userId]: 1, "01NOBODYEVERHADTHISUSERID0": 4 } });
const verFrame = await cver.waitFor((f) => f.t === "deviceVersions");
check("sync answers the current device-set version",
  verFrame?.versions?.[lk_owner.userId] === 4, JSON.stringify(verFrame));
check("an unknown user is absent from the versions answer",
  !!verFrame && !("01NOBODYEVERHADTHISUSERID0" in verFrame.versions), JSON.stringify(verFrame));
cver.ws.close();

// 22. Push path: a tiny receiver instead of APNs (port from PUSH_PORT, where APNS_HOST points)
const pushes = [];
// the receiver plays APNs: dead-token answers 410, flaky-token answers 429 on the
// first attempt; hold delays the answer for a device's push, so the ack can be
// shown not to wait on APNs
let flakyHits = 0;
let hold = { token: null, ms: 0 };
const pushSrv = http.createServer((req, res) => {
  let data = "";
  req.on("data", (c) => (data += c));
  req.on("end", () => {
    pushes.push({ url: req.url, headers: req.headers, body: JSON.parse(data), at: Date.now() });
    if (req.url === "/3/device/dead-token") {
      res.writeHead(410, { "content-type": "application/json" });
      res.end(JSON.stringify({ reason: "Unregistered", timestamp: Date.now() }));
      return;
    }
    if (req.url === "/3/device/flaky-token" && ++flakyHits === 1) {
      res.writeHead(429, { "content-type": "application/json" });
      res.end(JSON.stringify({ reason: "TooManyRequests" }));
      return;
    }
    const done = () => { res.writeHead(200, { "apns-id": "mock" }); res.end(); };
    if (hold.token && req.url === `/3/device/${hold.token}`) setTimeout(done, hold.ms);
    else done();
  });
});
await new Promise((r) => pushSrv.listen(PUSH_PORT, r));

async function waitPush(pred, ms = 4000) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const p = pushes.find(pred);
    if (p) return p;
    await new Promise((r) => setTimeout(r, 50));
  }
  return null;
}
const pushFor = (token, ack) => (p) =>
  p.url === `/3/device/${token}` && p.body.chatId === ack.chatId && p.body.seq === ack.seq;

const eve = await api("/api/register", { body: {
  username: "eve_" + suffix, displayName: "Eve", ...fakeKeys("e") } });
await api("/api/push-token", { token: eve.token,
  body: { apnsToken: `eve-sim-${suffix}`, env: "development" } });
await api("/api/push-token", { token: alice.token,
  body: { apnsToken: `alice-sim-${suffix}`, env: "development" } });

const echat = await api("/api/chats", { token: alice.token,
  body: { kind: "direct", memberIds: [eve.userId] } });
check("create push chat", echat.ok);

// Alice back online to send
const ca2 = new Client("alice2", alice.token);
await ca2.connect();

// (a) recipient with no socket: the push goes out at once and keeps the APNs contract
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p1 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p1");
const push1 = await waitPush(pushFor(`eve-sim-${suffix}`, p1));
check("push delivered offline", !!push1, JSON.stringify(pushes));
if (push1) {
  check("push chatId", push1.body.chatId === echat.chatId);
  check("push thread-id", push1.body.aps["thread-id"] === echat.chatId);
  // the display order of a burst is built from seq, so seq travels in the push
  check("push carries seq", push1.body.seq === p1.seq, `seq=${push1.body.seq}`);
  check("push carries sentAt", typeof push1.body.sentAt === "number");
  // the chat is still a request: the counter does not reveal how much has been written
  check("push badge=0 before accept", push1.body.aps.badge === 0, `badge=${push1.body.aps.badge}`);
  check("push alert w/o plaintext", push1.body.aps.alert.body === "Новое сообщение"
    && push1.body.aps["mutable-content"] === 1 && push1.body.aps.sound === "default");
  // (chatId, seq) is the identity; the chat travels hashed to fit the 64-byte header
  const expectCollapse =
    createHash("sha256").update(echat.chatId).digest("hex").slice(0, 16) + ":" + p1.seq;
  check("push collapse-id names (chatId, seq)",
    push1.headers["apns-collapse-id"] === expectCollapse,
    push1.headers["apns-collapse-id"]);
  check("push topic", push1.headers["apns-topic"] === "msngr.msngr"
    && push1.headers["apns-push-type"] === "alert");
  check("dev push unsigned", push1.headers.authorization === undefined);
}

// (b) recipient with a live socket: both the WS frame and the push arrive (client dedupes)
const ce = new Client("eve", eve.token);
await ce.connect();
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p2 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p2");
check("eve got ws msg", !!(await ce.waitFor((f) =>
  f.t === "msg" && f.chatId === echat.chatId && f.seq === p2.seq)));
const push2 = await waitPush(pushFor(`eve-sim-${suffix}`, p2));
check("push delivered despite live ws", !!push2);
check("push badge stays 0 before accept", push2 && push2.body.aps.badge === 0,
  `badge=${push2?.body.aps.badge}`);

// read moves the badge: eve accepts the chat (message request), reads everything,
// and the next push arrives with badge=1
await api(`/api/chats/${echat.chatId}/accept`, { token: eve.token, body: {} });
ce.send({ t: "read", chatId: echat.chatId, upToSeq: p2.seq });
await ca2.waitFor((f) => f.t === "receipt" && f.kind === "read" && f.by === eve.userId);
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p3", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p3 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p3");
const push3 = await waitPush(pushFor(`eve-sim-${suffix}`, p3));
check("push badge after read", push3 && push3.body.aps.badge === 1,
  `badge=${push3?.body.aps.badge}`);
// badgeStamp is how the client tells a fresh counter from an older one that
// overtook it: UserDO issues the number and it strictly grows
check("badge stamps grow", push1 && push2 && push3
  && push1.body.badgeStamp < push2.body.badgeStamp
  && push2.body.badgeStamp < push3.body.badgeStamp,
  `${push1?.body.badgeStamp} ${push2?.body.badgeStamp} ${push3?.body.badgeStamp}`);

// (c) a service frame produces no push
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p4", sentAt: Date.now(),
  service: true, body: { v: 1, mode: "skd", c: "c2tk" } });
const p4 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p4");
check("no push for service", !(await waitPush(pushFor(`eve-sim-${suffix}`, p4), 1200)));

// (c0) a service frame flagged notify (a missed-call record) does push, and
// still does not grow the badge
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p4n", sentAt: Date.now(),
  service: true, notify: true, body: { v: 1, mode: "pw", msgs: {} } });
const p4n = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p4n");
const push4n = await waitPush(pushFor(`eve-sim-${suffix}`, p4n));
check("notify service frame pushes", !!push4n);
check("notify service frame keeps the badge", push4n?.body.aps.badge === 1,
  `badge=${push4n?.body.aps.badge}`);
check("notify frame travels service on ws", !!(await ce.waitFor((f) =>
  f.t === "msg" && f.seq === p4n.seq && f.service === true)));

// (c1) A service frame takes a seq but does not grow the badge: in a read chat the read
// mark absorbs it, exactly the way the client moves the cursor. The server counts the
// badge, so these two counts must not diverge.
ce.send({ t: "read", chatId: echat.chatId, upToSeq: p4.seq });
await ca2.waitFor((f) => f.t === "receipt" && f.kind === "read"
  && f.by === eve.userId && f.upToSeq === p4.seq);
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-svc-1", sentAt: Date.now(),
  service: true, body: { v: 1, mode: "skd", c: "c2tk" } });
await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-svc-1");
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-svc-2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const psvc = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-svc-2");
const pushSvc = await waitPush(pushFor(`eve-sim-${suffix}`, psvc));
check("service frame does not grow the badge", pushSvc?.body.aps.badge === 1,
  `badge=${pushSvc?.body.aps.badge}`);

// (c1a) The same frame in a chat that is *not* read to the end. The badge counts
// what the reader will be shown, and a service frame is never shown: an edit, a
// reaction or the sender key handed out after a membership change must leave the
// number where it is. A group is where this shows up most, because every change
// of the roster hands the key out again.
{
  const nils = await api("/api/register", { body: {
    username: "nils_" + suffix, displayName: "Nils", ...fakeKeys("x") } });
  const olga = await api("/api/register", { body: {
    username: "olga_" + suffix, displayName: "Olga", ...fakeKeys("y") } });
  const piet = await api("/api/register", { body: {
    username: "piet_" + suffix, displayName: "Piet", ...fakeKeys("z") } });
  await api("/api/push-token", { token: olga.token,
    body: { apnsToken: `olga-sim-${suffix}`, env: "development" } });
  const gchat = await api("/api/chats", { token: nils.token,
    body: { kind: "group", title: "Counting", memberIds: [olga.userId, piet.userId] } });
  check("unread group created", gchat.ok, JSON.stringify(gchat));
  const cni = new Client("nils", nils.token);
  await cni.connect();
  const gsend = async (id, service) => {
    cni.send({ t: "send", chatId: gchat.chatId, clientMsgId: id, sentAt: Date.now(),
      body: { v: 1, mode: "sk", msgs: {} }, ...(service ? { service: true } : {}) });
    return cni.waitFor((f) => f.t === "sent" && f.clientMsgId === id);
  };

  const u1 = await gsend("cm-u1");
  const badge1 = (await waitPush(pushFor(`olga-sim-${suffix}`, u1)))?.body.aps.badge;
  check("group badge counts the first message", badge1 === 1, `badge=${badge1}`);

  // nothing is read here: this is where the number used to grow on its own
  const s1 = await gsend("cm-u2", true);
  check("no push for the group's service frame",
    !(await waitPush(pushFor(`olga-sim-${suffix}`, s1), 1500)));

  const u3 = await gsend("cm-u3");
  const badge2 = (await waitPush(pushFor(`olga-sim-${suffix}`, u3)))?.body.aps.badge;
  check("a service frame does not grow an unread badge", badge2 === 2, `badge=${badge2}`);

  // being added to a group raises its own push, with the group's title in the
  // clear and no envelope for the extension to decrypt
  const quinn = await api("/api/register", { body: {
    username: "quinn_" + suffix, displayName: "Quinn", ...fakeKeys("q") } });
  await api("/api/push-token", { token: quinn.token,
    body: { apnsToken: `quinn-sim-${suffix}`, env: "development" } });
  const added = await api(`/api/chats/${gchat.chatId}/members`, { token: nils.token,
    body: { add: [quinn.userId], remove: [] } });
  check("group add ok", added.ok, JSON.stringify(added));
  const addPush = await waitPush((p) =>
    p.url === `/3/device/quinn-sim-${suffix}` && p.body.chatId === gchat.chatId);
  check("push on being added to a group", !!addPush, JSON.stringify(pushes.slice(-3)));
  if (addPush) {
    check("group-add push names the group",
      addPush.body.aps.alert.body === "Вас добавили в «Counting»",
      JSON.stringify(addPush.body.aps.alert));
    // an informational push carries nothing to decrypt
    check("group-add push has no envelope",
      addPush.body.env === undefined && addPush.body.aps["mutable-content"] === undefined,
      JSON.stringify(addPush.body));
  }
  // adding someone already in the group is a no-op and raises no push
  const readd = await api(`/api/chats/${gchat.chatId}/members`, { token: nils.token,
    body: { add: [olga.userId], remove: [] } });
  check("re-add is a no-op with no push", readd.ok
    && !(await waitPush((p) => p.url === `/3/device/olga-sim-${suffix}`
      && p.body.aps?.alert?.body?.startsWith("Вас добавили"), 1200)));

  // The push's sound: the chat's own choice wins, then the user's default for
  // the chat's shape, then "default". Both are resolved by the receiver's
  // object, so a sender changes nothing about them.
  await api("/api/notify-sounds", { token: olga.token, body: { group: "chime2.caf" } });
  const s2 = await gsend("cm-snd1");
  const sndPush1 = await waitPush(pushFor(`olga-sim-${suffix}`, s2));
  check("group default sound rides the push",
    sndPush1?.body.aps.sound === "chime2.caf", JSON.stringify(sndPush1?.body.aps));
  await api(`/api/chats/${gchat.chatId}/flags`, { token: olga.token,
    body: { sound: "chime1.caf" } });
  const s3 = await gsend("cm-snd2");
  const sndPush2 = await waitPush(pushFor(`olga-sim-${suffix}`, s3));
  check("the chat's own sound beats the default",
    sndPush2?.body.aps.sound === "chime1.caf", JSON.stringify(sndPush2?.body.aps));
  await api(`/api/chats/${gchat.chatId}/flags`, { token: olga.token, body: { sound: null } });
  await api("/api/notify-sounds", { token: olga.token, body: { group: null } });
  const s4 = await gsend("cm-snd3");
  const sndPush3 = await waitPush(pushFor(`olga-sim-${suffix}`, s4));
  check("clearing both returns the push to default",
    sndPush3?.body.aps.sound === "default", JSON.stringify(sndPush3?.body.aps));
  // the sender's personal sound follows them into any chat, under the chat's own
  await api(`/api/notify-sounds/person/${nils.userId}`, { token: olga.token,
    body: { sound: "chime3.caf" } });
  const s5 = await gsend("cm-snd4");
  const sndPush4 = await waitPush(pushFor(`olga-sim-${suffix}`, s5));
  check("a person's sound rides their message",
    sndPush4?.body.aps.sound === "chime3.caf", JSON.stringify(sndPush4?.body.aps));
  await api(`/api/chats/${gchat.chatId}/flags`, { token: olga.token,
    body: { sound: "chime2.caf" } });
  const s6 = await gsend("cm-snd5");
  const sndPush5 = await waitPush(pushFor(`olga-sim-${suffix}`, s6));
  check("the chat's explicit sound still wins over the person's",
    sndPush5?.body.aps.sound === "chime2.caf", JSON.stringify(sndPush5?.body.aps));
  // a silent choice: the push carries no sound field at all, so the system
  // posts the banner without playing anything
  await api(`/api/chats/${gchat.chatId}/flags`, { token: olga.token, body: { sound: "none" } });
  const s7 = await gsend("cm-snd6");
  const sndPush6 = await waitPush(pushFor(`olga-sim-${suffix}`, s7));
  check("a silent chat pushes with no sound field",
    sndPush6 !== undefined && !("sound" in sndPush6.body.aps),
    JSON.stringify(sndPush6?.body.aps));
  await api(`/api/chats/${gchat.chatId}/flags`, { token: olga.token,
    body: { sound: "chime2.caf" } });
  // with the chat and the person both set, the exceptions list names them both
  const exc = await api("/api/notify-sounds/exceptions", { token: olga.token });
  check("exceptions list the chat's sound",
    exc.chats?.some((e) => e.chatId === gchat.chatId && e.sound === "chime2.caf"),
    JSON.stringify(exc.chats));
  check("exceptions list the person's sound",
    exc.people?.some((e) => e.userId === nils.userId && e.sound === "chime3.caf"),
    JSON.stringify(exc.people));
  await api(`/api/chats/${gchat.chatId}/flags`, { token: olga.token, body: { sound: null } });
  await api(`/api/notify-sounds/person/${nils.userId}`, { token: olga.token,
    body: { sound: null } });
  // clearing both empties the list again
  const exc2 = await api("/api/notify-sounds/exceptions", { token: olga.token });
  check("cleared sounds leave the exceptions list",
    !exc2.chats?.some((e) => e.chatId === gchat.chatId)
      && !exc2.people?.some((e) => e.userId === nils.userId),
    JSON.stringify(exc2));
  cni.ws.close();
}

// (c2) The push carries the message itself, addressed to the device it goes to:
// the extension decrypts it and writes it, so a chat opened offline holds what
// the banner said. A pairwise envelope is trimmed to this device's own box.
const eveAddr = `${eve.userId}/${eve.deviceId}`;
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p8", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {
    [eveAddr]: { type: "dr", c: "Zm9yLWV2ZQ==" },
    "someone/else": { type: "dr", c: "Zm9yLXNvbWVvbmUtZWxzZQ==" },
  } } });
const p8 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p8");
const push8 = await waitPush(pushFor(`eve-sim-${suffix}`, p8));
check("push carries the envelope", !!push8?.body.env, JSON.stringify(push8?.body));
if (push8?.body.env) {
  const env = JSON.parse(push8.body.env);
  check("envelope trimmed to this device",
    Object.keys(env.msgs ?? {}).join() === eveAddr, JSON.stringify(env.msgs));
  check("push carries the sender", push8.body.from === alice.userId
    && typeof push8.body.fromDevice === "string" && typeof push8.body.ts === "number",
    JSON.stringify({ from: push8.body.from, fromDevice: push8.body.fromDevice }));
}

// (c3) APNs takes no more than four kilobytes: the envelope is dropped and the
// rest still arrives, the message itself comes with the next connection
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p9", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: { [eveAddr]: { type: "dr", c: "A".repeat(5000) } } } });
const p9 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p9");
const push9 = await waitPush(pushFor(`eve-sim-${suffix}`, p9));
check("oversized envelope is dropped from the push",
  !!push9 && push9.body.env === undefined);

// (d) a muted chat produces no push
await api(`/api/chats/${echat.chatId}/flags`, { token: eve.token, body: { muted: true } });
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p5", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p5 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p5");
check("no push for muted chat", !(await waitPush(pushFor(`eve-sim-${suffix}`, p5), 1200)));

// (e) mute with an expiry: no push while it has not expired
const nowS = Math.floor(Date.now() / 1000);
await api(`/api/chats/${echat.chatId}/flags`, { token: eve.token,
  body: { muted: true, mutedUntil: nowS + 3600 } });
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p6", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p6 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p6");
check("no push while mute not expired", !(await waitPush(pushFor(`eve-sim-${suffix}`, p6), 1200)));

// (f) once it has expired the push goes out and the flag clears itself
await api(`/api/chats/${echat.chatId}/flags`, { token: eve.token,
  body: { muted: true, mutedUntil: nowS - 1 } });
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p7", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p7 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p7");
check("push after mute expired", !!(await waitPush(pushFor(`eve-sim-${suffix}`, p7))));
const eveChats = await api("/api/chats", { token: eve.token });
const eveEntry = eveChats.chats.find((e) => e.state.chatId === echat.chatId);
check("expired mute cleared in flags",
  !!eveEntry && eveEntry.flags.muted === false && eveEntry.flags.mutedUntil === undefined,
  JSON.stringify(eveEntry?.flags));

// (g) own echo: alice has a token registered, yet her own sends create no push
check("no push for own echo", !pushes.some((p) => p.url === `/3/device/alice-sim-${suffix}`),
  JSON.stringify(pushes.filter((p) => p.url === `/3/device/alice-sim-${suffix}`).map((p) => p.body)));

// (d) The server counts the badge, and the author does not count what they sent as
// unread, exactly as the cursor on the device does. Otherwise the number would grow on
// what the author wrote themselves.
ce.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-e1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const e1 = await ce.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-e1");
check("author's badge counts the peer's message",
  (await waitPush(pushFor(`alice-sim-${suffix}`, e1)))?.body.aps.badge === 1);
for (const id of ["cm-p11", "cm-p12", "cm-p13"]) {
  ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: id, sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === id);
}
ce.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-e2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const e2 = await ce.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-e2");
const badgeAfter = (await waitPush(pushFor(`alice-sim-${suffix}`, e2)))?.body.aps.badge;
check("own messages do not grow the author's badge", badgeAfter === 1,
  `badge=${badgeAfter}`);

// (h) Saved messages: a chat with yourself, one per user, never a push
const selfChat = await api("/api/chats", { token: alice.token, body: { kind: "self", memberIds: [] } });
check("self chat created", selfChat.ok && selfChat.chatId === "self:" + alice.userId,
  JSON.stringify(selfChat));
const selfAgain = await api("/api/chats", { token: alice.token, body: { kind: "self", memberIds: [] } });
check("self chat is one per user", selfAgain.ok && selfAgain.chatId === selfChat.chatId);
const pushMarkSelf = pushes.length;
ca2.send({ t: "send", chatId: selfChat.chatId, clientMsgId: "cm-self1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const selfSent = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-self1");
check("send to yourself gets a seq", !!selfSent);
await new Promise((r) => setTimeout(r, 600));
check("saved messages raise no push",
  !pushes.slice(pushMarkSelf).some((p) => p.url === `/3/device/alice-sim-${suffix}`));
const selfEntry = (await api("/api/chats", { token: alice.token }))
  .chats.find((x) => x.state.chatId === selfChat.chatId);
check("self chat lists its one member",
  selfEntry?.state.kind === "self" && selfEntry.state.members.length === 1);

// 21. The sender's confirmation does not wait for APNs: with the mock's answer
// held for 1500 ms, the ack still lands next to the push's arrival instead of
// after the hold. The push queue runs independently of the ack path, so the
// two arrivals have no strict order — only the absence of the hold-sized lag
// is the product's promise.
hold = { token: `eve-sim-${suffix}`, ms: 1500 };
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-h1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const h1 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-h1");
const hp1 = await waitPush(pushFor(`eve-sim-${suffix}`, h1));
check("ack does not wait for apns", !!h1 && !!hp1 && h1.at - hp1.at < 1000,
  `ack ${h1?.at} push ${hp1?.at}`);

// the previous message's push is still hanging, the next ack arrives right away anyway
const holdT0 = Date.now();
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-h2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const h2 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-h2", 3000);
check("ack while apns still hanging", !!h2 && h2.at - holdT0 < 600,
  `${h2 ? h2.at - holdT0 : "no ack"}ms`);
const hp2 = await waitPush(pushFor(`eve-sim-${suffix}`, h2), 8000);
check("push follows its ack", !!hp2 && h2.at < hp2.at, `ack ${h2?.at} push ${hp2?.at}`);
hold = { token: null, ms: 0 };

// 23. Reading the APNs answer: 410 drops the token, 429 is retried
const jack = await api("/api/register", { body: {
  username: "jack_" + suffix, displayName: "Jack", ...fakeKeys("j") } });
await api("/api/push-token", { token: jack.token,
  body: { apnsToken: "dead-token", env: "development" } });
const jchat = await api("/api/chats", { token: alice.token,
  body: { kind: "direct", memberIds: [jack.userId] } });
ca2.send({ t: "send", chatId: jchat.chatId, clientMsgId: "cm-dead1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const d1 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-dead1");
check("dead token: push attempted", !!(await waitPush(pushFor("dead-token", d1))));

await new Promise((r) => setTimeout(r, 600));
const jackSess = await api("/api/sessions", { token: jack.token });
check("dead token: dropped from d1",
  jackSess.ok && jackSess.sessions[0].hasPushToken === false, JSON.stringify(jackSess));

ca2.send({ t: "send", chatId: jchat.chatId, clientMsgId: "cm-dead2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const d2 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-dead2");
check("dead token: no push after drop",
  !(await waitPush(pushFor("dead-token", d2), 1500)));

const kate = await api("/api/register", { body: {
  username: "kate_" + suffix, displayName: "Kate", ...fakeKeys("k") } });
await api("/api/push-token", { token: kate.token,
  body: { apnsToken: "flaky-token", env: "development" } });
const kchat = await api("/api/chats", { token: alice.token,
  body: { kind: "direct", memberIds: [kate.userId] } });
ca2.send({ t: "send", chatId: kchat.chatId, clientMsgId: "cm-flaky", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const fk = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-flaky");
await new Promise((r) => setTimeout(r, 2500));
const flakyTries = pushes.filter((p) =>
  p.url === "/3/device/flaky-token" && p.body.chatId === kchat.chatId && p.body.seq === fk.seq);
check("429 retried once and succeeded", flakyTries.length === 2, `tries=${flakyTries.length}`);
const kateSess = await api("/api/sessions", { token: kate.token });
check("retried token kept", kateSess.sessions[0].hasPushToken === true);


pushSrv.close();

// 22. Fanout: one recipient failing does not break delivery to the rest
const mallory = await api("/api/register", { body: {
  username: "mallory_" + suffix, displayName: "Mallory", ...fakeKeys("m") } });
const trent = await api("/api/register", { body: {
  username: "trent_" + suffix, displayName: "Trent", ...fakeKeys("t") } });
const fgrp = await api("/api/chats", { token: alice.token,
  body: { kind: "group", memberIds: [mallory.userId, trent.userId], title: "Fanout" } });
check("create fanout group", fgrp.ok, JSON.stringify(fgrp));

const cmal = new Client("mallory", mallory.token);
const ctre = new Client("trent", trent.token);
await cmal.connect(); await ctre.connect();
// let the presence frames go out so they do not eat the fault counter
await new Promise((r) => setTimeout(r, 600));

const sendTo = (clientMsgId) => ca2.send({ t: "send", chatId: fgrp.chatId, clientMsgId,
  sentAt: Date.now(), body: { v: 1, mode: "skm", c: "Zg" } });
const fault = (n) => api("/api/dev/fault", { token: mallory.token, body: { failEvents: n } });

const armed = await fault(1);
check("dev fault armed", armed.ok && armed.failEvents === 1, JSON.stringify(armed));
sendTo("cm-f1");
const f1 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-f1");
check("sender acked while recipient fails", !!f1);
check("healthy recipient unaffected",
  !!(await ctre.waitFor((f) => f.t === "msg" && f.chatId === f1.chatId && f.seq === f1.seq)));
check("failed recipient gets retry",
  !!(await cmal.waitFor((f) => f.t === "msg" && f.chatId === f1.chatId && f.seq === f1.seq, 4000)));

// typing is not retried: it goes stale faster than a retry would arrive
await fault(1);
ca2.send({ t: "typing", chatId: fgrp.chatId, kind: "text" });
check("typing reaches healthy recipient",
  !!(await ctre.waitFor((f) => f.t === "typing" && f.chatId === fgrp.chatId)));
await new Promise((r) => setTimeout(r, 2000));
check("typing not retried", !cmal.frames.some((f) => f.t === "typing" && f.chatId === fgrp.chatId));

// a recipient broken for good: the queue gives up on it and keeps working
await fault(99);
sendTo("cm-f2");
const f2 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-f2");
check("delivery survives a broken recipient",
  !!(await ctre.waitFor((f) => f.t === "msg" && f.chatId === f2.chatId && f.seq === f2.seq, 8000)));
sendTo("cm-f3");
const f3 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-f3");
check("queue keeps moving after dropped recipient",
  !!(await ctre.waitFor((f) => f.t === "msg" && f.chatId === f3.chatId && f.seq === f3.seq, 8000)));
await fault(0);

// 23. Fanout queue: a burst is queued and replayed to the end
async function fanoutState() {
  return api(`/api/chats/${fgrp.chatId}/fanout`, { token: alice.token });
}
await fault(2); // the head job gets stuck for two retries
const Q = 6;
for (let i = 0; i < Q; i++) sendTo(`cm-q${i}`);
// the ack comes only after the fanout has been queued: without this wait the
// queue state would be asked for before the first job appears in it
await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === `cm-q${Q - 1}`);
const qState = await fanoutState();
check("fanout is queued, not inline", qState.ok && qState.pending > 0, JSON.stringify(qState));
check("a queued job reports its wait", typeof qState.oldestMs === "number", JSON.stringify(qState));

const qLast = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === `cm-q${Q - 1}`, 10000);
check("burst acked", !!qLast);
const qGotT = await ctre.waitFor((f) =>
  f.t === "msg" && f.chatId === qLast.chatId && f.seq === qLast.seq, 20000);
check("queue replays the whole burst", !!qGotT);
const qGotM = await cmal.waitFor((f) =>
  f.t === "msg" && f.chatId === qLast.chatId && f.seq === qLast.seq, 20000);
check("stalled recipient catches up after retries", !!qGotM);
const qSeqs = ctre.frames.filter((f) => f.t === "msg" && f.chatId === fgrp.chatId)
  .map((f) => f.seq);
check("queue keeps frame order", qSeqs.every((s, i) => i === 0 || s > qSeqs[i - 1]),
  JSON.stringify(qSeqs));

let drained = null;
for (let i = 0; i < 60; i++) {
  drained = await fanoutState();
  if (drained.ok && drained.pending === 0) break;
  await new Promise((r) => setTimeout(r, 250));
}
check("queue drains to empty",
  !!drained && drained.pending === 0 && drained.recipients === 0, JSON.stringify(drained));
check("drained queue reports no waiting job", drained?.oldestMs === null, JSON.stringify(drained));

const strangerQ = await api(`/api/chats/${fgrp.chatId}/fanout`, { token: bob.token });
check("fanout state hidden from non-member", !strangerQ.ok && strangerQ.error === "not_member");

// 23b. A burst with a second sender landing inside its drain: a job queued
// while the alarm is running has to be picked up by that drain. Whenever the
// queue holds jobs, a drain must be coming for them — a job left unarmed stops
// the chat without closing anyone's socket.
{
  const N = 120;
  const mark = ctre.mark();
  const markM = cmal.mark();
  for (let i = 0; i < N; i++) sendTo(`cm-b${i}`);
  setTimeout(() => ctre.send({
    t: "send", chatId: fgrp.chatId, clientMsgId: "cm-b-trailer", sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} },
  }), 5);
  // a stalled queue shows as the head job's age growing without bound; it is
  // read that way because `armed` is briefly false between the runtime taking
  // the alarm and the drain starting
  let oldest = 0;
  let st = null;
  for (let i = 0; i < 200; i++) {
    st = await fanoutState();
    oldest = Math.max(oldest, st.oldestMs ?? 0);
    if (st.pending === 0 && ctre.frames.slice(mark).filter((f) => f.t === "msg").length >= N + 1) break;
    await new Promise((r) => setTimeout(r, 50));
  }
  const gotT = ctre.frames.slice(mark).filter((f) => f.t === "msg" && f.chatId === fgrp.chatId).length;
  const gotM = cmal.frames.slice(markM).filter((f) => f.t === "msg" && f.chatId === fgrp.chatId).length;
  check("burst reaches every member", gotT >= N + 1 && gotM >= N + 1, `${gotT}/${gotM} of ${N + 1}`);
  check("burst leaves the queue empty", st?.pending === 0, JSON.stringify(st));
  check("no job waits out the burst", oldest < 5000, `oldest=${oldest}ms`);
}

// 24. Arming the fanout alarm: the queue is never left without one.
// A stored alarm time keeps its value after the alarm has fired, so a job
// queued around that moment used to see a pending alarm nobody was going to
// run, and stayed undelivered until the next send into the chat.
{
  const now = 1_000_000;
  check("arms when nothing is pending", shouldArmAlarm(null, now + 1, now));
  check("arms past an alarm due right now", shouldArmAlarm(now, now + 1, now));
  check("arms past an alarm that already fired", shouldArmAlarm(now - 5000, now + 1, now));
  check("skips an earlier alarm still ahead", !shouldArmAlarm(now + 1, now + 200, now));
  check("arms ahead of a later alarm", shouldArmAlarm(now + 500, now + 1, now));
}

// 25. Deleting a chat: the conversation leaves the deleter's list and stays with the peer
const dana = await api("/api/register", { body: {
  username: "dana_" + suffix, displayName: "Dana", ...fakeKeys("n") } });
const erik = await api("/api/register", { body: {
  username: "erik_" + suffix, displayName: "Erik", ...fakeKeys("r") } });
const dchat2 = await api("/api/chats", { token: dana.token,
  body: { kind: "direct", memberIds: [erik.userId] } });
const cd = new Client("dana", dana.token);
const cer = new Client("erik", erik.token);
await cd.connect(); await cer.connect();
await api(`/api/chats/${dchat2.chatId}/accept`, { token: erik.token, body: {} });
cd.send({ t: "send", chatId: dchat2.chatId, clientMsgId: "cm-d1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
await cd.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-d1");
await cer.waitFor((f) => f.t === "msg" && f.chatId === dchat2.chatId);

const delDirect = await api(`/api/chats/${dchat2.chatId}/delete`, { token: dana.token, body: {} });
check("direct chat deleted", delDirect.ok, JSON.stringify(delDirect));
const danaList = await api("/api/chats", { token: dana.token });
check("deleted chat leaves the deleter's list",
  !danaList.chats.some((c2) => c2.state.chatId === dchat2.chatId));
const erikList = await api("/api/chats", { token: erik.token });
const erikChat = erikList.chats.find((c2) => c2.state.chatId === dchat2.chatId);
check("peer keeps the chat and its journal", !!erikChat && erikChat.state.lastSeq === 1);
check("deleter's read mark is at the end of the journal",
  erikChat?.state.readMarks[dana.userId] === 1, JSON.stringify(erikChat?.state.readMarks));

// the peer writes again and the chat comes back
const cd2 = new Client("dana2", dana.token);
await cd2.connect();
cer.send({ t: "send", chatId: dchat2.chatId, clientMsgId: "cm-e1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const back = await cd2.waitFor((f) => f.t === "msg" && f.chatId === dchat2.chatId && f.seq === 2);
check("message into a deleted chat still reaches the deleter", !!back);
const danaList2 = await api("/api/chats", { token: dana.token });
check("chat comes back on the next message",
  danaList2.chats.some((c2) => c2.state.chatId === dchat2.chatId));

// the deleter opens the conversation again without waiting for a message
const delAgain = await api(`/api/chats/${dchat2.chatId}/delete`, { token: dana.token, body: {} });
check("direct chat deleted a second time", delAgain.ok, JSON.stringify(delAgain));
const reopen = await api("/api/chats", { token: dana.token,
  body: { kind: "direct", memberIds: [erik.userId] } });
check("reopening a deleted direct chat answers with the same chat",
  reopen.ok && reopen.chatId === dchat2.chatId, JSON.stringify(reopen));
const danaList3 = await api("/api/chats", { token: dana.token });
check("reopening puts the chat back into the deleter's list",
  danaList3.chats.some((c2) => c2.state.chatId === dchat2.chatId));
check("the journal it comes back with is the old one",
  danaList3.chats.find((c2) => c2.state.chatId === dchat2.chatId)?.state.lastSeq === 2);

// in a group, deleting means leaving
const dgrp = await api("/api/chats", { token: dana.token,
  body: { kind: "group", memberIds: [erik.userId], title: "Leave me" } });
const delGrp = await api(`/api/chats/${dgrp.chatId}/delete`, { token: dana.token, body: {} });
check("group delete leaves the group", delGrp.ok, JSON.stringify(delGrp));
const grpState = await api("/api/chats", { token: erik.token });
const leftGrp = grpState.chats.find((c2) => c2.state.chatId === dgrp.chatId);
check("the others see the member gone",
  !!leftGrp && !leftGrp.state.members.some((m) => m.userId === dana.userId));
const notMember = await api(`/api/chats/${dgrp.chatId}/delete`, { token: dana.token, body: {} });
check("deleting a chat you are not in is refused", !notMember.ok);
cd.ws.close(); cd2.ws.close(); cer.ws.close();

// 26. The delivery receipt over HTTP: what the notification extension sends
// when it writes a message from a push and the app has no socket up.
{
  const gina = await api("/api/register", { body: {
    username: "rita_" + suffix, displayName: "Rita", ...fakeKeys("u") } });
  const hugo = await api("/api/register", { body: {
    username: "sven_" + suffix, displayName: "Sven", ...fakeKeys("v") } });
  check("receipt pair registered", gina.ok && hugo.ok, JSON.stringify([gina, hugo]));
  const rchat = await api("/api/chats", { token: gina.token,
    body: { kind: "direct", memberIds: [hugo.userId] } });
  const cgi = new Client("gina", gina.token);
  await cgi.connect();
  await api(`/api/chats/${rchat.chatId}/accept`, { token: hugo.token, body: {} });
  cgi.send({ t: "send", chatId: rchat.chatId, clientMsgId: "cm-g1", sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  await cgi.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-g1");

  // Hugo never connects: the receipt is the only thing that arrives from him
  const rest = await api(`/api/chats/${rchat.chatId}/recv`, { token: hugo.token, body: { seqs: [1] } });
  check("rest recv accepted", rest.ok, JSON.stringify(rest));
  const restReceipt = await cgi.waitFor((f) => f.t === "receipt" && f.kind === "delivered");
  check("rest recv reaches the author",
    !!restReceipt && restReceipt.by === hugo.userId && restReceipt.upToSeq === 1,
    JSON.stringify(restReceipt));

  const again = await api(`/api/chats/${rchat.chatId}/recv`, { token: hugo.token, body: { seqs: [1] } });
  check("rest recv repeats without harm", again.ok);
  const emptySeqs = await api(`/api/chats/${rchat.chatId}/recv`, { token: hugo.token, body: { seqs: [] } });
  check("rest recv without seqs is refused", !emptySeqs.ok, JSON.stringify(emptySeqs));

  // a stranger holding the chat id marks nothing
  const nosy = await api("/api/register", { body: {
    username: "tess_" + suffix, displayName: "Tess", ...fakeKeys("w") } });
  await api(`/api/chats/${rchat.chatId}/recv`, { token: nosy.token, body: { seqs: [1] } });
  const rstate = await api("/api/chats", { token: gina.token });
  const rc = rstate.chats.find((c2) => c2.state.chatId === rchat.chatId);
  check("rest recv from a stranger marks nothing",
    rc?.state.deliveredMarks[nosy.userId] === undefined,
    JSON.stringify(rc?.state.deliveredMarks));
  check("rest recv marked the member", rc?.state.deliveredMarks[hugo.userId] === 1,
    JSON.stringify(rc?.state.deliveredMarks));
  cgi.ws.close();
}

// The idempotency window: a cmid record is swept once the sender's own
// delivered mark passes it, and only then. The stand runs with CMID_MIN_AGE=0
// and CMID_SWEEP_EVERY=0, so a sweep runs on every send; production ages the
// records for three days first.
{
  const ivan = await api("/api/register", { body: {
    username: "ivan_" + suffix, displayName: "Ivan", ...fakeKeys("y") } });
  const jane = await api("/api/register", { body: {
    username: "jane_" + suffix, displayName: "Jane", ...fakeKeys("z") } });
  const schat = await api("/api/chats", { token: ivan.token,
    body: { kind: "direct", memberIds: [jane.userId] } });
  const civ = new Client("ivan", ivan.token);
  await civ.connect();
  civ.send({ t: "send", chatId: schat.chatId, clientMsgId: "cm-w1", sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  const w1 = await civ.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-w1");

  // not acked by the sender yet: the record survives any number of sweeps
  civ.send({ t: "send", chatId: schat.chatId, clientMsgId: "cm-w2", sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  await civ.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-w2");
  civ.send({ t: "send", chatId: schat.chatId, clientMsgId: "cm-w1", sentAt: Date.now(), body: {} });
  const w1again = await civ.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-w1" && f !== w1);
  check("cmid survives sweeps until the sender acks", w1again.seq === w1.seq,
    JSON.stringify(w1again));

  // acked: the next send sweeps it, and a late resend lands as a fresh message
  civ.send({ t: "recv", chatId: schat.chatId, seqs: [w1.seq] });
  await new Promise((r) => setTimeout(r, 200));
  civ.send({ t: "send", chatId: schat.chatId, clientMsgId: "cm-w3", sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  await civ.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-w3");
  civ.send({ t: "send", chatId: schat.chatId, clientMsgId: "cm-w1", sentAt: Date.now(), body: {} });
  const w1fresh = await civ.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-w1"
    && f.seq !== w1.seq);
  check("cmid swept behind the sender's ack", !!w1fresh && w1fresh.seq > w1.seq,
    JSON.stringify(w1fresh));
  civ.ws.close();
}

{
  // --- restoring from a backup after the last device logged out ---
  // The account identity outlives its devices in the user's object: revoking
  // every device must leave /api/restore/start something to verify against.
  const ed = await import("@noble/ed25519");
  const priv = ed.utils.randomSecretKey();
  const pub = await ed.getPublicKeyAsync(priv);
  const b64url = (bytes) => Buffer.from(bytes).toString("base64url");
  const keys = fakeKeys("rst");
  keys.identitySignKey = b64url(pub);
  const username = "rst" + (Date.now() % 1e8);
  const reg = await api("/api/register", { body: {
    username, displayName: "Restore Me", ...keys,
  } });
  check("restore: registered", reg.ok, JSON.stringify(reg));
  const out = await api("/api/logout", { token: reg.token, body: {} });
  check("restore: logout of the only device", out.ok, JSON.stringify(out));

  const start = await api("/api/restore/start", { body: { username } });
  check("restore: start with zero devices", start.ok && !!start.nonce, JSON.stringify(start));
  const signature = b64url(await ed.signAsync(new TextEncoder().encode(start.nonce), priv));
  const claim = await api(`/api/restore/${start.restoreId}/claim`, { body: {
    ...keys, signature, device: { name: "restored" },
  } });
  check("restore: claim adds a device back", claim.ok && !!claim.token, JSON.stringify(claim));
  const sessions = await api("/api/sessions", { token: claim.token });
  check("restore: the restored device authenticates",
    sessions.ok && sessions.sessions.length === 1 && sessions.sessions[0].name === "restored",
    JSON.stringify(sessions));
}

{
  // --- deleting the account whole ---
  const gone = "gone" + (Date.now() % 1e8);
  const doomed = await api("/api/register", { body: {
    username: gone, displayName: "Doomed", ...fakeKeys("dm") } });
  check("delete: registered", doomed.ok, JSON.stringify(doomed));
  const dg = await api("/api/chats", { token: alice.token, method: "POST", body: {
    kind: "group", title: "Doomed group", members: [doomed.userId] } });
  check("delete: sits in a group", dg.ok, JSON.stringify(dg));
  const del = await api("/api/account/delete", { token: doomed.token, body: {} });
  check("account delete ok", del.ok, JSON.stringify(del));
  const after = await api("/api/me", { token: doomed.token });
  check("deleted token rejected", after.error === "unauthorized", JSON.stringify(after));
  const lst = await api("/api/chats", { token: alice.token });
  const doomedGroup = (lst.chats ?? []).find((ch) => ch.state?.chatId === dg.chatId);
  check("deleted user left the group",
    !!doomedGroup && doomedGroup.state.members.every((m) => m.userId !== doomed.userId),
    JSON.stringify(doomedGroup?.state?.members));
  const roster = await api(`/api/users?q=${gone}`, { token: alice.token });
  check("deleted user not found by search",
    (roster.users ?? []).every((u) => u.username !== gone), JSON.stringify(roster.users));
  const again = await api("/api/register", { body: {
    username: gone, displayName: "Reborn", ...fakeKeys("rb") } });
  check("the freed handle registers again", again.ok, JSON.stringify(again));
}

{
  // --- deferred send: the envelope waits on the server and leaves on time ---
  const due = Date.now() + 1500;
  ca.send({ t: "defer", chatId: chat.chatId, clientMsgId: "cm-def1", sentAt: Date.now(),
    dueAt: due, body: { v: 1, mode: "pw", msgs: {} } });
  const ack = await ca.waitFor((f) => f.t === "deferred" && f.clientMsgId === "cm-def1");
  check("defer acked with its deadline", !!ack && ack.dueAt === due, JSON.stringify(ack));
  const early = await cb2.waitFor((f) => f.t === "msg" && f.chatId === chat.chatId
    && f.from === alice.userId && f.sentAt >= due - 2000 && Date.now() < due - 300, 700);
  check("deferred envelope is not journaled early", !early, JSON.stringify(early));
  const landed = await cb2.waitFor((f) => f.t === "msg" && f.chatId === chat.chatId
    && f.at >= due - 250 && f.from === alice.userId, 8000);
  check("deferred envelope arrives once due", !!landed, JSON.stringify(landed));
  const echoMark = ca.frames.findIndex((f) =>
    f.t === "msg" && f.chatId === chat.chatId && f.seq === landed?.seq);
  check("sender gets the echo of the deferred send", echoMark >= 0);
  // the echo names the outbox row it closes: an author offline at the deadline
  // finalizes from the journal instead of the sent ack
  check("msg echo carries the clientMsgId",
    ca.frames[echoMark]?.clientMsgId === "cm-def1", JSON.stringify(ca.frames[echoMark]));

  // a reschedule replaces the envelope in place; a cancel removes it
  ca.send({ t: "defer", chatId: chat.chatId, clientMsgId: "cm-def2", sentAt: Date.now(),
    dueAt: Date.now() + 60_000, body: { v: 1, mode: "pw", msgs: {} } });
  await ca.waitFor((f) => f.t === "deferred" && f.clientMsgId === "cm-def2");
  const soon = Date.now() + 1500;
  ca.send({ t: "defer", chatId: chat.chatId, clientMsgId: "cm-def2", sentAt: Date.now(),
    dueAt: soon, body: { v: 1, mode: "pw", msgs: {} } });
  const moved = await ca.waitFor((f) => f.t === "deferred" && f.clientMsgId === "cm-def2"
    && f.dueAt === soon);
  check("reschedule replaces the deadline", !!moved, JSON.stringify(moved));
  const landed2 = await cb2.waitFor((f) => f.t === "msg" && f.chatId === chat.chatId
    && f.at >= soon - 250 && f.seq > (landed?.seq ?? 0), 8000);
  check("rescheduled envelope leaves at the new time", !!landed2, JSON.stringify(landed2));

  ca.send({ t: "defer", chatId: chat.chatId, clientMsgId: "cm-def3", sentAt: Date.now(),
    dueAt: Date.now() + 1200, body: { v: 1, mode: "pw", msgs: {} } });
  await ca.waitFor((f) => f.t === "deferred" && f.clientMsgId === "cm-def3");
  ca.send({ t: "deferCancel", chatId: chat.chatId, clientMsgId: "cm-def3" });
  const cancelled = await cb2.waitFor((f) => f.t === "msg" && f.chatId === chat.chatId
    && f.seq > (landed2?.seq ?? 0) && f.from === alice.userId, 2500);
  check("a cancelled deferred send never leaves", !cancelled, JSON.stringify(cancelled));
}

// --- channels: plaintext posts, roles, history for a late subscriber, search
{
  const plain = (kind, text) => ({ v: 1, mode: "plain", p: { kind, text } });
  const chan = await api("/api/chats", { token: alice.token,
    body: { kind: "channel", memberIds: [], title: `Chan ${suffix}` } });
  check("a channel is created", !!chan.chatId, JSON.stringify(chan));
  const noTitle = await apiRaw("/api/chats", { token: alice.token,
    body: { kind: "channel", memberIds: [], title: "  " } });
  check("a channel without a title is refused", noTitle.status === 400,
    String(noTitle.status));

  const cch = new Client("chan-alice", alice.token);
  await cch.connect();
  await cch.waitFor((f) => f.t === "hello");
  cch.send({ t: "send", chatId: chan.chatId, clientMsgId: "ch-1", sentAt: Date.now(),
    body: plain("text", "first post about otters") });
  const post1 = await cch.waitFor((f) => f.t === "sent" && f.clientMsgId === "ch-1");
  check("the owner posts to the channel", !!post1, JSON.stringify(post1));
  cch.send({ t: "send", chatId: chan.chatId, clientMsgId: "ch-2", sentAt: Date.now(),
    body: plain("text", "second post about badgers") });
  await cch.waitFor((f) => f.t === "sent" && f.clientMsgId === "ch-2");

  // a reader arrives by the invite link and gets everything posted before them
  const inv = await api(`/api/chats/${chan.chatId}/invite`, { token: alice.token, body: {} });
  const joined = await api(`/api/join/${inv.code}`, { token: bob.token, body: {} });
  check("a reader joins a channel by its link", joined.chatId === chan.chatId,
    JSON.stringify(joined));
  const hist = await api(`/api/chats/${chan.chatId}/history?fromSeq=0`, { token: bob.token });
  check("a late subscriber reads the whole history", hist.msgs?.length === 2,
    JSON.stringify(hist.msgs?.length));
  check("the post is plaintext on the server",
    hist.msgs?.[0]?.body?.p?.text === "first post about otters",
    JSON.stringify(hist.msgs?.[0]?.body));

  // a reader may comment and react, and may not post
  const cbr = new Client("chan-bob", bob.token);
  await cbr.connect();
  await cbr.waitFor((f) => f.t === "hello");
  cbr.send({ t: "send", chatId: chan.chatId, clientMsgId: "ch-r1", sentAt: Date.now(),
    body: plain("text", "readers cannot post") });
  const refused = await cbr.waitFor((f) => f.t === "error" && f.clientMsgId === "ch-r1");
  check("a reader cannot post to a channel", refused?.error === "not_allowed",
    JSON.stringify(refused));
  cbr.send({ t: "send", chatId: chan.chatId, clientMsgId: "ch-r2", sentAt: Date.now(),
    body: { v: 1, mode: "plain", p: { kind: "comment", text: "nice otters", targetSeq: post1.seq } } });
  const comment = await cbr.waitFor((f) => f.t === "sent" && f.clientMsgId === "ch-r2");
  check("a reader comments under a post", !!comment, JSON.stringify(comment));
  cbr.send({ t: "send", chatId: chan.chatId, clientMsgId: "ch-r3", sentAt: Date.now(),
    body: { v: 1, mode: "plain", p: { kind: "reaction", emoji: "👍", targetSeq: post1.seq } },
    service: true });
  check("a reader reacts to a post",
    !!(await cbr.waitFor((f) => f.t === "sent" && f.clientMsgId === "ch-r3")));

  // the owner hands out the right to post and takes it back
  const promoted = await api(`/api/chats/${chan.chatId}/roles`, { token: alice.token,
    body: { userId: bob.userId, role: "editor" } });
  check("the owner makes a reader an editor", promoted.ok === true, JSON.stringify(promoted));
  cbr.send({ t: "send", chatId: chan.chatId, clientMsgId: "ch-r4", sentAt: Date.now(),
    body: plain("text", "an editor posts") });
  check("an editor posts to the channel",
    !!(await cbr.waitFor((f) => f.t === "sent" && f.clientMsgId === "ch-r4")));
  const notOwner = await apiRaw(`/api/chats/${chan.chatId}/roles`, { token: bob.token,
    body: { userId: alice.userId, role: "reader" } });
  check("an editor cannot change roles", notOwner.status === 403, String(notOwner.status));
  await api(`/api/chats/${chan.chatId}/roles`, { token: alice.token,
    body: { userId: bob.userId, role: "reader" } });
  cbr.send({ t: "send", chatId: chan.chatId, clientMsgId: "ch-r5", sentAt: Date.now(),
    body: plain("text", "demoted again") });
  check("a demoted editor cannot post",
    (await cbr.waitFor((f) => f.t === "error" && f.clientMsgId === "ch-r5"))?.error === "not_allowed");

  // the server searches what it can read
  const hits = await api(`/api/chats/${chan.chatId}/search?q=badgers`, { token: bob.token });
  check("the server searches a channel's history", hits.hits?.length === 1,
    JSON.stringify(hits.hits));
  check("the hit names its post", hits.hits?.[0]?.text === "second post about badgers",
    JSON.stringify(hits.hits?.[0]));
  const none = await api(`/api/chats/${chan.chatId}/search?q=elephants`, { token: bob.token });
  check("a search with no match answers empty", none.hits?.length === 0, JSON.stringify(none));
  const notChannel = await apiRaw(`/api/chats/${chat.chatId}/search?q=hi`, { token: alice.token });
  check("an encrypted chat is not searched on the server", notChannel.status === 400,
    String(notChannel.status));
  const outsider = await apiRaw(`/api/chats/${chan.chatId}/search?q=otters`, { token: carol.token });
  check("a non-subscriber cannot search a channel", outsider.status === 403,
    String(outsider.status));
  cch.ws.close(); cbr.ws.close();
}

// --- bots: an account with a token and no keys, and the chat it makes readable
{
  const plain = (kind, extra = {}) => ({ v: 1, mode: "plain", p: { kind, ...extra } });
  const bot = await api("/api/bots", { token: alice.token, body: {
    username: `helper_${suffix}`, displayName: "Helper",
    commands: [{ command: "start", description: "start over" },
               { command: "help", description: "what I can do" }],
  } });
  check("a bot is created", !!bot.botId && !!bot.token, JSON.stringify(bot));
  const badCmd = await apiRaw("/api/bots", { token: alice.token, body: {
    username: `bad_${suffix}`, displayName: "Bad", commands: [{ command: "Not A Command" }],
  } });
  check("a command that is not a word is refused", badCmd.status === 400, String(badCmd.status));
  const mine = await api("/api/bots", { token: alice.token });
  check("the owner lists their bots", mine.bots?.some((b) => b.id === bot.botId),
    JSON.stringify(mine.bots?.length));
  const notMine = await api("/api/bots", { token: bob.token });
  check("someone else's bots are not listed", !notMine.bots?.length, JSON.stringify(notMine));
  const notOwner = await apiRaw(`/api/bots/${bot.botId}`, { token: bob.token,
    body: { displayName: "Stolen" } });
  check("only the owner edits a bot", notOwner.status === 403, String(notOwner.status));

  // the bot's card says what it is, and carries its commands
  const card = await api(`/api/users/${bot.botId}`, { token: bob.token });
  check("the card names the bot's owner", card.user?.bot_owner === alice.userId,
    JSON.stringify(card.user));
  check("the card carries the commands",
    JSON.parse(card.user?.bot_commands ?? "[]").length === 2, card.user?.bot_commands);

  // a chat with a bot is readable by design
  const botChat = await api("/api/chats", { token: bob.token,
    body: { kind: "direct", memberIds: [bot.botId] } });
  const snapshot = await api("/api/chats", { token: bob.token });
  const entry = snapshot.chats.find((e) => e.state.chatId === botChat.chatId);
  check("a chat with a bot is marked plaintext", entry?.state?.plaintext === true,
    JSON.stringify(entry?.state?.plaintext));
  const plainEntry = snapshot.chats.find((e) => e.state.chatId === chat.chatId);
  check("an ordinary chat is not", plainEntry?.state?.plaintext === false,
    JSON.stringify(plainEntry?.state?.plaintext));

  const cbot = new Client("bot", bot.token);
  await cbot.connect();
  await cbot.waitFor((f) => f.t === "hello");
  const cuser = new Client("bot-user", bob.token);
  await cuser.connect();
  await cuser.waitFor((f) => f.t === "hello");
  cuser.send({ t: "send", chatId: botChat.chatId, clientMsgId: "bot-1", sentAt: Date.now(),
    body: plain("text", { text: "/start" }) });
  const heard = await cbot.waitFor((f) => f.t === "msg" && f.chatId === botChat.chatId);
  check("the bot reads what is written to it", heard?.body?.p?.text === "/start",
    JSON.stringify(heard?.body));

  // the bot answers with buttons, and the button press comes back as a callback
  cbot.send({ t: "send", chatId: botChat.chatId, clientMsgId: "bot-2", sentAt: Date.now(),
    body: plain("text", { text: "pick one",
                          buttons: [[{ text: "Yes", data: "y" }, { text: "No", data: "n" }]] }) });
  const withButtons = await cuser.waitFor((f) => f.t === "msg" && f.from === bot.botId);
  check("the bot's message carries its buttons",
    withButtons?.body?.p?.buttons?.[0]?.[1]?.data === "n", JSON.stringify(withButtons?.body?.p));
  cuser.send({ t: "send", chatId: botChat.chatId, clientMsgId: "bot-3", sentAt: Date.now(),
    body: plain("callback", { data: "y" }), service: true });
  const pressed = await cbot.waitFor((f) => f.t === "msg" && f.body?.p?.kind === "callback");
  check("a pressed button reaches the bot", pressed?.body?.p?.data === "y",
    JSON.stringify(pressed?.body?.p));

  // a readable envelope has no business in an encrypted chat
  cuser.send({ t: "send", chatId: chat.chatId, clientMsgId: "bot-4", sentAt: Date.now(),
    body: plain("text", { text: "in the clear where it must not be" }) });
  const refused = await cuser.waitFor((f) => f.t === "error" && f.clientMsgId === "bot-4");
  check("a readable envelope is refused in an encrypted chat",
    refused?.error === "not_plaintext_chat", JSON.stringify(refused));

  // a bot in a group takes the encryption off what is written from then on
  const grp = await api("/api/chats", { token: alice.token,
    body: { kind: "group", memberIds: [bob.userId], title: `Bot group ${suffix}` } });
  const before = await api("/api/chats", { token: alice.token });
  check("a group without a bot is encrypted",
    before.chats.find((e) => e.state.chatId === grp.chatId)?.state?.plaintext === false);
  await api(`/api/chats/${grp.chatId}/members`, { token: alice.token,
    body: { add: [bot.botId], remove: [] } });
  const after = await api("/api/chats", { token: alice.token });
  check("a bot in the group takes the encryption off",
    after.chats.find((e) => e.state.chatId === grp.chatId)?.state?.plaintext === true);
  await api(`/api/chats/${grp.chatId}/members`, { token: alice.token,
    body: { add: [], remove: [bot.botId] } });
  const gone = await api("/api/chats", { token: alice.token });
  check("the bot leaving puts it back",
    gone.chats.find((e) => e.state.chatId === grp.chatId)?.state?.plaintext === false);

  const fresh = await api(`/api/bots/${bot.botId}`, { token: alice.token, body: { newToken: true } });
  check("the owner asks for a fresh token", !!fresh.token && fresh.token !== bot.token);
  const deadToken = await apiRaw("/api/me", { token: bot.token });
  check("the old token stops working", deadToken.status === 401, String(deadToken.status));
  cbot.ws.close(); cuser.ws.close();
}

// --- stories: an access rule instead of a key, and a page outside the app
{
  const upload = async (token, bytes) => {
    const r = await fetch(BASE + "/api/media", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/octet-stream" },
      body: bytes,
    });
    return (await r.json()).mediaId;
  };
  const photo = await upload(alice.token, new Uint8Array([1, 2, 3, 4]));
  const posted = await api("/api/stories", { token: alice.token, body: {
    frames: [{ mediaId: photo, type: "photo", text: "первый кадр", textColor: "#fff" }],
    audience: "contacts", hours: 24, link: true,
  } });
  check("a story is published", !!posted.storyId, JSON.stringify(posted));
  check("the link is minted with it", (posted.link ?? "").includes("/s/"), posted.link);

  const badFrames = await apiRaw("/api/stories", { token: alice.token,
    body: { frames: [{ type: "photo" }] } });
  check("a frame without media is refused", badFrames.status === 400, String(badFrames.status));
  const badAudience = await apiRaw("/api/stories", { token: alice.token,
    body: { frames: [{ mediaId: photo, type: "photo" }], audience: "the world" } });
  check("an audience nobody defined is refused", badAudience.status === 400,
    String(badAudience.status));

  // bob shares a direct chat with alice, carol does not
  const bobSees = await api("/api/stories", { token: bob.token });
  check("someone with a direct chat sees it",
    bobSees.stories?.some((s) => s.id === posted.storyId), JSON.stringify(bobSees.stories?.length));
  const carolSees = await api("/api/stories", { token: carol.token });
  check("a stranger does not see a contacts-only story",
    !carolSees.stories?.some((s) => s.id === posted.storyId), JSON.stringify(carolSees.stories));
  const open = await api("/api/stories", { token: alice.token, body: {
    frames: [{ mediaId: photo, type: "photo" }], audience: "everyone",
  } });
  const carolOpen = await api("/api/stories", { token: carol.token });
  check("a story for everyone reaches a stranger",
    carolOpen.stories?.some((s) => s.id === open.storyId), JSON.stringify(carolOpen.stories?.length));

  // who watched belongs to the author
  const beforeSeen = bobSees.stories.find((s) => s.id === posted.storyId);
  check("a story arrives unwatched", beforeSeen?.seen === false, JSON.stringify(beforeSeen?.seen));
  await api(`/api/stories/${posted.storyId}/seen`, { token: bob.token, body: {} });
  const afterSeen = await api("/api/stories", { token: bob.token });
  check("watching it is remembered",
    afterSeen.stories.find((s) => s.id === posted.storyId)?.seen === true);
  const viewers = await api(`/api/stories/${posted.storyId}/viewers`, { token: alice.token });
  check("the author sees who watched",
    viewers.viewers?.length === 1 && viewers.viewers[0].viewer_id === bob.userId,
    JSON.stringify(viewers.viewers));
  const notAuthor = await apiRaw(`/api/stories/${posted.storyId}/viewers`, { token: bob.token });
  check("nobody else sees who watched", notAuthor.status === 403, String(notAuthor.status));

  // the page outside the app
  const code = posted.link.split("/s/")[1];
  const page = await fetch(`${BASE}/s/${code}`);
  const html = await page.text();
  check("the public page opens with no account", page.status === 200, String(page.status));
  check("the page carries the text over the frame", html.includes("первый кадр"),
    html.slice(0, 200));
  check("the page names no audience",
    !html.includes(bob.userId) && !html.includes(alice.userId), "an id leaked into the page");
  const frame = await fetch(`${BASE}/s/${code}/m/0`);
  check("the frame is served through the link", frame.status === 200
    && frame.headers.get("content-type") === "image/jpeg", String(frame.status));
  const noFrame = await fetch(`${BASE}/s/${code}/m/7`);
  check("a frame the story has not got is not served", noFrame.status === 404,
    String(noFrame.status));

  // revoking, and what a kept link shows afterwards
  const revoked = await api(`/api/stories/${posted.storyId}`, { token: alice.token,
    body: { link: false } });
  check("the link is revoked", revoked.link === null, JSON.stringify(revoked));
  const afterRevoke = await fetch(`${BASE}/s/${code}`);
  const revokedHtml = await afterRevoke.text();
  check("a kept link says the story is gone", revokedHtml.includes("больше не открывается"),
    revokedHtml.slice(0, 200));
  check("its frames stop being served", (await fetch(`${BASE}/s/${code}/m/0`)).status === 404);
  const again = await api(`/api/stories/${posted.storyId}`, { token: alice.token,
    body: { link: true } });
  check("a new link is a new code", !again.link.endsWith(code), again.link);

  // taking the story down
  await api(`/api/stories/${posted.storyId}`, { token: alice.token, body: { takeDown: true } });
  const gone = await api("/api/stories", { token: bob.token });
  check("a story taken down is gone for everyone",
    !gone.stories?.some((s) => s.id === posted.storyId), JSON.stringify(gone.stories?.length));
  const notMine = await apiRaw(`/api/stories/${open.storyId}`, { token: bob.token,
    body: { takeDown: true } });
  check("only the author takes a story down", notMine.status === 403, String(notMine.status));
}

cmal.ws.close(); ctre.ws.close();
ca.ws.close(); cb2.ws.close(); cb3.ws.close(); cb4.ws.close(); ca2.ws.close(); ce.ws.close();
cf.ws.close(); cg.ws.close();
console.log(failures ? `\n${failures} FAILURES` : "\nALL PASS");
process.exit(failures ? 1 : 0);
