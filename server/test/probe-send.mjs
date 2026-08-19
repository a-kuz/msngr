// One message end to end on a running stand: register two users, open a direct
// chat, send over the socket, expect the author's `sent` and the recipient's
// `msg`. Prints each step so a stuck stand names the step it stuck on.
//
//   BASE_URL=http://localhost:8787 node test/probe-send.mjs
import WebSocket from "ws";

const BASE = process.env.BASE_URL ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");

async function api(path, { token, body, method } = {}) {
  const r = await fetch(BASE + path, {
    method: method ?? (body !== undefined ? "POST" : "GET"),
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => ({}));
  console.log(`${method ?? (body !== undefined ? "POST" : "GET")} ${path} -> ${r.status}`);
  return j;
}

function fakeKeys(n) {
  return {
    identityKey: "ik_" + n, identitySignKey: "isk_" + n, identityKeySig: "iksig_" + n,
    signedPrekey: { id: 1, key: "spk_" + n, sig: "sig_" + n },
    oneTimePrekeys: [{ id: 1, key: "otp1_" + n }, { id: 2, key: "otp2_" + n }],
  };
}

class Client {
  constructor(token, name) { this.token = token; this.name = name; this.frames = []; }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`${WS_BASE}/ws?token=${this.token}&v=1`);
      this.ws.on("message", (d) => {
        const f = JSON.parse(d.toString());
        f._at = Date.now();
        this.frames.push(f);
      });
      this.ws.on("open", resolve);
      this.ws.on("error", reject);
    });
  }
  send(f) { this.ws.send(JSON.stringify(f)); }
  async waitFor(what, pred, ms = 10_000) {
    const t0 = Date.now();
    for (;;) {
      const f = this.frames.find(pred);
      if (f) { console.log(`${this.name}: ${what} after ${f._at - t0 < 0 ? 0 : Date.now() - t0}ms`); return f; }
      if (Date.now() - t0 > ms) {
        console.log(`${this.name}: NO ${what} in ${ms}ms; frames seen: ${this.frames.map((x) => x.t).join(",") || "(none)"}`);
        return null;
      }
      await new Promise((r) => setTimeout(r, 20));
    }
  }
}

const suffix = Math.random().toString(36).slice(2, 8);
const a = await api("/api/register", { body: { username: "pa_" + suffix, displayName: "PA", ...fakeKeys("a") } });
const b = await api("/api/register", { body: { username: "pb_" + suffix, displayName: "PB", ...fakeKeys("b") } });
if (!a.token || !b.token) { console.log("register failed", a, b); process.exit(1); }
const chat = await api("/api/chats", { token: a.token, body: { kind: "direct", memberIds: [b.userId] } });
if (!chat.chatId) { console.log("chat create failed", chat); process.exit(1); }
await api(`/api/chats/${chat.chatId}/accept`, { token: b.token, body: {} });

const ca = new Client(a.token, "A");
const cb = new Client(b.token, "B");
await ca.connect();
await cb.connect();
const ha = await ca.waitFor("hello", (f) => f.t === "hello");
const hb = await cb.waitFor("hello", (f) => f.t === "hello");
if (!ha || !hb) process.exit(1);

ca.send({
  t: "send", chatId: chat.chatId, clientMsgId: "probe-1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: { [`${b.userId}/${b.deviceId}`]: { type: "dr", c: "ZmFrZQ" } } },
});
const sent = await ca.waitFor("sent ack", (f) => f.t === "sent" && f.clientMsgId === "probe-1", 15_000);
const msg = await cb.waitFor("msg", (f) => f.t === "msg" && f.from === a.userId, 15_000);
if (sent && msg) {
  cb.send({ t: "recv", chatId: chat.chatId, seqs: [msg.seq] });
  const tick = await ca.waitFor("delivered receipt", (f) => f.t === "receipt" && f.kind === "delivered", 15_000);
  console.log(tick ? "PROBE GREEN" : "PROBE RED: no delivered tick");
  process.exit(tick ? 0 : 1);
}
console.log("PROBE RED");
process.exit(1);
