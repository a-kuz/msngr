// Probe: what the queue does when a recipient keeps failing.
// The recipient's session rejects the next N deliveries (dev fault); the sender
// fires one message and the probe watches whether it ever reaches the
// recipient's live socket, and what the queue says meanwhile.
//   BASE_URL=http://localhost:8833 node test/probe-drop.mjs [failEvents]
import WebSocket from "ws";

const BASE = process.env.BASE_URL ?? "http://localhost:8833";
const WS_BASE = BASE.replace(/^http/, "ws");
const FAIL = Number(process.argv[2] ?? 10);

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
const a = await api("/api/register", { body: { username: "pa_" + suffix, displayName: "A", ...fakeKeys("a") } });
const b = await api("/api/register", { body: { username: "pb_" + suffix, displayName: "B", ...fakeKeys("b") } });
const chat = await api("/api/chats", { token: a.token, body: { kind: "direct", memberIds: [b.userId] } });
await api(`/api/chats/${chat.chatId}/accept`, { token: b.token, body: {} });

const frames = [];
const ws = new WebSocket(`${WS_BASE}/ws?token=${b.token}&v=1`);
await new Promise((res, rej) => { ws.on("open", res); ws.on("error", rej); });
ws.on("message", (d) => frames.push({ ...JSON.parse(d.toString()), _at: Date.now() }));

await api("/api/dev/fault", { token: b.token, body: { failEvents: FAIL } });

const wsA = new WebSocket(`${WS_BASE}/ws?token=${a.token}&v=1`);
await new Promise((res, rej) => { wsA.on("open", res); wsA.on("error", rej); });

const t0 = Date.now();
wsA.send(JSON.stringify({
  t: "send", chatId: chat.chatId, clientMsgId: "probe-1", sentAt: Date.now(),
  body: { v: 1, mode: "pw", msgs: {} },
}));

for (let i = 0; i < 40; i++) {
  await new Promise((r) => setTimeout(r, 500));
  const q = await api(`/api/chats/${chat.chatId}/fanout`, { token: a.token });
  const got = frames.find((f) => f.t === "msg");
  console.log(`t=${Date.now() - t0}ms queue: pending=${q.pending} attempt=${q.attempt} ` +
    `oldestMs=${q.oldestMs} armed=${q.armed} | recipient got msg: ${got ? "YES at " + (got._at - t0) + "ms" : "no"}`);
  if (got || (q.pending === 0 && i > 4)) break;
}
const got = frames.find((f) => f.t === "msg");
console.log(got ? `DELIVERED after ${got._at - t0}ms` : "DROPPED: the message never reached the live socket");
ws.close();
wsA.close();
process.exit(0);
