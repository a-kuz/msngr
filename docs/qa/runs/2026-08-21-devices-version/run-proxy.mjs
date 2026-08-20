// Run tool: counts what the simulators ask the stand, and dropping it drops
// their sockets. Forwards :8804 -> :8803, one log line per request/upgrade.
import http from "node:http";
import net from "node:net";
import fs from "node:fs";

const TARGET = 8803;
const PORT = 8804;
const LOG = new URL("./run-proxy.log", import.meta.url).pathname;
const log = (line) => fs.appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`);

const server = http.createServer((req, res) => {
  log(`${req.method} ${req.url}`);
  const p = http.request(
    { host: "127.0.0.1", port: TARGET, path: req.url, method: req.method, headers: req.headers },
    (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); }
  );
  p.on("error", () => { res.writeHead(502); res.end(); });
  req.pipe(p);
});

server.on("upgrade", (req, socket, head) => {
  log(`UPGRADE ${req.url}`);
  const up = net.connect(TARGET, "127.0.0.1", () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    }
    raw += "\r\n";
    up.write(raw);
    if (head?.length) up.write(head);
    socket.pipe(up);
    up.pipe(socket);
  });
  up.on("error", () => socket.destroy());
  socket.on("error", () => up.destroy());
});

server.listen(PORT, () => log(`proxy up :${PORT} -> :${TARGET}`));
