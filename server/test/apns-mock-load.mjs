#!/usr/bin/env node
// Load test for tools/apns-mock.mjs: drives the mock far above the rate its
// worker pool can deliver and checks that the pool holds.
//
// The point is the host, not the mock. `xcrun simctl push` is a CoreSimulator
// client and every live client holds an IOSurface slot machine-wide; a mock
// that spawns one per push takes the whole machine down with it once a burst
// piles up. So the assertions are: the number of live child processes never
// exceeds the configured concurrency, the backlog stays bounded, and every
// push the mock accepted ends in exactly one terminal counter.
//
// `xcrun` is shimmed with a script that sleeps, so the test needs no simulator
// and never touches one.
//
// Run: node test/apns-mock-load.mjs
import http from "node:http";
import { spawn, execFileSync } from "node:child_process";
import { mkdtemp, writeFile, chmod, rm, readFile, open } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const MOCK = path.join(here, "..", "tools", "apns-mock.mjs");

const PORT = Number(process.env.MOCK_PORT ?? 9879);
const CONCURRENCY = 4;
const QUEUE = 32;
const TOTAL = 400; // pushes to fire
const RATE_MS = 10; // one push every 10ms ≈ 100/s
const CHILD_MS = 300; // how long the shimmed `xcrun` runs

let failures = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? "  — " + detail : ""}`);
  if (!ok) failures++;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// a fresh connection per request: keep-alive pooling under this rate produces
// resets that have nothing to do with what is being measured
const agent = new http.Agent({ keepAlive: false });

function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: "127.0.0.1", port: PORT, method, path, agent },
      (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => resolve(data));
      }
    );
    req.on("error", reject);
    req.end(body);
  });
}

async function main() {
  const dir = await mkdtemp(path.join(tmpdir(), "apns-mock-load-"));
  const shim = path.join(dir, "xcrun");
  await writeFile(shim, `#!/bin/sh\nexec sleep ${CHILD_MS / 1000}\n`);
  await chmod(shim, 0o755);

  // the mock's output goes to a file, not to a pipe: stdout pipes are
  // synchronous on macOS, so a reader that stalls would stall the mock and the
  // test would measure the harness instead of the pool
  const logPath = path.join(dir, "mock.log");
  const logFd = await open(logPath, "w");
  const mock = spawn(process.execPath, [
    MOCK, "--port", String(PORT), "--concurrency", String(CONCURRENCY),
    "--queue", String(QUEUE), "--min-delay", "0", "--max-delay", "0",
    "--stats-every", "1000",
  ], {
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
    stdio: ["ignore", logFd.fd, logFd.fd],
  });
  await sleep(400);

  // Sample live children of the mock while the burst runs. `pgrep` is a
  // process of its own, so this cannot be tight: sampling every 25ms starves
  // the machine and the test ends up measuring its own sampler.
  let peakChildren = 0;
  const sampler = setInterval(() => {
    let out = "";
    try {
      out = execFileSync("pgrep", ["-P", String(mock.pid)], { encoding: "utf8" });
    } catch {
      return; // pgrep exits 1 when there are none
    }
    const n = out.trim().split("\n").filter(Boolean).length;
    if (n > peakChildren) peakChildren = n;
  }, 200);

  for (let i = 0; i < TOTAL; i++) {
    await request("POST", "/3/device/sim-udid",
      JSON.stringify({ aps: { alert: "x" }, chatId: `c${i}`, seq: i }));
    await sleep(RATE_MS);
  }

  // let the pool drain
  let stats;
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    stats = JSON.parse(await request("GET", "/stats"));
    if (stats.queued === 0 && stats.active === 0) break;
    await sleep(100);
  }
  clearInterval(sampler);
  await sleep(200);
  const log = await readFile(logPath, "utf8");

  console.log(JSON.stringify(stats));
  const terminal = stats.delivered + stats.failed + stats.droppedRate + stats.droppedOverflow;
  check("every accepted push has a terminal state", terminal === stats.accepted,
    `accepted=${stats.accepted} terminal=${terminal}`);
  check("mock accepted everything sent", stats.accepted === TOTAL, `accepted=${stats.accepted}`);
  check("pool never exceeded its concurrency", stats.peakActive <= CONCURRENCY,
    `peakActive=${stats.peakActive}`);
  check("live child processes stayed under the cap", peakChildren > 0 && peakChildren <= CONCURRENCY,
    `peak observed=${peakChildren}, cap=${CONCURRENCY}`);
  check("backlog stayed bounded", stats.peakQueued <= QUEUE, `peakQueued=${stats.peakQueued}`);
  check("overload actually happened", stats.droppedOverflow > 0,
    `droppedOverflow=${stats.droppedOverflow} — raise TOTAL/RATE if this is 0`);
  const dropLines = log.split("\n").filter((l) => l.includes("DROP overflow"));
  check("overload is announced in the log", dropLines.length > 0);
  check("drop reporting is throttled, not one line per push",
    dropLines.length < stats.droppedOverflow,
    `lines=${dropLines.length} drops=${stats.droppedOverflow}`);
  check("drop lines carry a running count",
    dropLines.every((l) => /droppedOverflow=\d+/.test(l)), dropLines[0] ?? "");
  // the pool line printed after the queue drained is the log's accounting: it
  // has to name the same totals /stats reports
  const poolLines = log.split("\n").filter((l) => l.includes("pool accepted="));
  const last = poolLines[poolLines.length - 1] ?? "";
  check("the log accounts for every push the mock accepted",
    last.includes(`accepted=${stats.accepted}`)
    && last.includes(`delivered=${stats.delivered}`)
    && last.includes(`overflow=${stats.droppedOverflow}`), last);

  mock.kill("SIGKILL");
  await logFd.close();
  await rm(dir, { recursive: true, force: true });
  console.log(failures ? `\n${failures} check(s) failed` : "\nall checks passed");
  process.exit(failures ? 1 : 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
