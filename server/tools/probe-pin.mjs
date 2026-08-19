// Probe: does a pin fan out over the socket to both members?
import WebSocket from "ws";
const BASE = process.env.BASE_URL ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");

async function api(path, { token, body, method } = {}) {
  const r = await fetch(BASE + path, {
    method: method ?? (body !== undefined ? "POST" : "GET"),
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  return r.json();
}
function keys(n) {
  return { identityKey: "ik_" + n, identitySignKey: "isk_" + n, identityKeySig: "iksig_" + n,
    signedPrekey: { id: 1, key: "spk_" + n, sig: "sig_" + n },
    oneTimePrekeys: [{ id: 1, key: "otp1_" + n }] };
}
class C {
  constructor(t) { this.token = t; this.frames = []; }
  connect() {
    return new Promise((res, rej) => {
      this.ws = new WebSocket(`${WS_BASE}/ws?token=${this.token}&v=1`);
      this.ws.on("message", (d) => this.frames.push({ ...JSON.parse(d.toString()), at: Date.now() }));
      this.ws.on("open", res); this.ws.on("error", rej);
    });
  }
  send(f) { this.ws.send(JSON.stringify(f)); }
  async waitFor(pred, ms = 5000) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      const f = this.frames.find(pred); if (f) return f;
      await new Promise((r) => setTimeout(r, 50));
    }
    return null;
  }
}
const s = Math.random().toString(36).slice(2, 8);
const a = await api("/api/register", { body: { username: "pina_" + s, displayName: "PinA", ...keys("a") } });
const b = await api("/api/register", { body: { username: "pinb_" + s, displayName: "PinB", ...keys("b") } });
const chat = await api("/api/chats", { token: a.token, body: { kind: "direct", memberIds: [b.userId] } });
const ca = new C(a.token), cb = new C(b.token);
await ca.connect(); await cb.connect();
await ca.waitFor((f) => f.t === "hello");
ca.send({ t: "send", chatId: chat.chatId, clientMsgId: "cm-1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: { [`${b.userId}/${b.deviceId}`]: { type: "dr", c: "ZmFrZQ" } } } });
const sent = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === "cm-1");
console.log("sent:", JSON.stringify(sent));
// accept, so Bob is a full member
await api(`/api/chats/${chat.chatId}/accept`, { token: b.token, body: {} });
const ma = ca.frames.length, mb = cb.frames.length;
const t0 = Date.now();
const pinRes = await api(`/api/chats/${chat.chatId}/pin-message`, { token: a.token, body: { msgId: sent.msgId } });
console.log("POST pin ->", JSON.stringify(pinRes), `${Date.now() - t0}ms`);
const fa = await ca.waitFor((f, i) => i >= ma && f.t === "chat" && f.event === "pinned");
const fb = await cb.waitFor((f, i) => i >= mb && f.t === "chat" && f.event === "pinned");
console.log("actor got chat/pinned:", !!fa, fa ? `${fa.at - t0}ms pinnedMsgId=${fa.state?.pinnedMsgId}` : "");
console.log("peer  got chat/pinned:", !!fb, fb ? `${fb.at - t0}ms pinnedMsgId=${fb.state?.pinnedMsgId}` : "");
console.log("all frames after pin (actor):", JSON.stringify(ca.frames.slice(ma).map((f) => f.t + "/" + (f.event ?? ""))));
console.log("all frames after pin (peer) :", JSON.stringify(cb.frames.slice(mb).map((f) => f.t + "/" + (f.event ?? ""))));
process.exit(0);
