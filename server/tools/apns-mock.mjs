#!/usr/bin/env node
// Мок APNs для dev-стенда: принимает APNs-совместимые POST /3/device/{token}
// и доставляет payload в iOS-симулятор через `xcrun simctl push`.
// token в dev = UDID симулятора. Ответ 200 уходит сразу (как у настоящего
// APNs), сама доставка — асинхронно, со случайной задержкой.
//
// Запуск:  node tools/apns-mock.mjs [--port 9871] [--drop-rate 0.05]
//          [--min-delay 150] [--max-delay 500] [--bundle ai.enface.Msngr] [--log]
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
const DROP_RATE = Number(opt("--drop-rate", 0)); // доля молча съеденных пушей
const MIN_DELAY = Number(opt("--min-delay", 150));
const MAX_DELAY = Number(opt("--max-delay", 500));
const BUNDLE = opt("--bundle", "ai.enface.Msngr");
const LOG = args.includes("--log");

const ts = () => new Date().toISOString().slice(11, 23);
const log = (...a) => console.log(ts(), ...a);

function deliver(token, rawBody, chatId) {
  const delay = Math.round(MIN_DELAY + Math.random() * (MAX_DELAY - MIN_DELAY));
  if (Math.random() < DROP_RATE) {
    log(`DROP token=${token.slice(0, 8)}… chat=${chatId}`);
    return;
  }
  setTimeout(async () => {
    const file = path.join(tmpdir(), `apns-mock-${randomUUID()}.json`);
    try {
      // simctl push ждёт JSON-файл с верхнеуровневым "aps" — это ровно
      // полученное APNs-тело
      await writeFile(file, rawBody);
      const child = spawn("xcrun", ["simctl", "push", token, BUNDLE, file]);
      let stderr = "";
      child.stderr.on("data", (d) => (stderr += d));
      child.on("close", (code) => {
        unlink(file).catch(() => {});
        if (code !== 0) {
          // симулятор выключен / UDID не найден — логируем, не падаем
          log(`simctl push failed (${code}) token=${token.slice(0, 8)}…`, stderr.trim());
        } else if (LOG) {
          log(`push token=${token.slice(0, 8)}… chat=${chatId} delay=${delay}ms`);
        }
      });
      child.on("error", (e) => {
        unlink(file).catch(() => {});
        log("simctl spawn error:", e.message);
      });
    } catch (e) {
      log("deliver error:", e.message);
    }
  }, delay);
}

const server = http.createServer((req, res) => {
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
    deliver(token, body, parsed.chatId ?? "?");
  });
});

server.listen(PORT, () => {
  log(`apns-mock on :${PORT} → xcrun simctl push (bundle ${BUNDLE}), ` +
    `delay ${MIN_DELAY}–${MAX_DELAY}ms, drop-rate ${DROP_RATE}`);
});
