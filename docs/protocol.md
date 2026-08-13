# Протокол

## Транспорт

- HTTP `/api/*` — auth, prekeys, профили, чаты (создание/членство), медиа (R2), контакты.
- WS `/ws?token=…&device=…` — один на устройство. JSON-фреймы `{t, ...}`.
- Auth: Bearer-токен устройства (выдаётся при регистрации/логине, хранится хэшом в D1).

## Идентификаторы

- `userId` — ULID. `deviceId` — ULID (per-устройство). `chatId` — ULID.
- `msgId` — ULID, присваивает ConversationDO. `seq` — монотонный номер в чате (1..N).
- `clientMsgId` — UUID клиента, ключ идемпотентности отправки.

## HTTP API (все ответы `{ok:true,...}` либо `{ok:false,error}`)

```
POST /api/register        {username, displayName, device:{name}, identityKey, signedPrekey{key,sig,id}, oneTimePrekeys[]}
                          → {userId, deviceId, token}
POST /api/login           {username, proof}  // подпись челленджа identity-ключом существующего устройства — v2; v1: восстановление = новая регистрация
GET  /api/users?q=        поиск по username/имени → [{userId, username, displayName, avatarUrl, identityKey}]
GET  /api/users/:id/prekeys?device=all → бандлы X3DH по устройствам (one-time prekey выдаётся и удаляется)
POST /api/prekeys         пополнение one-time prekeys
POST /api/profile         {displayName?, bio?, avatarId?}
POST /api/avatar          multipart → R2, {avatarId,url} (аватары не E2E)
POST /api/chats           {kind:"direct"|"group", memberIds[], title?} → {chatId}  (direct дедуплицируется)
GET  /api/chats           снапшот: чаты + члены + последние N сообщений + курсоры
POST /api/chats/:id/members       {add[], remove[]} (админ)
POST /api/chats/:id/leave
POST /api/chats/:id/settings      {title?, avatarId?, description?}
POST /api/chats/:id/admins        {userId, admin:bool}
POST /api/chats/:id/invite        → {link}; POST /api/join/:code
POST /api/chats/:id/pin-message   {msgId|null}
POST /api/media/upload    → {mediaId, putUrl}  затем PUT блоба; GET /api/media/:id → stream
POST /api/push-token      {apnsToken, env}
POST /api/block           {userId, blocked:bool}
GET  /api/blocked
```

## WS: клиент → сервер

```
{t:"sync",  cursors:{chatId:lastSeq,...}}          // после connect: доигрывание пропущенного
{t:"send",  chatId, clientMsgId, sentAt, body}      // body — E2E-конверт (см. ниже)
{t:"recv",  chatId, seqs:[...]}                     // подтверждение доставки → delivery receipts автору
{t:"read",  chatId, upToSeq}
{t:"typing",chatId, kind:"text"|"voice"|"photo"|null}
{t:"delete",chatId, msgIds:[...], forAll:bool}      // forAll: сервер тумбстоунит ciphertext
{t:"ping"}
```

## WS: сервер → клиент

```
{t:"hello", serverTime}
{t:"sent",    chatId, clientMsgId, msgId, seq, ts}          // ack отправки
{t:"msg",     chatId, seq, msgId, from, fromDevice, sentAt, ts, body}
{t:"receipt", chatId, kind:"delivered"|"read", upToSeq|seqs, by}
{t:"typing",  chatId, from, kind}
{t:"presence",userId, online, lastSeen}
{t:"chat",    chatId, event:"created"|"members"|"settings"|"pinned", state}  // снапшот чата
{t:"deleted", chatId, msgIds, forAll, by}
{t:"pong"}
```

## E2E-конверт (`body`)

Сервер не заглядывает внутрь. Клиентские варианты:

```
{v:1, mode:"pw",  msgs:{ "<userId>/<deviceId>": {type:"pk"|"dr", c:b64, ...ratchet header}, ...}}
{v:1, mode:"skm", chatId, c:b64, senderKeyId, iv, sig}      // группа: sender-key message
{v:1, mode:"skd", msgs:{...}}                               // раздача sender key (pairwise)
```

Plaintext внутри ciphertext (после расшифровки) — единый формат контента:

```
{kind:"text", text, replyTo?, fwd?{...}, entities?}
{kind:"media", media:{type:"photo"|"video"|"file"|"voice", mediaId, key, hash, size,
                      w?,h?,dur?,waveform?,name?,mime}, caption?, replyTo?}
{kind:"edit", targetMsgId, newContent{...}}
{kind:"reaction", targetMsgId, emoji|null}
{kind:"disappearing", ttlSeconds}    // включение таймера в чате
{kind:"contact"|"location"|...}
```

Доставка: at-least-once; клиент дедуплицирует по (chatId,msgId). Порядок — по seq.
Read receipts в группах агрегируются (у сообщения: прочитано кем/сколько).

## Пуши

APNs-пуш уходит немедленно для каждого контентного `msg` — независимо от
presence и живых WS-сокетов. Исключения: `service:true`, собственное эхо
автора, muted-чат. Дедуп на клиенте: `willPresent` гасит баннер, если
сообщение уже показано по WS (матч по chatId/msgId).

Payload (текста сообщения нет — E2EE; превью строит NSE после расшифровки):

```
POST {APNS_HOST}/3/device/{apnsToken}
заголовки: apns-topic, apns-push-type: alert, apns-priority: 10,
           apns-collapse-id: msgId   // повторная доставка не плодит баннеры
{
  "aps": {
    "alert": {"title": "Msngr", "body": "Новое сообщение"},
    "badge": <суммарный unread юзера по всем чатам>,
    "sound": "default",
    "mutable-content": 1,
    "thread-id": "<chatId>"
  },
  "chatId": "...", "msgId": "..."
}
```

Badge: UserSessionDO держит в storage кэш unread по чатам (`unreadCache`);
инвалидация — по входящему `msg` и собственному `read`, ленивый пересчёт в
момент пуша запросом `GET /unread-count?userId=` к ConversationDO
(unread = lastSeq − read-марка юзера). Приближение: service-сообщения и
muted-чаты входят в число до прочтения.

Dev без Apple-аккаунта: `APNS_HOST` (в `.dev.vars` — `http://localhost:9871`)
направляет пуши в мок `server/tools/apns-mock.mjs`, который доставляет их в
симулятор через `xcrun simctl push` (apnsToken = UDID симулятора). На
не-яблочном хосте запрос уходит без JWT-подписи (p8-ключ не нужен),
формат запроса остаётся APNs-совместимым.
