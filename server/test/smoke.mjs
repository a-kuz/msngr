// Интеграционный смоук: 2 пользователя, direct-чат, WS-обмен, receipts, sync, группа.
import WebSocket from "ws";

const BASE = "http://localhost:8787";
let failures = 0;

function check(name, cond, extra = "") {
  if (cond) console.log(`ok   ${name}`);
  else { failures++; console.log(`FAIL ${name} ${extra}`); }
}

async function api(path, { token, body, method } = {}) {
  const res = await fetch(BASE + path, {
    method: method ?? (body !== undefined ? "POST" : "GET"),
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  return res.json();
}

function fakeKeys(n) {
  return {
    identityKey: "ik_" + n,
    identitySignKey: "isk_" + n,
    signedPrekey: { id: 1, key: "spk_" + n, sig: "sig_" + n },
    oneTimePrekeys: [{ id: 1, key: "otp1_" + n }, { id: 2, key: "otp2_" + n }],
  };
}

class Client {
  constructor(name, token) {
    this.name = name;
    this.token = token;
    this.frames = [];
  }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`ws://localhost:8787/ws?token=${this.token}`);
      this.ws.on("message", (d) => this.frames.push(JSON.parse(d.toString())));
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
}

const suffix = Math.random().toString(36).slice(2, 8);

// 1. Регистрация
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

// 2. Поиск и prekeys
const found = await api(`/api/users?q=bob_${suffix}`, { token: alice.token });
check("user search", found.ok && found.users.length === 1);

const bundle = await api(`/api/users/${bob.userId}/prekeys`, { token: alice.token });
check("prekey bundle", bundle.ok && bundle.bundles[0].oneTimePrekey?.key === "otp1_b");
const bundle2 = await api(`/api/users/${bob.userId}/prekeys`, { token: alice.token });
check("one-time prekey consumed", bundle2.bundles[0].oneTimePrekey?.key === "otp2_b");

// 3. Direct-чат (+дедуп)
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
check("ws hello", !!(await ca.waitFor((f) => f.t === "hello")));

// 5. Отправка сообщения
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: { [`${bob.userId}/${bob.deviceId}`]: { type: "dr", c: "ZmFrZQ" } } } });
const sent = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-1");
check("sent ack", !!sent && sent.seq === 1, JSON.stringify(sent));
const gotMsg = await cb.waitFor((f) => f.t === "msg" && f.chatId === chat.chatId);
check("bob receives msg", !!gotMsg && gotMsg.from === alice.userId);
const aliceEcho = await ca.waitFor((f) => f.t === "msg" && f.msgId === sent.msgId);
check("alice gets own echo", !!aliceEcho);

// идемпотентность
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-1", sentAt: Date.now(), body: {} });
const sent2 = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-1" && f !== sent);
check("idempotent resend same seq", !!sent2 && sent2.seq === 1 && sent2.msgId === sent.msgId);

// 6. Receipts
cb.send({ t: "recv", chatId: chat.chatId, seqs: [1] });
const delivered = await ca.waitFor((f) => f.t === "receipt" && f.kind === "delivered");
check("delivered receipt", !!delivered && delivered.by === bob.userId);
cb.send({ t: "read", chatId: chat.chatId, upToSeq: 1 });
const read = await ca.waitFor((f) => f.t === "receipt" && f.kind === "read");
check("read receipt", !!read && read.upToSeq === 1);

// 7. Typing
cb.send({ t: "typing", chatId: chat.chatId, kind: "text" });
const typing = await ca.waitFor((f) => f.t === "typing" && f.from === bob.userId);
check("typing", !!typing);

// 8. Offline → sync: Bob отключается, Alice шлёт, Bob возвращается с курсором
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

// 9. Группа
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

// 10. Снапшот чатов
const snap = await api("/api/chats", { token: bob.token });
check("chats snapshot", snap.ok && snap.chats.length === 2 && snap.users.length >= 3);

// 11. delete for all
ca.send({ t: "delete", chatId: chat.chatId, msgIds: [sent.msgId], forAll: true });
const del = await cb2.waitFor((f) => f.t === "deleted");
check("delete for all", !!del && del.msgIds.includes(sent.msgId));
const hist = await api(`/api/chats/${chat.chatId}/history?fromSeq=0`, { token: bob.token });
const tomb = hist.msgs.find((m) => m.msgId === sent.msgId);
check("tombstoned on server", tomb && tomb.deleted === true && tomb.body === null);

// 12. Флаги чата (pin/mute/archive)
const fl = await api(`/api/chats/${chat.chatId}/flags`, { token: alice.token,
  body: { pinned: true, muted: true } });
check("chat flags", fl.ok);

// 13. Блокировка
const bl = await api("/api/block", { token: bob.token, body: { userId: carol.userId, blocked: true } });
const tryChat = await api("/api/chats", { token: carol.token,
  body: { kind: "direct", memberIds: [bob.userId] } });
check("blocked direct rejected", bl.ok && !tryChat.ok && tryChat.error === "blocked");

// 14. Медиа: upload/download с range
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

// 15. Invite link
const inv = await api(`/api/chats/${grp.chatId}/invite`, { token: alice.token, body: {} });
check("invite created", inv.ok && inv.code);

ca.ws.close(); cb2.ws.close();
console.log(failures ? `\n${failures} FAILURES` : "\nALL PASS");
process.exit(failures ? 1 : 0);
