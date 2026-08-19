// A burst of messages and the ticks it earns, measured on the server alone.
//
// One sender fires the burst into a direct chat as fast as its socket takes it;
// the recipient answers the way the app does — one `recv` per pass carrying the
// largest seq of the pass. The run reports how far apart the messages landed on
// the recipient and how long each of them took to earn the author's second
// tick, and fails when either number is worse than what the product promises.
//
//   BASE_URL=http://localhost:8813 PUSH_PORT=9883 node test/tick-burst.mjs [count]
//
// The recipient has a push token, because a burst on a real device does: every
// content message raises a push, and the frame delivery of the chat must not
// wait for it. The test owns the APNs endpoint the stand was started with
// (`--var APNS_HOST:http://localhost:$PUSH_PORT`) and answers on it with the
// latency of the real thing, so a push that is waited for shows up as a burst
// spread out in time.
import WebSocket from "ws";
import http from "node:http";

const BASE = process.env.BASE_URL ?? "http://localhost:8813";
const WS_BASE = BASE.replace(/^http/, "ws");
const PUSH_PORT = Number(process.env.PUSH_PORT ?? 9883);
const COUNT = Number(process.argv[2] ?? 100);
/// What one APNs call costs. Apple answers in this order of magnitude, and the
/// point of the run is that the number never becomes the delivery rate of a chat.
const PUSH_LATENCY_MS = Number(process.env.PUSH_LATENCY_MS ?? 150);
/// The whole burst has to be on the recipient's screen inside this.
const LAND_MS = Number(process.env.LAND_MS ?? 3_000);
/// A message's second tick, counted from the moment that message arrived. The
/// author watches the ticks move while the burst lands, not once it is over.
const TICK_MS = Number(process.env.TICK_MS ?? 1_500);
/// The wait ends here whatever happened, so a stuck run reports instead of hanging.
const WAIT_MS = Number(process.env.WAIT_MS ?? 180_000);
/// Nothing arrived and no mark moved for this long: the queue is standing still.
const IDLE_MS = Number(process.env.IDLE_MS ?? 20_000);

async function api(path, { token, body, method } = {}) {
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

/// APNs as the stand sees it: a 200 after PUSH_LATENCY_MS.
const pushes = [];
const apns = http.createServer((req, res) => {
  req.resume();
  req.on("end", () => {
    const at = Date.now();
    setTimeout(() => {
      pushes.push({ at, answered: Date.now() });
      res.writeHead(200, { "apns-id": String(pushes.length) });
      res.end();
    }, PUSH_LATENCY_MS);
  });
});
await new Promise((r) => apns.listen(PUSH_PORT, r));

class Client {
  constructor(token) {
    this.token = token;
    this.frames = [];
  }
  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`${WS_BASE}/ws?token=${this.token}&v=1`);
      this.ws.on("message", (d) => {
        const f = JSON.parse(d.toString());
        f._at = Date.now();
        this.frames.push(f);
        this.onFrame?.(f);
      });
      this.ws.on("open", resolve);
      this.ws.on("error", reject);
    });
  }
  send(f) { this.ws.send(JSON.stringify(f)); }
  async waitFor(pred, ms = 10_000) {
    const t0 = Date.now();
    for (;;) {
      const f = this.frames.find(pred);
      if (f) return f;
      if (Date.now() - t0 > ms) return null;
      await new Promise((r) => setTimeout(r, 20));
    }
  }
}

function stats(values) {
  if (!values.length) return { n: 0, min: 0, p50: 0, p90: 0, max: 0, mean: 0 };
  const s = [...values].sort((x, y) => x - y);
  const at = (q) => s[Math.min(s.length - 1, Math.floor(q * s.length))];
  return {
    n: s.length, min: s[0], p50: at(0.5), p90: at(0.9), max: s[s.length - 1],
    mean: Math.round(values.reduce((x, y) => x + y, 0) / values.length),
  };
}

const suffix = Math.random().toString(36).slice(2, 8);
const a = await api("/api/register", {
  body: { username: "ta_" + suffix, displayName: "TA", ...fakeKeys("a") },
});
const b = await api("/api/register", {
  body: { username: "tb_" + suffix, displayName: "TB", ...fakeKeys("b") },
});
const chat = await api("/api/chats", {
  token: a.token, body: { kind: "direct", memberIds: [b.userId] },
});
// an unaccepted request earns no receipts at all — the recipient is invisible to
// the author until then, so the burst is measured on an accepted chat
await api(`/api/chats/${chat.chatId}/accept`, { token: b.token, body: {} });
await api("/api/push-token", {
  token: b.token, body: { apnsToken: "burst-token-" + suffix, env: "sandbox" },
});

const ca = new Client(a.token);
const cb = new Client(b.token);

/// What the recipient does with a burst: one receipt per pass, carrying the
/// largest seq of the pass. A pass is a macrotask here — the frames the socket
/// handed over before the loop came back around, which is the coalescing the
/// app's sync engine does per run of the receive path.
const arrivedAt = new Map(); // seq -> when the recipient had it
let pendingTop = 0;
let scheduled = false;
cb.onFrame = (f) => {
  if (f.t !== "msg" || f.from === b.userId) return;
  if (!arrivedAt.has(f.seq)) arrivedAt.set(f.seq, f._at);
  pendingTop = Math.max(pendingTop, f.seq);
  if (scheduled) return;
  scheduled = true;
  setTimeout(() => {
    scheduled = false;
    cb.send({ t: "recv", chatId: chat.chatId, seqs: [pendingTop] });
  }, 0);
};

const tickedAt = new Map(); // seq -> when the author could show the second tick
let marked = 0;
ca.onFrame = (f) => {
  if (f.t !== "receipt" || f.kind !== "delivered") return;
  for (let s = marked + 1; s <= f.upToSeq; s++) tickedAt.set(s, f._at);
  marked = Math.max(marked, f.upToSeq);
};

await ca.connect();
await cb.connect();
await ca.waitFor((f) => f.t === "hello");
await cb.waitFor((f) => f.t === "hello");

const t0 = Date.now();
for (let i = 0; i < COUNT; i++) {
  ca.send({
    t: "send", chatId: chat.chatId, clientMsgId: `burst-${i}`, sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: { [`${b.userId}/${b.deviceId}`]: { type: "dr", c: "ZmFrZQ" } } },
  });
}
const lastAck = await ca.waitFor(
  (f) => f.t === "sent" && f.clientMsgId === `burst-${COUNT - 1}`, 60_000);
const ackMs = Date.now() - t0;
const lastSeq = lastAck?.seq ?? 0;
const firstSeq = lastSeq - COUNT + 1;

let lastProgress = Date.now();
let prevArrived = 0, prevMarked = 0;
while (Date.now() - t0 < WAIT_MS) {
  if (arrivedAt.size >= COUNT && marked >= lastSeq) break;
  if (arrivedAt.size !== prevArrived || marked !== prevMarked) {
    prevArrived = arrivedAt.size;
    prevMarked = marked;
    lastProgress = Date.now();
  }
  if (Date.now() - lastProgress > IDLE_MS) break;
  await new Promise((r) => setTimeout(r, 50));
}
// the last receipts are still in flight when the counts line up
await new Promise((r) => setTimeout(r, 300));

const seqs = [];
for (let s = firstSeq; s <= lastSeq; s++) seqs.push(s);
const landed = seqs.filter((s) => arrivedAt.has(s));
const gaps = landed.slice(1).map((s, i) => arrivedAt.get(s) - arrivedAt.get(landed[i]));
const lag = seqs
  .filter((s) => arrivedAt.has(s) && tickedAt.has(s))
  .map((s) => tickedAt.get(s) - arrivedAt.get(s));
const g = stats(gaps);
const l = stats(lag);
const landMs = landed.length ? arrivedAt.get(landed[landed.length - 1]) - t0 : -1;

console.log(`burst of ${COUNT}, APNs answering in ${PUSH_LATENCY_MS}ms`);
console.log(`  ack of the last send: ${ackMs}ms`);
console.log(`  landed on the recipient: ${landed.length}/${COUNT} in ${landMs}ms`);
console.log(`  gap between arrivals: min=${g.min} p50=${g.p50} p90=${g.p90} max=${g.max} mean=${g.mean}`);
console.log(`  second ticks: ${lag.length}/${COUNT}, lag after arrival ` +
  `min=${l.min} p50=${l.p50} p90=${l.p90} max=${l.max} mean=${l.mean}`);
console.log(`  pushes APNs took: ${pushes.length}`);
const q = await api(`/api/chats/${chat.chatId}/fanout`, { token: a.token });
console.log(`  fanout queue: pending=${q.pending} cursor=${q.cursor} oldestMs=${q.oldestMs} armed=${q.armed}`);

const problems = [];
if (landed.length !== COUNT) problems.push(`${COUNT - landed.length} messages never arrived`);
if (landMs > LAND_MS) problems.push(`the burst took ${landMs}ms to land, over ${LAND_MS}ms`);
if (lag.length !== COUNT) problems.push(`${COUNT - lag.length} messages earned no second tick`);
if (l.max > TICK_MS) problems.push(`a tick waited ${l.max}ms after its message arrived, over ${TICK_MS}ms`);
for (const p of problems) console.log(`  BAD: ${p}`);
console.log(problems.length ? "BAD" : "OK");

ca.ws.close();
cb.ws.close();
apns.close();
process.exit(problems.length ? 1 : 0);
