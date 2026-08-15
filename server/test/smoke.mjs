// Интеграционный смоук: пользователи, direct-чат, WS-обмен, receipts, sync, группа,
// блокировки, логаут, пуши.
// Пуш-проверки требуют, чтобы wrangler dev видел APNS_HOST на порт приёмника смоука:
// по умолчанию http://localhost:9871 (.dev.vars), иначе PUSH_PORT=<порт>.
import http from "node:http";
import WebSocket from "ws";

const BASE = process.env.BASE_URL ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
// Порт приёмника пушей: должен совпадать с APNS_HOST у проверяемого wrangler dev.
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

class Client {
  constructor(name, token) {
    this.name = name;
    this.token = token;
    this.frames = [];
  }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`${WS_BASE}/ws?token=${this.token}`);
      // at: момент получения фрейма — по нему сравнивается порядок ack и пуша
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
  /// Позиция в ленте фреймов: с неё ищет waitAfter, ею режется срез раунда.
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

/// Догон порциями, как его крутит клиент: sync → msg-фреймы, syncState по
/// чатам, syncDone; дальше catchup по тем, кто ещё отстал, пока more не станет
/// false. Возвращает раунды со срезом syncState каждого.
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
      if (!st) next[chatId] = from;        // до чата порция не дошла
      else if (st.more) next[chatId] = st.cursor;
    }
    if (!Object.keys(next).length) return { done: true, portions };
    asked = next;
    t = "catchup";
  }
  return { done: false, portions };
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

// 6. Message request: Bob ещё не принял чат → read-receipt не уходит
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

// presence получателя не виден автору заявки и через профиль
const profBefore = await api(`/api/users/${bob.userId}`, { token: alice.token });
check("no presence before accept", profBefore.ok && profBefore.presence === null,
  JSON.stringify(profBefore.presence));

const acc = await api(`/api/chats/${chat.chatId}/accept`, { token: bob.token, body: {} });
check("accept request", acc.ok);

const profAfter = await api(`/api/users/${bob.userId}`, { token: alice.token });
check("presence after accept", profAfter.ok && !!profAfter.presence,
  JSON.stringify(profAfter.presence));

// Receipts после accept
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

// 11a. Чужое сообщение «у всех» не сносится: ни тумбстоуна, ни рассылки
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

// 12. Флаги чата (pin/mute/archive)
const fl = await api(`/api/chats/${chat.chatId}/flags`, { token: alice.token,
  body: { pinned: true, muted: true } });
check("chat flags", fl.ok);

// 13. Блокировка
const bl = await api("/api/block", { token: bob.token, body: { userId: carol.userId, blocked: true } });
const tryChat = await api("/api/chats", { token: carol.token,
  body: { kind: "direct", memberIds: [bob.userId] } });
check("blocked direct rejected", bl.ok && !tryChat.ok && tryChat.error === "blocked");

// 13a. Блокировка в уже созданном чате: отправка удаётся, доставки нет
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

// обратная сторона: заблокировавшему писать в этот чат нельзя, и он об этом
// знает — сервер отвечает явной ошибкой, а не молчаливым «отправлено»
cf.send({ t: "send", chatId: fgChat.chatId, clientMsgId: "cm-fg3", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const fg3err = await cf.waitFor((f) => f.t === "error", 1500);
check("blocker gets explicit error", fg3err?.error === "blocked", JSON.stringify(fg3err));
check("no ack for the blocked direction",
  !(await cf.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-fg3", 500)));

// непрочитанное блокирующего не растёт на невидимые сообщения
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

// 15. Contact discovery по хэшам телефонов
const ph = await api("/api/phone", { token: bob.token, body: { phoneHash: "hash_" + suffix } });
const disc = await api("/api/contacts/discover", { token: alice.token,
  body: { hashes: ["hash_" + suffix, "nonexistent"] } });
check("contact discovery", ph.ok && disc.ok && disc.matches.length === 1
  && disc.matches[0].id === bob.userId);

// 16. Invite link: создать может только участник, join по коду работает
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

// direct-чат по инвайту не джойнится
const dinv = await api(`/api/chats/${chat.chatId}/invite`, { token: alice.token, body: {} });
const djoin = await api(`/api/join/${dinv.code}`, { token: dave.token, body: {} });
check("join into direct rejected", !djoin.ok && djoin.error === "not_group");

// 16a. Настройки группы: имя и аватар меняет только админ, участники видят chat-фрейм
const titleByMember = await api(`/api/chats/${grp.chatId}/settings`, { token: dave.token,
  body: { title: "Захвачено" } });
check("group title by non-admin rejected",
  !titleByMember.ok && titleByMember.error === "not_admin");

const newTitle = "Команда " + suffix;
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

// 17. Service-фрейм: флаг доходит получателю, дедуп по clientMsgId работает
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

// 18. Sync доигрывает тумбстоуны и read-марки
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

// 19. Догон порциями: курсор двигается, «есть ещё» гаснет, ничего не теряется
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

// 19a. Между порциями объект отвечает на всё остальное: ping, посланный сразу
// за sync, получает pong до того, как догон дойдёт до конца
const cb5 = new Client("bob5", bob.token);
await cb5.connect();
cb5.send({ t: "sync", cursors: { [grp.chatId]: 1 } });
cb5.send({ t: "ping" });
const pongMid = await cb5.waitFor((f) => f.t === "pong", 15000);
const deliveredByPong = cb5.frames.filter(
  (f) => f.t === "msg" && f.chatId === grp.chatId && f.at <= pongMid?.at).length;
check("live traffic is answered mid catch-up", !!pongMid && deliveredByPong < N,
  `${deliveredByPong} of ${N} delivered by the pong`);

// 19b. Обрыв посреди догона: следующее подключение продолжает с курсора,
// а не с нуля
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

// 20. Блокировка внутри существующего чата
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

// до блокировки обмен идёт как обычно
ch.send({ t: "send", chatId: bchat.chatId, clientMsgId: "cm-b0", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const b0 = await ch.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-b0");
check("block: msg before block delivered",
  !!(await ci.waitFor((f) => f.t === "msg" && f.msgId === b0.msgId)));

// Iris блокирует Henry
check("block: applied", (await api("/api/block", { token: iris.token,
  body: { userId: henry.userId, blocked: true } })).ok);

// (а) Henry пишет: ack приходит как обычно, до Iris ничего не доходит
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

// (б) в истории блокирующего заблокированного сообщения нет, у автора — есть
const irisHist = await api(`/api/chats/${bchat.chatId}/history?fromSeq=0`, { token: iris.token });
check("block: hidden from blocker history",
  !irisHist.msgs.some((m) => m.msgId === b1.msgId)
  && irisHist.msgs.some((m) => m.msgId === b0.msgId), JSON.stringify(irisHist.msgs.length));
const henryHist = await api(`/api/chats/${bchat.chatId}/history?fromSeq=0`, { token: henry.token });
check("block: visible in sender history",
  henryHist.msgs.some((m) => m.msgId === b1.msgId));

// (в) sync блокирующего не доигрывает заблокированное
const ci2 = new Client("iris2", iris.token);
await ci2.connect();
ci2.send({ t: "sync", cursors: { [bchat.chatId]: 0 } });
await ci2.waitFor((f) => f.t === "msg" && f.msgId === b0.msgId);
await new Promise((r) => setTimeout(r, 500));
check("block: sync skips blocked msg",
  !ci2.frames.some((f) => f.t === "msg" && f.msgId === b1.msgId));

// (г) квитанции и typing заблокированного до блокирующего не доходят
ch.send({ t: "read", chatId: bchat.chatId, upToSeq: b1.seq });
ch.send({ t: "typing", chatId: bchat.chatId, kind: "text" });
await new Promise((r) => setTimeout(r, 700));
check("block: no receipt to blocker",
  !ci.frames.some((f) => f.t === "receipt" && f.by === henry.userId));
check("block: no typing to blocker",
  !ci.frames.some((f) => f.t === "typing" && f.from === henry.userId));

// (д) блокирующий пишет заблокированному: явный машиночитаемый отказ
ci.send({ t: "send", chatId: bchat.chatId, clientMsgId: "cm-b2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const bErr = await ci.waitFor((f) => f.t === "error" && f.clientMsgId === "cm-b2");
check("block: blocker gets error code", !!bErr && bErr.error === "blocked", JSON.stringify(bErr));
check("block: blocker msg not delivered",
  !(await ch.waitFor((f) => f.t === "msg" && f.from === iris.userId, 1200)));

// (е) разблокировка возвращает доставку; сообщения периода блокировки остаются скрытыми
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

// 21. Логаут и отзыв устройства
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

// сервер шлёт close-фрейм 4401 сразу; TCP-хвост wrangler dev рвёт с задержкой,
// поэтому проверяем, что сокет вышел из OPEN
await new Promise((r) => setTimeout(r, 400));
check("lg_revoked token closes live socket", lg_cLogout.ws.readyState !== 1,
  `readyState=${lg_cLogout.ws.readyState}`);

const lg_wsAfter = await new Promise((r) => {
  const ws = new WebSocket(`${WS_BASE}/ws?token=${logoutUser.token}`);
  ws.on("open", () => { ws.close(); r("open"); });
  ws.on("error", () => r("error"));
});
check("lg_revoked token rejected on ws upgrade", lg_wsAfter === "error");

// отзыв конкретного устройства из списка
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

// 22. Пуш-путь: мини-приёмник вместо APNs (порт из PUSH_PORT, туда же смотрит APNS_HOST)
const pushes = [];
// приёмник изображает APNs: dead-token отвечает 410, flaky-token — 429 на первую попытку;
// hold задерживает ответ на пуш устройства, чтобы проверить, что ack не стоит за APNs
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

// Alice снова онлайн для отправки
const ca2 = new Client("alice2", alice.token);
await ca2.connect();

// (а) получатель без сокета: пуш уходит сразу, APNs-контракт соблюдён
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p1 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p1");
const push1 = await waitPush(pushFor("eve-sim-udid", p1.msgId));
check("push delivered offline", !!push1, JSON.stringify(pushes));
if (push1) {
  check("push chatId", push1.body.chatId === echat.chatId);
  check("push thread-id", push1.body.aps["thread-id"] === echat.chatId);
  // порядок показа лавины строится по seq, поэтому он едет в пуше
  check("push carries seq", push1.body.seq === p1.seq, `seq=${push1.body.seq}`);
  check("push carries sentAt", typeof push1.body.sentAt === "number");
  // чат ещё заявка: счётчик не выдаёт, сколько сообщений уже написали
  check("push badge=0 before accept", push1.body.aps.badge === 0, `badge=${push1.body.aps.badge}`);
  check("push alert w/o plaintext", push1.body.aps.alert.body === "Новое сообщение"
    && push1.body.aps["mutable-content"] === 1 && push1.body.aps.sound === "default");
  check("push collapse-id=msgId", push1.headers["apns-collapse-id"] === p1.msgId);
  check("push topic", push1.headers["apns-topic"] === "ai.enface.Msngr"
    && push1.headers["apns-push-type"] === "alert");
  check("dev push unsigned", push1.headers.authorization === undefined);
}

// (б) получатель с живым сокетом: WS-фрейм и пуш приходят оба (дедуп на клиенте)
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

// read сдвигает бейдж: eve принимает чат (message request), читает всё,
// следующий пуш приходит с badge=1
await api(`/api/chats/${echat.chatId}/accept`, { token: eve.token, body: {} });
ce.send({ t: "read", chatId: echat.chatId, upToSeq: p2.seq });
await ca2.waitFor((f) => f.t === "receipt" && f.kind === "read" && f.by === eve.userId);
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p3", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p3 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p3");
const push3 = await waitPush(pushFor("eve-sim-udid", p3.msgId));
check("push badge after read", push3 && push3.body.aps.badge === 1,
  `badge=${push3?.body.aps.badge}`);

// (в) service-фрейм пуш не порождает
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p4", sentAt: Date.now(),
  service: true, body: { v: 1, mode: "skd", c: "c2tk" } });
const p4 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p4");
check("no push for service", !(await waitPush(pushFor("eve-sim-udid", p4.msgId), 1200)));

// (г) muted-чат пуш не порождает
await api(`/api/chats/${echat.chatId}/flags`, { token: eve.token, body: { muted: true } });
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p5", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p5 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p5");
check("no push for muted chat", !(await waitPush(pushFor("eve-sim-udid", p5.msgId), 1200)));

// (д) mute со сроком: пока срок не вышел — пуша нет
const nowS = Math.floor(Date.now() / 1000);
await api(`/api/chats/${echat.chatId}/flags`, { token: eve.token,
  body: { muted: true, mutedUntil: nowS + 3600 } });
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-p6", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const p6 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-p6");
check("no push while mute not expired", !(await waitPush(pushFor("eve-sim-udid", p6.msgId), 1200)));

// (е) срок вышел — пуш уходит, флаг снимается сам
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

// (ж) own echo: у alice токен зарегистрирован, но её собственные отправки пуш не создают
check("no push for own echo", !pushes.some((p) => p.url === "/3/device/alice-sim-udid"));

// 21. Ack раньше пуша: подтверждение отправителю не ждёт APNs
hold = { token: "eve-sim-udid", ms: 1500 };
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-h1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const h1 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-h1");
const hp1 = await waitPush(pushFor("eve-sim-udid", h1.msgId));
check("ack precedes push", !!h1 && !!hp1 && h1.at <= hp1.at,
  `ack ${h1?.at} push ${hp1?.at}`);

// пуш предыдущего сообщения ещё висит — ack следующего всё равно приходит сразу
const holdT0 = Date.now();
ca2.send({ t: "send", chatId: echat.chatId, clientMsgId: "cm-h2", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} } });
const h2 = await ca2.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-h2", 3000);
check("ack while apns still hanging", !!h2 && h2.at - holdT0 < 600,
  `${h2 ? h2.at - holdT0 : "no ack"}ms`);
const hp2 = await waitPush(pushFor("eve-sim-udid", h2.msgId), 8000);
check("push follows its ack", !!hp2 && h2.at < hp2.at, `ack ${h2?.at} push ${hp2?.at}`);
hold = { token: null, ms: 0 };

// 23. Разбор ответа APNs: 410 удаляет токен, 429 повторяется
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

// 22. Fanout: падение одного получателя не рвёт доставку остальным
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
// дать presence-фреймам разойтись, чтобы они не съели счётчик сбоев
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

// typing не повторяется: он устаревает быстрее, чем доедет повтор
await fault(1);
ca2.send({ t: "typing", chatId: fgrp.chatId, kind: "text" });
check("typing reaches healthy recipient",
  !!(await ctre.waitFor((f) => f.t === "typing" && f.chatId === fgrp.chatId)));
await new Promise((r) => setTimeout(r, 2000));
check("typing not retried", !cmal.frames.some((f) => f.t === "typing" && f.chatId === fgrp.chatId));

// получатель сломан насовсем: очередь отдаёт его и продолжает работать
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

// 23. Очередь рассылки: пачка встаёт в очередь и доигрывается до конца
async function fanoutState() {
  return api(`/api/chats/${fgrp.chatId}/fanout`, { token: alice.token });
}
await fault(2); // головное задание застревает на двух повторах
const Q = 6;
for (let i = 0; i < Q; i++) sendTo(`cm-q${i}`);
const qState = await fanoutState();
check("fanout is queued, not inline", qState.ok && qState.pending > 0, JSON.stringify(qState));

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

const strangerQ = await api(`/api/chats/${fgrp.chatId}/fanout`, { token: bob.token });
check("fanout state hidden from non-member", !strangerQ.ok && strangerQ.error === "not_member");

cmal.ws.close(); ctre.ws.close();
ca.ws.close(); cb2.ws.close(); cb3.ws.close(); cb4.ws.close(); ca2.ws.close(); ce.ws.close();
cf.ws.close(); cg.ws.close();
console.log(failures ? `\n${failures} FAILURES` : "\nALL PASS");
process.exit(failures ? 1 : 0);
