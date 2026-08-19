// Probe: chats with APNs fully down, and pushes catching up when it returns.
//
// Nothing listens on the stand's APNs port while a burst goes through: every
// frame still has to land on the recipient's live socket at once and every
// message has to earn its delivered receipt. Then the endpoint comes up and
// the pushes owed have to arrive — one per message, none lost, none doubled.
//
//   BASE_URL=http://localhost:8833 PUSH_PORT=9893 node test/probe-apns-down.mjs [count]
//
// PUSH_PORT must be the port the stand's APNS_HOST points at, and nothing
// else may own it while this runs.
import WebSocket from "ws";
import http from "node:http";

const BASE = process.env.BASE_URL ?? "http://localhost:8833";
const WS_BASE = BASE.replace(/^http/, "ws");
const PUSH_PORT = Number(process.env.PUSH_PORT ?? 9893);
const COUNT = Number(process.argv[2] ?? 10);
/// The whole burst must be on the recipient's socket inside this, APNs or not.
const LAND_MS = Number(process.env.LAND_MS ?? 3_000);
/// How long the pushes owed are given to catch up once the endpoint is back.
const CATCHUP_MS = Number(process.env.CATCHUP_MS ?? 90_000);

async function api(path, { token, body } = {}) {
  const r = await fetch(BASE + path, {
    method: body !== undefined ? "POST" : "GET",
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
    oneTimePrekeys: [{ id: 1, key: "otp1_" + n }],
  };
}

const suffix = Math.random().toString(36).slice(2, 8);
const a = await api("/api/register", { body: { username: "da_" + suffix, displayName: "A", ...fakeKeys("a") } });
const b = await api("/api/register", { body: { username: "db_" + suffix, displayName: "B", ...fakeKeys("b") } });
const chat = await api("/api/chats", { token: a.token, body: { kind: "direct", memberIds: [b.userId] } });
await api(`/api/chats/${chat.chatId}/accept`, { token: b.token, body: {} });
await api("/api/push-token", { token: b.token, body: { apnsToken: "down-" + suffix, env: "sandbox" } });

const wsA = new WebSocket(`${WS_BASE}/ws?token=${a.token}&v=1`);
const wsB = new WebSocket(`${WS_BASE}/ws?token=${b.token}&v=1`);
const framesA = [], framesB = [];
await Promise.all([
  new Promise((res, rej) => { wsA.on("open", res); wsA.on("error", rej); }),
  new Promise((res, rej) => { wsB.on("open", res); wsB.on("error", rej); }),
]);
wsA.on("message", (d) => framesA.push({ ...JSON.parse(d.toString()), _at: Date.now() }));
wsB.on("message", (d) => framesB.push({ ...JSON.parse(d.toString()), _at: Date.now() }));

// the recipient acks what lands, the way the app does
wsB.on("message", (d) => {
  const f = JSON.parse(d.toString());
  if (f.t === "msg" && f.from !== b.userId) {
    wsB.send(JSON.stringify({ t: "recv", chatId: chat.chatId, seqs: [f.seq] }));
  }
});

// APNs is down: nothing listens on PUSH_PORT while the burst flies
const t0 = Date.now();
for (let i = 0; i < COUNT; i++) {
  wsA.send(JSON.stringify({
    t: "send", chatId: chat.chatId, clientMsgId: `down-${i}`, sentAt: Date.now(),
    body: { v: 1, mode: "pw", msgs: { [`${b.userId}/${b.deviceId}`]: { type: "dr", c: "ZmFrZQ" } } },
  }));
}

const landDeadline = t0 + LAND_MS;
while (Date.now() < landDeadline) {
  const got = framesB.filter((f) => f.t === "msg" && f.from === a.userId).length;
  const ticked = framesA.filter((f) => f.t === "receipt" && f.kind === "delivered").length;
  if (got >= COUNT && ticked > 0) break;
  await new Promise((r) => setTimeout(r, 50));
}
const landed = framesB.filter((f) => f.t === "msg" && f.from === a.userId);
const landMs = landed.length ? landed[landed.length - 1]._at - t0 : -1;
const receipts = framesA.filter((f) => f.t === "receipt" && f.kind === "delivered");
const tickedUpTo = receipts.length ? Math.max(...receipts.map((f) => f.upToSeq)) : 0;
const lastSeq = landed.length ? Math.max(...landed.map((f) => f.seq)) : 0;
console.log(`APNs down: landed ${landed.length}/${COUNT} in ${landMs}ms, ` +
  `delivered receipt up to seq ${tickedUpTo} of ${lastSeq}`);

// the endpoint comes back: every push owed has to arrive, each message once
const pushedMsgIds = [];
const apns = http.createServer((req, res) => {
  let raw = "";
  req.on("data", (c) => (raw += c));
  req.on("end", () => {
    try { pushedMsgIds.push(JSON.parse(raw).msgId ?? "?"); } catch { pushedMsgIds.push("?"); }
    res.writeHead(200, { "apns-id": String(pushedMsgIds.length) });
    res.end();
  });
});
await new Promise((r) => apns.listen(PUSH_PORT, r));
const upAt = Date.now();

const sentMsgIds = new Set(landed.map((f) => f.msgId));
const catchupDeadline = Date.now() + CATCHUP_MS;
while (Date.now() < catchupDeadline) {
  if (new Set(pushedMsgIds).size >= sentMsgIds.size) break;
  await new Promise((r) => setTimeout(r, 250));
}
// a beat for a straggler that would show up as a double
await new Promise((r) => setTimeout(r, 1500));

const uniquePushed = new Set(pushedMsgIds);
const missing = [...sentMsgIds].filter((id) => !uniquePushed.has(id));
const doubled = pushedMsgIds.length - uniquePushed.size;
console.log(`APNs back: ${uniquePushed.size}/${sentMsgIds.size} messages pushed ` +
  `in ${Date.now() - upAt}ms, ${doubled} duplicate push(es)`);

const problems = [];
if (landed.length !== COUNT) problems.push(`${COUNT - landed.length} frames never landed with APNs down`);
if (landMs > LAND_MS) problems.push(`the burst took ${landMs}ms to land, over ${LAND_MS}ms`);
if (tickedUpTo < lastSeq) problems.push(`delivered receipt stuck at ${tickedUpTo} of ${lastSeq}`);
if (missing.length) problems.push(`${missing.length} push(es) never caught up`);
if (doubled > 0) problems.push(`${doubled} duplicate push(es) after recovery`);
for (const p of problems) console.log(`  BAD: ${p}`);
console.log(problems.length ? "BAD" : "OK");
wsA.close(); wsB.close(); apns.close();
process.exit(problems.length ? 1 : 0);
