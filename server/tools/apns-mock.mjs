#!/usr/bin/env node
// An APNs mock for the dev stand: it takes APNs-shaped POST /3/device/{token}
// and delivers the payload into an iOS simulator through `xcrun simctl push`.
// On the dev stand the token is the simulator's UDID. The 200 goes back at once,
// as real APNs does, while delivery happens asynchronously after a random delay.
//
// Delivery runs through a bounded worker pool. `xcrun simctl push` is a
// CoreSimulator client, and every live client holds an IOSurface slot on the
// host; a burst that spawns one process per push exhausts that pool (limit is
// about 1020 machine-wide) and then every CoreSimulator client on the machine
// — simctl, xcodebuild, screenshots — fails to start until the processes
// drain. So the pool caps how many run at once and the backlog is bounded too:
// a mock that queues without limit only postpones the same pile-up.
//
// Run:     node tools/apns-mock.mjs [--port 9871] [--drop-rate 0.05]
//          [--min-delay 150] [--max-delay 500] [--bundle msngr.msngr] [--log]
//          [--concurrency 4] [--queue 256] [--stats-every 5000]
//
// GET /stats answers with the counters, so a test can assert that every push
// the mock accepted is accounted for.
import http from "node:http";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { writeFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const args = process.argv.slice(2);
function opt(name, def) {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : def;
}
const PORT = Number(opt("--port", 9871));
const DROP_RATE = Number(opt("--drop-rate", 0)); // share of pushes swallowed silently
const MIN_DELAY = Number(opt("--min-delay", 150));
const MAX_DELAY = Number(opt("--max-delay", 500));
const BUNDLE = opt("--bundle", "msngr.msngr");
const LOG = args.includes("--log");
/// How many `xcrun simctl push` processes may run at once.
const CONCURRENCY = Math.max(1, Number(opt("--concurrency", 4)));
/// How many pushes may wait for a free worker before the mock starts dropping.
const QUEUE_LIMIT = Math.max(1, Number(opt("--queue", 256)));
/// How often the pool reports itself while it has work.
const STATS_EVERY = Number(opt("--stats-every", 5000));

const ts = () => new Date().toISOString().slice(11, 23);
const log = (...a) => console.log(ts(), ...a);

/// Every push the mock accepted ends up in exactly one terminal counter:
/// delivered + failed + droppedRate + droppedOverflow === accepted.
const stats = {
  accepted: 0,
  delivered: 0,
  failed: 0,
  droppedRate: 0,
  droppedOverflow: 0,
  get queued() {
    return queue.length;
  },
  get active() {
    return active;
  },
  get peakQueued() {
    return peakQueued;
  },
  get peakActive() {
    return peakActive;
  },
};

const queue = [];
let active = 0;
let peakQueued = 0;
let peakActive = 0;
let statsTimer = null;

function statsLine() {
  return `accepted=${stats.accepted} delivered=${stats.delivered} ` +
    `failed=${stats.failed} dropped=${stats.droppedRate + stats.droppedOverflow} ` +
    `(rate=${stats.droppedRate} overflow=${stats.droppedOverflow}) ` +
    `queued=${queue.length} active=${active} peak(queued=${peakQueued} active=${peakActive})`;
}

/// Reports the pool while it has work, so a backlog that builds up is visible
/// in the log without polling /stats.
function scheduleStats() {
  if (statsTimer || STATS_EVERY <= 0) return;
  statsTimer = setInterval(() => log("pool", statsLine()), STATS_EVERY);
  statsTimer.unref?.();
}

/// The accounting of a finished burst, printed the moment the pool goes idle.
function reportIdle() {
  if (statsTimer) {
    clearInterval(statsTimer);
    statsTimer = null;
  }
  log("pool", statsLine());
}

/// Overload is reported at its start and then at most once a second, always
/// with the running total. A line per dropped push would be the louder answer
/// and the wrong one: on stdout, which is a synchronous pipe on macOS, a flood
/// of lines blocks the mock's own event loop and stalls the pool it describes.
let lastDropLog = 0;
function reportDrop(job) {
  const now = Date.now();
  if (now - lastDropLog < 1000) return;
  lastDropLog = now;
  log(`DROP overflow token=${job.token.slice(0, 8)}… chat=${job.chatId} ` +
    `queue=${QUEUE_LIMIT} droppedOverflow=${stats.droppedOverflow}`);
}

function enqueue(job) {
  if (queue.length >= QUEUE_LIMIT) {
    // dropping the oldest keeps the freshest notifications, which is what a
    // burst is judged by; the count says how much of the burst never reached
    // the simulator, so a hole in a run is not mistaken for a product defect
    const lost = queue.shift();
    stats.droppedOverflow++;
    reportDrop(lost);
  }
  queue.push(job);
  if (queue.length > peakQueued) peakQueued = queue.length;
  scheduleStats();
  pump();
}

function pump() {
  while (active < CONCURRENCY && queue.length) {
    const job = queue.shift();
    active++;
    if (active > peakActive) peakActive = active;
    run(job).finally(() => {
      active--;
      pump();
    });
  }
  if (queue.length === 0 && active === 0) reportIdle();
}

/// One `xcrun simctl push`. Resolves when the child is gone — the pool counts
/// live processes, so it must not release the slot before that.
function run({ token, rawBody, chatId, delay, badge }) {
  return new Promise((resolve) => {
    const file = path.join(tmpdir(), `apns-mock-${randomUUID()}.json`);
    let settled = false;
    const done = () => {
      if (settled) return;
      settled = true;
      unlink(file).catch(() => {});
      resolve();
    };
    // simctl push wants a JSON file with a top-level "aps", which is exactly
    // the APNs body that came in
    writeFile(file, rawBody).then(() => {
      const child = spawn("xcrun", ["simctl", "push", token, BUNDLE, file]);
      let stderr = "";
      child.stderr.on("data", (d) => (stderr += d));
      child.on("close", (code) => {
        if (code !== 0) {
          // simulator shut down or UDID unknown: log it rather than fall over
          stats.failed++;
          log(`simctl push failed (${code}) token=${token.slice(0, 8)}…`, stderr.trim());
        } else {
          stats.delivered++;
          // the badge and its stamp are logged at the moment of delivery: the
          // random delay reorders a burst, and the order the simulator sees is
          // the one that decides what lands on the icon
          if (LOG) log(`push token=${token.slice(0, 8)}… chat=${chatId} ` +
            `badge=${badge.value} stamp=${badge.stamp} delay=${delay}ms`);
        }
        done();
      });
      child.on("error", (e) => {
        stats.failed++;
        log("simctl spawn error:", e.message);
        done();
      });
    }).catch((e) => {
      stats.failed++;
      log("deliver error:", e.message);
      done();
    });
  });
}

function deliver(token, rawBody, chatId, badge) {
  stats.accepted++;
  const delay = Math.round(MIN_DELAY + Math.random() * (MAX_DELAY - MIN_DELAY));
  if (Math.random() < DROP_RATE) {
    stats.droppedRate++;
    log(`DROP token=${token.slice(0, 8)}… chat=${chatId} droppedRate=${stats.droppedRate}`);
    return;
  }
  setTimeout(() => enqueue({ token, rawBody, chatId, delay, badge }), delay);
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && (req.url ?? "").startsWith("/stats")) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({
      accepted: stats.accepted, delivered: stats.delivered, failed: stats.failed,
      droppedRate: stats.droppedRate, droppedOverflow: stats.droppedOverflow,
      queued: stats.queued, active: stats.active,
      peakQueued: stats.peakQueued, peakActive: stats.peakActive,
      concurrency: CONCURRENCY, queueLimit: QUEUE_LIMIT,
    }));
    return;
  }
  const m = req.method === "POST" && /^\/3\/device\/([^/]+)$/.exec(req.url ?? "");
  if (!m) {
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ reason: "BadPath" }));
    return;
  }
  const token = decodeURIComponent(m[1]);
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ reason: "PayloadEmpty" }));
      return;
    }
    res.writeHead(200, { "apns-id": randomUUID() });
    res.end();
    deliver(token, body, parsed.chatId ?? "?",
      { value: parsed.aps?.badge ?? "?", stamp: parsed.badgeStamp ?? "?" });
  });
});

process.on("SIGINT", () => {
  log("final", statsLine());
  process.exit(0);
});

server.listen(PORT, () => {
  log(`apns-mock on :${PORT} → xcrun simctl push (bundle ${BUNDLE}), ` +
    `delay ${MIN_DELAY}–${MAX_DELAY}ms, drop-rate ${DROP_RATE}, ` +
    `concurrency ${CONCURRENCY}, queue ${QUEUE_LIMIT}`);
});
