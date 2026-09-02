#!/usr/bin/env node
// An HTTP/1.1 → HTTP/2 relay in front of APNs for the stand.
//
// APNs speaks HTTP/2 only (its TLS endpoint refuses ALPN http/1.1 and closes the
// connection), while workerd's outbound fetch is HTTP/1.1, so a Worker cannot
// post to api.push.apple.com itself. The Worker posts the same APNs-shaped
// request to this relay instead (APNS_HOST=http://127.0.0.1:9872), and the relay
// forwards it over one HTTP/2 session, adding the provider token it signs with
// the p8 key. The status and body Apple answers with go back unchanged, so the
// Worker's handling of 400/403/410/429 stays the same.
//
// Environment:
//   APNS_KEY_FILE   path to the .p8 (or APNS_KEY_P8 with the PEM inline)
//   APNS_KEY_ID     the key id (kid)
//   APNS_TEAM_ID    the team id (iss)
//   APNS_UPSTREAM   default https://api.sandbox.push.apple.com
//   PORT            default 9872
import http from "node:http";
import http2 from "node:http2";
import { readFileSync } from "node:fs";
import { createSign, createPrivateKey } from "node:crypto";

const PORT = Number(process.env.PORT ?? 9872);
const UPSTREAM = process.env.APNS_UPSTREAM ?? "https://api.sandbox.push.apple.com";
const KEY_ID = process.env.APNS_KEY_ID;
const TEAM_ID = process.env.APNS_TEAM_ID;
const PEM = process.env.APNS_KEY_FILE
  ? readFileSync(process.env.APNS_KEY_FILE, "utf8")
  : (process.env.APNS_KEY_P8 ?? "").replace(/\\n/g, "\n");
if (!KEY_ID || !TEAM_ID || !PEM) {
  console.error("apns-relay: APNS_KEY_ID, APNS_TEAM_ID and APNS_KEY_FILE (or APNS_KEY_P8) are required");
  process.exit(2);
}
const key = createPrivateKey(PEM);

// Apple accepts a provider token for an hour and asks for at most one new one
// every 20 minutes; a token is reused for 50 minutes here.
const TOKEN_TTL_MS = 50 * 60 * 1000;
let token = null;
let tokenAt = 0;
function providerToken(force = false) {
  const now = Date.now();
  if (!force && token && now - tokenAt < TOKEN_TTL_MS) return token;
  const b64 = (s) => Buffer.from(s).toString("base64url");
  const header = b64(JSON.stringify({ alg: "ES256", kid: KEY_ID }));
  const payload = b64(JSON.stringify({ iss: TEAM_ID, iat: Math.floor(now / 1000) }));
  const sig = createSign("SHA256")
    .update(`${header}.${payload}`)
    .sign({ key, dsaEncoding: "ieee-p1363" });
  token = `${header}.${payload}.${sig.toString("base64url")}`;
  tokenAt = now;
  return token;
}

// One HTTP/2 session to Apple, reopened when it drops.
let session = null;
function upstream() {
  if (session && !session.closed && !session.destroyed) return session;
  session = http2.connect(UPSTREAM);
  session.on("error", (e) => console.log(`apns-relay: session error: ${e.message}`));
  session.on("close", () => { session = null; });
  return session;
}

const FORWARDED = ["apns-topic", "apns-push-type", "apns-priority", "apns-collapse-id", "apns-expiration", "apns-id", "content-type"];

function forward(path, headers, body, retryOnExpired = true) {
  return new Promise((resolve) => {
    const h = { ":method": "POST", ":path": path, authorization: `bearer ${providerToken()}` };
    for (const name of FORWARDED) if (headers[name] !== undefined) h[name] = headers[name];
    let req;
    try {
      req = upstream().request(h);
    } catch (e) {
      return resolve({ status: 502, body: JSON.stringify({ reason: `relay: ${e.message}` }) });
    }
    let status = 502;
    let data = "";
    req.on("response", (rh) => { status = rh[":status"]; });
    req.on("data", (d) => { data += d; });
    req.on("error", (e) => resolve({ status: 502, body: JSON.stringify({ reason: `relay: ${e.message}` }) }));
    req.on("end", async () => {
      if (status === 403 && retryOnExpired && /ExpiredProviderToken/.test(data)) {
        providerToken(true);
        return resolve(await forward(path, headers, body, false));
      }
      resolve({ status, body: data });
    });
    req.end(body);
  });
}

const stats = { received: 0, byStatus: {} };

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/stats") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify(stats));
  }
  if (req.method !== "POST" || !req.url.startsWith("/3/device/")) {
    res.writeHead(404);
    return res.end();
  }
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks);
  stats.received++;
  const { status, body: answer } = await forward(req.url, req.headers, body);
  stats.byStatus[status] = (stats.byStatus[status] ?? 0) + 1;
  const tail = req.url.slice(-8);
  console.log(`apns-relay: …${tail} ${req.headers["apns-topic"] ?? "-"} → ${status}${answer ? " " + answer : ""}`);
  res.writeHead(status, { "content-type": "application/json" });
  res.end(answer);
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`apns-relay: listening on 127.0.0.1:${PORT}, upstream ${UPSTREAM}, team ${TEAM_ID}, key ${KEY_ID}`);
});
