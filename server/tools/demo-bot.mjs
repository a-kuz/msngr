// A bot, as one would actually be written: a socket, a token, and plaintext
// content. Reads what is written to it and answers; a pressed button arrives
// as a `callback`.
//
//   node bot.mjs <token> [base]
import WebSocket from "ws";

const token = process.argv[2];
const http = process.argv[3] ?? "https://msngr.a-kuz.online";
const base = http.replace(/^http/, "ws");

// A bot walks in through the same door as a device, so it hears its own
// messages back the way a second phone would. Every bot has to know its own id
// and skip them — without that the first answer it sends comes straight back to
// it and it answers itself forever.
const me = await fetch(`${http}/api/me`, { headers: { authorization: `Bearer ${token}` } })
  .then((r) => r.json());
const selfId = me.user?.id ?? me.userId;
console.log("bot is", selfId);

const ws = new WebSocket(`${base}/ws?token=${token}&v=1`);

const plain = (p) => ({ v: 1, mode: "plain", p });
let n = 0;
const send = (chatId, p, service = false) =>
  ws.send(JSON.stringify({
    t: "send", chatId, clientMsgId: `bot-${Date.now()}-${n++}`,
    // seconds, the way a client sends it: this is the clock the feed reads
    sentAt: Date.now() / 1000, body: plain(p), service,
  }));

ws.on("open", () => console.log("bot connected"));
ws.on("message", (raw) => {
  const f = JSON.parse(raw.toString());
  if (f.t === "sent" || f.t === "hello") return;
  if (f.t !== "msg" || !f.body?.p || f.from === selfId) return;
  const { kind, text, data } = f.body.p;
  console.log("<-", kind, text ?? data ?? "");
  if (kind === "callback") {
    send(f.chatId, { kind: "text", text: data === "y" ? "Рад слышать." : "Ладно, в другой раз." });
    return;
  }
  if (text === "/start") {
    send(f.chatId, {
      kind: "text",
      text: "Привет! Я живу на сокете и читаю всё, что здесь написано.",
      buttons: [[{ text: "Нравится", data: "y" }, { text: "Не очень", data: "n" }]],
    });
  } else if (text === "/help") {
    send(f.chatId, { kind: "text", text: "/start — начать, /help — эта строка." });
  } else if (text) {
    send(f.chatId, { kind: "text", text: `Вы написали: ${text}` });
  }
});
ws.on("error", (e) => console.log("error", String(e)));
ws.on("close", () => console.log("closed"));
