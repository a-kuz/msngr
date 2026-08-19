// Sustained-load probe for the fanout queue of one chat.
//
// Fires bursts into a group as fast as the sender's socket takes them and, for
// every round, checks that both receivers got every frame and that the queue
// drained to empty. A stalled queue shows up here as receivers short of the
// count while their socket is still open — the shape a client cannot tell apart
// from silence.
//
//   BASE_URL=http://localhost:8811 node test/fanout-load.mjs [count] [fault] [rounds]
//
// `fault` makes one receiver's session reject that many deliveries, so the
// rounds run through the retry path as well.
import WebSocket from "ws";

const BASE = process.env.BASE_URL ?? "http://localhost:8787";
const WS_BASE = BASE.replace(/^http/, "ws");
const COUNT = Number(process.argv[2] ?? 500);
const FAULT = Number(process.argv[3] ?? 0);
const ROUNDS = Number(process.argv[4] ?? 1);
/// No frame for this long with the round unfinished ends the wait and is
/// reported: the round can still finish, so it is an idle gap, not a verdict.
const IDLE_STALL_MS = 4_000;
/// How long the queue is given to reach an empty cursor after the round landed.
const DRAIN_MS = 4_000;
/// Pause between rounds, which is what lets the queue go empty in between: the
/// arming race only exists for a job that arrives around a drain ending.
const GAP_MS = Number(process.env.GAP_MS ?? 60);
/// Window the second sender's frame lands in, measured from the burst.
const TRAILER_MS = Number(process.env.TRAILER_MS ?? 12);

async function api(path, { token, body, method } = {}) {
  try {
    return await apiOnce(path, { token, body, method });
  } catch (e) {
    // a chat busy draining answers late: the object handles the request only
    // once the drain lets go of it
    return { ok: false, error: String(e?.cause?.code ?? e?.message ?? e) };
  }
}

async function apiOnce(path, { token, body, method } = {}) {
  const r = await fetch(BASE + path, {
    method: method ?? (body !== undefined ? "POST" : "GET"),
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      "content-type": "application/json",
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  return r.json();
}

function fakeKeys(n) {
  return {
    identityKey: "ik_" + n, identitySignKey: "isk_" + n, identityKeySig: "iksig_" + n,
    signedPrekey: { id: 1, key: "spk_" + n, sig: "sig_" + n },
    oneTimePrekeys: [{ id: 1, key: "otp1_" + n }, { id: 2, key: "otp2_" + n }],
  };
}

class Client {
  constructor(token) { this.token = token; this.frames = []; this.msgs = 0; this.lastAt = 0; }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`${WS_BASE}/ws?token=${this.token}`);
      this.ws.on("message", (d) => {
        const f = JSON.parse(d.toString());
        this.frames.push(f);
        if (f.t === "msg") { this.msgs++; this.lastAt = Date.now(); }
      });
      this.ws.on("open", resolve);
      this.ws.on("error", reject);
    });
  }
  send(f) { this.ws.send(JSON.stringify(f)); }
  async waitFor(pred, ms = 8000) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      const f = this.frames.find(pred);
      if (f) return f;
      await new Promise((r) => setTimeout(r, 25));
    }
    return null;
  }
}

const suffix = Math.random().toString(36).slice(2, 8);
const a = await api("/api/register", { body: { username: "la_" + suffix, displayName: "LA", ...fakeKeys("a") } });
const b = await api("/api/register", { body: { username: "lb_" + suffix, displayName: "LB", ...fakeKeys("b") } });
const c = await api("/api/register", { body: { username: "lc_" + suffix, displayName: "LC", ...fakeKeys("c") } });
const grp = await api("/api/chats", {
  token: a.token, body: { kind: "group", memberIds: [b.userId, c.userId], title: "load" },
});
const ca = new Client(a.token), cb = new Client(b.token), cc = new Client(c.token);
await ca.connect(); await cb.connect(); await cc.connect();
await ca.waitFor((f) => f.t === "hello");

let bad = 0;
for (let round = 1; round <= ROUNDS; round++) {
  const baseB = cb.msgs, baseC = cc.msgs;
  if (FAULT > 0) await api("/api/dev/fault", { token: b.token, body: { failEvents: FAULT } });

  const t0 = Date.now();
  for (let i = 0; i < COUNT; i++) {
    ca.send({
      t: "send", chatId: grp.chatId, clientMsgId: `r${round}-${i}`, sentAt: Date.now(),
      body: { v: 1, mode: "pw", msgs: { [`${b.userId}/${b.deviceId}`]: { type: "dr", c: "ZmFrZQ" } } },
    });
  }
  // a second sender lands its frame while the first burst is being drained,
  // which is where a job can be queued against an alarm that is already running
  const trailer = new Promise((r) => setTimeout(r, Math.random() * TRAILER_MS)).then(() =>
    cc.send({
      t: "send", chatId: grp.chatId, clientMsgId: `r${round}-t`, sentAt: Date.now(),
      body: { v: 1, mode: "pw", msgs: { [`${b.userId}/${b.deviceId}`]: { type: "dr", c: "ZmFrZQ" } } },
    })
  );
  const lastAck = await ca.waitFor((f) => f.t === "sent" && f.clientMsgId === `r${round}-${COUNT - 1}`, 60_000);
  await trailer;
  const sendSec = (Date.now() - t0) / 1000;
  const expect = COUNT + 1;

  let stalled = null;
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    if (cb.msgs - baseB >= expect && cc.msgs - baseC >= expect) break;
    if (Date.now() - Math.max(cb.lastAt, cc.lastAt, t0) > IDLE_STALL_MS) {
      stalled = { b: cb.msgs - baseB, c: cc.msgs - baseC };
      break;
    }
    await new Promise((r) => setTimeout(r, 100));
  }

  let q = null;
  for (let i = 0; i < DRAIN_MS / 100; i++) {
    q = await api(`/api/chats/${grp.chatId}/fanout`, { token: a.token });
    if (q.ok && q.pending === 0) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  const totalSec = (Date.now() - t0) / 1000;
  const ok = !!lastAck && cb.msgs - baseB === expect && cc.msgs - baseC === expect && q?.pending === 0;
  if (!ok) bad++;
  if (!ok || ROUNDS <= 20) console.log(
    `round ${round}: ${ok ? "OK" : "BAD"} sent=${expect} ack=${!!lastAck} ` +
    `b=${cb.msgs - baseB} c=${cc.msgs - baseC} pending=${q?.pending} oldestMs=${q?.oldestMs} ` +
    `sendRate=${(COUNT / sendSec).toFixed(0)}/s total=${totalSec.toFixed(1)}s ` +
    `socketOpen=${ca.ws.readyState === WebSocket.OPEN}` +
    (stalled ? ` idle ${IDLE_STALL_MS}ms at ${JSON.stringify(stalled)}` : "")
  );
  if (GAP_MS > 0) await new Promise((r) => setTimeout(r, Math.random() * GAP_MS));
}
console.log(`TOTAL rounds=${ROUNDS} bad=${bad}`);
ca.ws.close(); cb.ws.close(); cc.ws.close();
process.exit(bad ? 1 : 0);
