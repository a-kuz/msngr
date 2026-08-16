// Integration smoke: users, direct chat, WS exchange, receipts, sync, groups,
// blocks, logout, pushes.
// The push checks need wrangler dev to point APNS_HOST at the smoke's own
// receiver: http://localhost:9871 by default (.dev.vars), otherwise PUSH_PORT=<port>.
import http from "node:http";
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

const bundle = await api(`/api/users/${bob.userId}/prekeys`, { token: alice.token });
check("prekey bundle", bundle.ok && bundle.bundles[0].oneTimePrekey?.key === "otp1_b");
const bundle2 = await api(`/api/users/${bob.userId}/prekeys`, { token: alice.token });
check("one-time prekey consumed", bundle2.bundles[0].oneTimePrekey?.key === "otp2_b");

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
const aliceEcho = await ca.waitFor((f) => f.t === "msg" && f.msgId === sent.msgId);
check("alice gets own echo", !!aliceEcho);

// idempotency
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-1", sentAt: Date.now(), body: {} });
const sent2 = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-1" && f !== sent);
check("idempotent resend same seq", !!sent2 && sent2.seq === 1 && sent2.msgId === sent.msgId);

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
ca.send({ t: "delete", chatId: chat.chatId, msgIds: [sent.msgId], forAll: true });
const del = await cb2.waitFor((f) => f.t === "deleted");
check("delete for all", !!del && del.msgIds.includes(sent.msgId));
const hist = await api(`/api/chats/${chat.chatId}/history?fromSeq=0`, { token: bob.token });
const tomb = hist.msgs.find((m) => m.msgId === sent.msgId);
check("tombstoned on server", tomb && tomb.deleted === true && tomb.body === null);

// 11a. Delete for all does not touch someone else's message: no tombstone, no fanout
cb2.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-bob-own", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const bobOwn = await cb2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-bob-own");
ca.send({ t: "delete", chatId: chat.chatId, msgIds: [bobOwn.msgId], forAll: true });
const foreignDel = await cb2.waitFor((f) => f.t === "deleted" && f.msgIds.includes(bobOwn.msgId), 1500);
check("no fanout deleting someone else's message", foreignDel === null);
const hist2 = await api(`/api/chats/${chat.chatId}/history?fromSeq=0`, { token: bob.token });
const keptMsg = hist2.msgs.find((m) => m.msgId === bobOwn.msgId);
check("someone else's message survives delete for all",
  keptMsg && !keptMsg.deleted && keptMsg.body !== null);

// 12. Chat flags (pin/mute/archive)
const fl = await api(`/api/chats/${chat.chatId}/flags`, { token: alice.token,
  body: { pinned: true, muted: true } });
check("chat flags", fl.ok);

// 13. Blocking
const bl = await api("/api/block", { token: bob.token, body: { userId: carol.userId, blocked: true } });
const tryChat = await api("/api/chats", { token: carol.token,
  body: { kind: "direct", memberIds: [bob.userId] } });
check("blocked direct rejected", bl.ok && !tryChat.ok && tryChat.error === "blocked");

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
  !(await cf.waitFor((f) => f.t === "msg" && f.msgId === fg2?.msgId, 1200)));

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
  !!(await cf.waitFor((f) => f.t === "msg" && f.msgId === fg4?.msgId)));

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

// 16b. Member rights: who may write and who may bring people in
const policyByMember = await api(`/api/chats/${grp.chatId}/settings`, { token: dave.token,
  body: { sendPolicy: "admins" } });
check("group rights by non-admin rejected",
  !policyByMember.ok && policyByMember.error === "not_admin");

const cdave = new Client("dave-rights", dave.token);
await cdave.connect();
const daveOpen = cdave.mark();
cdave.send({ t: "send", chatId: grp.chatId, clientMsgId: "cm-open-1", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
check("member writes while the group is open",
  !!(await cdave.waitAfter(daveOpen, (f) => f.t === "sent" && f.clientMsgId === "cm-open-1")));

const readOnly = await api(`/api/chats/${grp.chatId}/settings`, { token: alice.token,
  body: { sendPolicy: "admins" } });
const readOnlyFrame = await cb2.waitFor((f) =>
  f.t === "chat" && f.chatId === grp.chatId && f.state.sendPolicy === "admins");
check("admin makes the group read-only", readOnly.ok && !!readOnlyFrame);

const daveMuted = cdave.mark();
cdave.send({ t: "send", chatId: grp.chatId, clientMsgId: "cm-muted-1", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
const muteErr = await cdave.waitAfter(daveMuted,
  (f) => f.t === "error" && f.clientMsgId === "cm-muted-1");
check("member cannot write in a read-only group",
  !!muteErr && muteErr.error === "not_allowed", JSON.stringify(muteErr));

// the crypto keeps working: a key handout, a repair, an ack are service frames
const daveService = cdave.mark();
cdave.send({ t: "send", chatId: grp.chatId, clientMsgId: "cm-muted-skd", sentAt: Date.now(),
  service: true, body: { v: 1, mode: "skd", c: "c2tk" } });
check("service frames pass in a read-only group",
  !!(await cdave.waitAfter(daveService, (f) => f.t === "sent" && f.clientMsgId === "cm-muted-skd")));

const adminWrite = ca.mark();
ca.send({ t: "send", chatId: grp.chatId, clientMsgId: "cm-muted-admin", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
check("admin writes in a read-only group",
  !!(await ca.waitAfter(adminWrite, (f) => f.t === "sent" && f.clientMsgId === "cm-muted-admin")));

await api(`/api/chats/${grp.chatId}/settings`, { token: alice.token, body: { sendPolicy: "all" } });
const daveAgain = cdave.mark();
cdave.send({ t: "send", chatId: grp.chatId, clientMsgId: "cm-open-2", sentAt: Date.now(),
  body: { v: 1, mode: "skm", c: "Zm9v", senderKeyId: "sk1" } });
check("the group opens again",
  !!(await cdave.waitAfter(daveAgain, (f) => f.t === "sent" && f.clientMsgId === "cm-open-2")));

// inviting: open by default, admins only once the policy says so
const guest = await api("/api/register", { body: {
  username: "guest" + suffix, displayName: "Guest", device: { name: "iPhone" }, ...fakeKeys("g1") } });
const addByMember = await api(`/api/chats/${grp.chatId}/members`, { token: dave.token,
  body: { add: [guest.userId], remove: [] } });
check("member adds a member while inviting is open", addByMember.ok, JSON.stringify(addByMember));
const invByMember = await api(`/api/chats/${grp.chatId}/invite`, { token: dave.token, body: {} });
check("member mints an invite while inviting is open", invByMember.ok);

const lockInvites = await api(`/api/chats/${grp.chatId}/settings`, { token: alice.token,
  body: { invitePolicy: "admins" } });
check("admin locks inviting", lockInvites.ok);
const guest2 = await api("/api/register", { body: {
  username: "guesttwo" + suffix, displayName: "Guest Two", device: { name: "iPhone" }, ...fakeKeys("g2") } });
const addByMemberLocked = await api(`/api/chats/${grp.chatId}/members`, { token: dave.token,
  body: { add: [guest2.userId], remove: [] } });
check("member cannot add once inviting is locked",
  !addByMemberLocked.ok && addByMemberLocked.error === "not_allowed",
  JSON.stringify(addByMemberLocked));
const invLocked = await api(`/api/chats/${grp.chatId}/invite`, { token: dave.token, body: {} });
check("member cannot mint an invite once inviting is locked",
  !invLocked.ok && invLocked.error === "not_allowed", JSON.stringify(invLocked));
const invByAdmin = await api(`/api/chats/${grp.chatId}/invite`, { token: alice.token, body: {} });
check("admin mints an invite in a locked group", invByAdmin.ok);
await api(`/api/chats/${grp.chatId}/settings`, { token: alice.token, body: { invitePolicy: "all" } });
cdave.ws.close();

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
check("service dedupe by clientMsgId", !!svcAck2 && svcAck2.seq === svcAck1.seq
  && svcAck2.msgId === svcAck1.msgId);

// 18. Sync replays tombstones and read marks
ca.send({ t: "read", chatId: chat.chatId, upToSeq: 2 });
await new Promise((r) => setTimeout(r, 300));
const cb3 = new Client("bob3", bob.token);
await cb3.connect();
cb3.send({ t: "sync", cursors: { [chat.chatId]: svc.seq } });
const syncTomb = await cb3.waitFor((f) => f.t === "deleted" && f.msgIds.includes(sent.msgId));
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
  !!(await ci.waitFor((f) => f.t === "msg" && f.msgId === b0.msgId)));

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
  !(await ci.waitFor((f) => f.t === "msg" && f.msgId === b1.msgId, 1200)));
check("block: own echo still delivered",
  !!(await ch.waitFor((f) => f.t === "msg" && f.msgId === b1.msgId)));

// (b) the blocked message is absent from the blocker's history and present in the sender's
const irisHist = await api(`/api/chats/${bchat.chatId}/history?fromSeq=0`, { token: iris.token });
check("block: hidden from blocker history",
  !irisHist.msgs.some((m) => m.msgId === b1.msgId)
  && irisHist.msgs.some((m) => m.msgId === b0.msgId), JSON.stringify(irisHist.msgs.length));
const henryHist = await api(`/api/chats/${bchat.chatId}/history?fromSeq=0`, { token: henry.token });
check("block: visible in sender history",
  henryHist.msgs.some((m) => m.msgId === b1.msgId));

// (c) the blocker's sync does not replay the blocked message
const ci2 = new Client("iris2", iris.token);
await ci2.connect();
ci2.send({ t: "sync", cursors: { [bchat.chatId]: 0 } });
await ci2.waitFor((f) => f.t === "msg" && f.msgId === b0.msgId);
await new Promise((r) => setTimeout(r, 500));
check("block: sync skips blocked msg",
  !ci2.frames.some((f) => f.t === "msg" && f.msgId === b1.msgId));

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
  !!(await ci.waitFor((f) => f.t === "msg" && f.msgId === b3.msgId)));
const irisHist2 = await api(`/api/chats/${bchat.chatId}/history?fromSeq=0`, { token: iris.token });
check("block: blocked msg stays hidden after unblock",
  !irisHist2.msgs.some((m) => m.msgId === b1.msgId)
  && irisHist2.msgs.some((m) => m.msgId === b3.msgId));
ch.ws.close(); ci.ws.close(); ci2.ws.close();

// 21. Logout and device revocation
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
const lk_bundlesAfter = await api(`/api/users/${lk_owner.userId}/prekeys`, { token: alice.token });
check("a revoked device hands out no more prekey bundles",
  lk_bundlesAfter.bundles.length === 1
  && lk_bundlesAfter.bundles[0].deviceId === lk_owner.deviceId,
  JSON.stringify(lk_bundlesAfter));
check("the revoked device's token is dead",
  (await apiRaw("/api/me", { token: lk_claim.token })).status === 401);
check("the remaining device is untouched",
  (await api("/api/me", { token: lk_owner.token })).ok);

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
const pushFor = (token, msgId) => (p) =>
  p.url === `/3/device/${token}` && p.body.msgId === msgId;

const eve = await api("/api/register", { body: {
  username: "eve_" + suffix, displayName: "Eve", ...fakeKeys("e") } });
await api("/api/push-token", { token: eve.token,
  body: { apnsToken: "eve-sim-udid", env: "development" } });
await api("/api/push-token", { token: alice.token,
  body: { apnsToken: "alice-sim-udid", env: "development" } });

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
const push1 = await waitPush(pushFor("eve-sim-udid", p1.msgId));
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
  check("push collapse-id=msgId", push1.headers["apns-collapse-id"] === p1.msgId);
  check("push topic", push1.headers["apns-topic"] === "ai.enface.Msngr"
    && push1.headers["apns-push-type"] === "alert");
  check("dev push unsigned", push1.headers.authorization === undefined);
}

// (b) recipient with a live socket: both the WS frame and the push arrive (client dedupes)
const ce = new Client("eve", eve.token);
await ce.connect();
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p2 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p2");
check("eve got ws msg", !!(await ce.waitFor((f) => f.t === "msg" && f.msgId === p2.msgId)));
const push2 = await waitPush(pushFor("eve-sim-udid", p2.msgId));
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
const push3 = await waitPush(pushFor("eve-sim-udid", p3.msgId));
check("push badge after read", push3 && push3.body.aps.badge === 1,
  `badge=${push3?.body.aps.badge}`);
// badgeStamp is how the client tells a fresh counter from an older one that
// overtook it: UserSessionDO issues the number and it strictly grows
check("badge stamps grow", push1 && push2 && push3
  && push1.body.badgeStamp < push2.body.badgeStamp
  && push2.body.badgeStamp < push3.body.badgeStamp,
  `${push1?.body.badgeStamp} ${push2?.body.badgeStamp} ${push3?.body.badgeStamp}`);

// (c) a service frame produces no push
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p4", sentAt: Date.now(),
  service: true, body: { v: 1, mode: "skd", c: "c2tk" } });
const p4 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p4");
check("no push for service", !(await waitPush(pushFor("eve-sim-udid", p4.msgId), 1200)));

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
const pushSvc = await waitPush(pushFor("eve-sim-udid", psvc.msgId));
check("service frame does not grow the badge", pushSvc?.body.aps.badge === 1,
  `badge=${pushSvc?.body.aps.badge}`);

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
const push8 = await waitPush(pushFor("eve-sim-udid", p8.msgId));
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
const push9 = await waitPush(pushFor("eve-sim-udid", p9.msgId));
check("oversized envelope is dropped from the push",
  !!push9 && push9.body.env === undefined && push9.body.msgId === p9.msgId);

// (d) a muted chat produces no push
await api(`/api/chats/${echat.chatId}/flags`, { token: eve.token, body: { muted: true } });
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p5", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p5 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p5");
check("no push for muted chat", !(await waitPush(pushFor("eve-sim-udid", p5.msgId), 1200)));

// (e) mute with an expiry: no push while it has not expired
const nowS = Math.floor(Date.now() / 1000);
await api(`/api/chats/${echat.chatId}/flags`, { token: eve.token,
  body: { muted: true, mutedUntil: nowS + 3600 } });
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p6", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p6 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p6");
check("no push while mute not expired", !(await waitPush(pushFor("eve-sim-udid", p6.msgId), 1200)));

// (f) once it has expired the push goes out and the flag clears itself
await api(`/api/chats/${echat.chatId}/flags`, { token: eve.token,
  body: { muted: true, mutedUntil: nowS - 1 } });
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p7", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p7 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p7");
check("push after mute expired", !!(await waitPush(pushFor("eve-sim-udid", p7.msgId))));
const eveChats = await api("/api/chats", { token: eve.token });
const eveEntry = eveChats.chats.find((e) => e.state.chatId === echat.chatId);
check("expired mute cleared in flags",
  !!eveEntry && eveEntry.flags.muted === false && eveEntry.flags.mutedUntil === undefined,
  JSON.stringify(eveEntry?.flags));

// (g) own echo: alice has a token registered, yet her own sends create no push
check("no push for own echo", !pushes.some((p) => p.url === "/3/device/alice-sim-udid"));

// (d) The server counts the badge, and the author does not count what they sent as
// unread, exactly as the cursor on the device does. Otherwise the number would grow on
// what the author wrote themselves.
ce.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-e1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const e1 = await ce.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-e1");
check("author's badge counts the peer's message",
  (await waitPush(pushFor("alice-sim-udid", e1.msgId)))?.body.aps.badge === 1);
for (const id of ["cm-p11", "cm-p12", "cm-p13"]) {
  ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: id, sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: {} } });
  await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === id);
}
ce.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-e2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const e2 = await ce.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-e2");
const badgeAfter = (await waitPush(pushFor("alice-sim-udid", e2.msgId)))?.body.aps.badge;
check("own messages do not grow the author's badge", badgeAfter === 1,
  `badge=${badgeAfter}`);

// 21. Ack before push: the sender's confirmation does not wait for APNs
hold = { token: "eve-sim-udid", ms: 1500 };
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-h1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const h1 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-h1");
const hp1 = await waitPush(pushFor("eve-sim-udid", h1.msgId));
check("ack precedes push", !!h1 && !!hp1 && h1.at <= hp1.at,
  `ack ${h1?.at} push ${hp1?.at}`);

// the previous message's push is still hanging, the next ack arrives right away anyway
const holdT0 = Date.now();
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-h2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const h2 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-h2", 3000);
check("ack while apns still hanging", !!h2 && h2.at - holdT0 < 600,
  `${h2 ? h2.at - holdT0 : "no ack"}ms`);
const hp2 = await waitPush(pushFor("eve-sim-udid", h2.msgId), 8000);
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
check("dead token: push attempted", !!(await waitPush(pushFor("dead-token", d1.msgId))));

await new Promise((r) => setTimeout(r, 600));
const jackSess = await api("/api/sessions", { token: jack.token });
check("dead token: dropped from d1",
  jackSess.ok && jackSess.sessions[0].hasPushToken === false, JSON.stringify(jackSess));

ca2.send({ t: "send", chatId: jchat.chatId, clientMsgId: "cm-dead2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const d2 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-dead2");
check("dead token: no push after drop",
  !(await waitPush(pushFor("dead-token", d2.msgId), 1500)));

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
  p.url === "/3/device/flaky-token" && p.body.msgId === fk.msgId);
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
  !!(await ctre.waitFor((f) => f.t === "msg" && f.msgId === f1.msgId)));
check("failed recipient gets retry",
  !!(await cmal.waitFor((f) => f.t === "msg" && f.msgId === f1.msgId, 4000)));

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
  !!(await ctre.waitFor((f) => f.t === "msg" && f.msgId === f2.msgId, 8000)));
sendTo("cm-f3");
const f3 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-f3");
check("queue keeps moving after dropped recipient",
  !!(await ctre.waitFor((f) => f.t === "msg" && f.msgId === f3.msgId, 8000)));
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
const qGotT = await ctre.waitFor((f) => f.t === "msg" && f.msgId === qLast.msgId, 20000);
check("queue replays the whole burst", !!qGotT);
const qGotM = await cmal.waitFor((f) => f.t === "msg" && f.msgId === qLast.msgId, 20000);
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
check("queue drains to empty cursor",
  !!drained && drained.pending === 0 && drained.cursor === 0, JSON.stringify(drained));
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

cmal.ws.close(); ctre.ws.close();
ca.ws.close(); cb2.ws.close(); cb3.ws.close(); cb4.ws.close(); ca2.ws.close(); ce.ws.close();
cf.ws.close(); cg.ws.close();
console.log(failures ? `\n${failures} FAILURES` : "\nALL PASS");
process.exit(failures ? 1 : 0);
