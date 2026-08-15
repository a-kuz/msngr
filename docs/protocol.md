# Протокол

Источник истины — код: `server/src/index.ts` (роутер), `server/src/types.ts`
(фреймы), `server/src/do/*.ts` (логика DO), `ios/MsngrKit/Sources/MsngrCore/Protocol.swift`
(клиентское зеркало).

## Транспорт

- HTTP `/api/*` — регистрация, ключи, профили, чаты, медиа, контакты, блокировки.
- WS `/ws?token=…` — один сокет на устройство, JSON-фреймы `{t, ...}`.
  Апгрейд авторизуется в Worker, сам сокет держит `UserSessionDO`.
- Auth: токен устройства (`Authorization: Bearer <token>` или `?token=`),
  в D1 хранится SHA-256 токена. Логина как отдельной операции нет: восстановление
  доступа — новая регистрация.
- Все клиент-видимые метки времени — в секундах (`nowSec()` на сервере,
  `timeIntervalSince1970` на клиенте).

## Идентификаторы

- `userId`, `deviceId`, `msgId` — ULID (собственная реализация в `server/src/util.ts`).
- `chatId`: группа — ULID; direct — детерминированное имя `direct:<userIdA>:<userIdB>`
  с отсортированными id, за счёт этого direct-чат дедуплицируется без индекса.
- `seq` — монотонный номер сообщения в чате (1..N), присваивает `ConversationDO`.
- `clientMsgId` — UUID клиента, ключ идемпотентности отправки. Дедуп-ключ на
  сервере — `cmid:<from>/<clientMsgId>`, повтор возвращает исходные `msgId`/`seq`.

## HTTP API

Ответы: `{ok:true, ...}` либо `{ok:false, error}` с ненулевым HTTP-статусом.

```
POST /api/register    {username, displayName, device:{name}, identityKey, identitySignKey,
                       signedPrekey:{id,key,sig}, oneTimePrekeys:[{id,key}], phoneHash?}
                      → {userId, deviceId, token}    (без auth; username [a-zA-Z0-9_]{3,32})
GET  /api/me                      → {user, deviceId}
GET  /api/users?q=                поиск по username/displayName (LOWER LIKE, лимит 20)
GET  /api/users/:id               → {user, presence:{online,lastSeen}}
GET  /api/devices?ids=a,b,c       устройства и identity-ключи; ничего не расходует
GET  /api/users/:id/prekeys       X3DH-бандлы всех устройств; one-time prekey выдаётся и удаляется
GET  /api/prekeys/count           остаток собственных one-time prekeys
POST /api/prekeys                 {oneTimePrekeys:[{id,key}]} — пополнение (до 200 за раз)
POST /api/profile                 {displayName?, bio?, avatarId?}
POST /api/avatar                  raw body (image/jpeg) → {avatarId};  GET /api/avatar/:id
                                  ?chatId=<id> — аватар чата вместо своего профиля
POST /api/chats                   {kind:"direct"|"group", memberIds[], title?} → {chatId}
GET  /api/chats                   снапшот: [{flags, state}] + профили всех участников
GET  /api/chats/:id/history       ?fromSeq=&toSeq=&limit=&dir=back → {msgs:[StoredMsg]}
POST /api/chats/:id/accept        принять message request
POST /api/chats/:id/members       {add[], remove[]}
POST /api/chats/:id/leave
POST /api/chats/:id/settings      {title?, avatarId?, description?}
POST /api/chats/:id/admins        {userId, admin:bool}
POST /api/chats/:id/pin-message   {msgId|null}
POST /api/chats/:id/flags         {pinned?, muted?, mutedUntil?, archived?} — локальные
                                  для пользователя; mutedUntil — секунды, null = бессрочно
POST /api/chats/:id/invite        → {code, link:"msngr://join/<code>"}
POST /api/join/:code              → {chatId}
POST /api/media                   raw body (ciphertext) → {mediaId, size}
GET  /api/media/:id               стрим блоба, поддерживает Range (206)
POST /api/push-token              {apnsToken, env}
POST /api/phone                   {phoneHash|null}
POST /api/contacts/discover       {hashes[]} → {matches[]}  (до 5000 хэшей, чанками по 100)
POST /api/block                   {userId, blocked}
GET  /api/blocked                 → {blocked:[userId]}
```

Права: удалять участников и менять настройки группы может только админ; добавить
может админ, а не-админ — только самого себя; вступление по инвайт-ссылке
разрешено не-участнику (`viaInvite`); создать инвайт может любой участник чата.
Создать direct с тем, кто заблокировал (или кого заблокировали), нельзя.

## Блокировки

Блокировка симметрично гасит доставку в уже существующем direct-чате: сообщение
автора принимается, занимает `seq` и лежит в журнале, но `ConversationDO` не
рассылает его заблокированной стороне — ни `msg`-фреймом, ни пушем. Так же
режутся `typing` и `presence`. Автор получает обычный `sent` и видит одну
галочку: `delivered` не приходит никогда.

Чтобы непрочитанное блокирующего не росло на невидимые сообщения, его read-марка
двигается до `seq` придержанного сообщения прямо в `/send` (без `receipt`-фрейма
автору). После разблокировки придержанные сообщения доезжают обычным `sync`:
журнал их хранит, отдельного отсева в истории нет.

## WS: клиент → сервер

```
{t:"sync",  cursors:{chatId: lastSeq, ...}}
{t:"send",  chatId, clientMsgId, sentAt, body, service?}   // body — E2E-конверт
{t:"recv",  chatId, seqs:[...]}                            // → delivered-квитанции автору
{t:"read",  chatId, upToSeq}
{t:"typing",chatId, kind}                                  // kind: строка или null (стоп)
{t:"delete",chatId, msgIds:[...], forAll}
{t:"ping"}
{t:"bg"}    // приложение свернулось: presence offline немедленно
{t:"fg"}    // вернулось: presence online
```

`service: true` — служебный фрейм (раздача sender key, реакция, правка,
переключение TTL). Он занимает `seq` и хранится в журнале, но не растит unread
и не порождает пуш. Клиент помечает так `edit`, `reaction`, `disappearing`
(`SyncEngine.serviceKinds`) и все skd-конверты.

## WS: сервер → клиент

```
{t:"hello",   serverTime}
{t:"sent",    chatId, clientMsgId, msgId, seq, ts}
{t:"msg",     chatId, seq, msgId, from, fromDevice, sentAt, ts, body, service?}
{t:"receipt", chatId, kind:"delivered"|"read", upToSeq, by}
{t:"typing",  chatId, from, kind}
{t:"presence",userId, online, lastSeen}
{t:"chat",    chatId, event:"created"|"members"|"settings"|"pinned"|"sync", state}
{t:"deleted", chatId, msgIds, forAll, by}
{t:"pong"}
```

`state` в `chat`-фрейме — полный снапшот чата: `members` (userId, role, joinedAt,
accepted), `title`, `avatarId`, `description`, `pinnedMsgId`, `lastSeq`,
`readMarks`, `deliveredMarks`. Профили участников фрейм не несёт: клиент
дотягивает недостающих через `GET /api/users/:id`.

## Presence

`UserSessionDO` считает пользователя онлайн, пока хотя бы один сокет присылал
`ping` не позже 35 секунд назад (`PRESENCE_TTL_MS`); клиент пингует каждые 12 с.
Открытый, но замолчавший сокет онлайном не считается — iOS держит соединение
минутами после сворачивания. Смену статуса рассылает alarm DO, `bg`/`fg`
переключают его сразу.

## Sync после переподключения

Клиент шлёт `sync` с курсорами `chatId → syncedSeq` (последний непрерывно
применённый seq). Сервер:

1. по чатам, которых нет в курсорах, шлёт `chat`-фрейм с `event:"sync"` и
   доигрывает историю с нуля;
2. по каждому чату тянет `/history` батчами по 200 и шлёт `msg`-фреймы, пока
   батчи не кончатся (ограничения на одну пачку нет);
3. затем шлёт `deleted`-фреймы по тумбстоунам и `receipt`-фреймы по текущим
   `readMarks`/`deliveredMarks` — то, что случилось, пока клиент был офлайн.

Тумбстоуны в истории пропускаются как `msg` и приходят отдельными `deleted`.
Курсор клиента двигается только по непрерывному префиксу, поэтому дыра в
доставке не приводит к потере истории.

## Message requests

В direct-чате получатель помечен `accepted: false`, пока не вызвал `/accept`.
До этого автору заявки не уходят ни `receipt`, ни `typing`, ни `presence`
получателя; `GET /api/users/:id` тоже отдаёт автору `presence: null`, пока
получатель не принял. Непрочитанное такого чата не входит в бейдж пуша
(`/unread-count` возвращает 0). В группах все участники считаются принявшими.

## E2E-конверт (`body`)

Сервер не заглядывает внутрь. Два режима:

```
{v:1, mode:"pw",  msgs:{ "<userId>/<deviceId>": PairwiseBox, ... }}
{v:1, mode:"skm", c, keyId, iteration, sig}
```

`PairwiseBox`:

```
{type:"pk"|"dr", c,        // base64 JSON RatchetMessage {header:{dhPub,pn,n}, ciphertext}
 ik?, isk?, ek?, spkId?, otpId?}   // только для pk: наши identity DH/Ed25519 pub,
                                   // ephemeral и id использованных prekey
```

Раздача sender key (`skd`) отдельным режимом конверта не является: это обычное
pairwise-сообщение, внутри которого лежит `InnerMessage` с `type:"skd"`.

Внутри pairwise-ciphertext:

```
{type:"content", content: ContentPayload}
{type:"skd", skd:{keyId, iteration, chainKey, signingPub}, chatId}
```

`ContentPayload` (он же plaintext в `skm`):

```
{kind, text?, media?, album?, replyTo?, fwd?, targetMsgId?, emoji?, ttlSeconds?,
 to?, repairSeq?, reason?, attempt?, repairOf?, origSentAt?, orig?, keyId?}
```

- `kind`: `text` | `photo` | `video` | `file` | `voice` | `album` | `contact` |
  `edit` | `reaction` | `disappearing` | `repairRequest` | `repair` | `skdAck`;
- `media` / `album` — `MediaInfo`: `type, mediaId, key, hash, size, mime, name?,
  w?, h?, dur?, waveform?, blurhash?, thumbMediaId?, thumbKey?, thumbHash?`;
- `replyTo` — `{msgId, authorId, text, kind}`, `fwd` — `{fromUserId, fromName}`;
- `edit` и `reaction` адресуются `targetMsgId`, `emoji: null` снимает реакцию;
- `disappearing` несёт `ttlSeconds` — новый TTL чата;
- `to` — адресный фрейм: конверт шифруется pairwise одному участнику, даже в
  группе. Так едет весь протокол ремонта.

### Ремонт нечитаемого

Идёт сам, без участия пользователя, служебными фреймами (`service: true`).

- `repairRequest` — «не смог прочитать сообщение»: `targetMsgId`, `repairSeq`,
  `reason` (причина отказа расшифровки), `attempt` (номер попытки), `to` —
  автор сообщения. `clientMsgId` детерминирован (`rq:<msgId>:<attempt>`):
  повтор той же попытки гасится дедупом сервера, следующая попытка проходит.
- `repair` — ответ автора: `repairOf` (исходный msgId), `repairSeq`,
  `origSentAt` и `orig` — исходный `ContentPayload` строкой JSON. Получатель
  кладёт его под исходным `msgId`, поэтому в ленте копия занимает место
  пропавшего сообщения, а не появляется рядом. `clientMsgId` —
  `rp:<msgId>:<attempt>`.
- `skdAck` — подтверждение раздачи sender key: `keyId` цепочки. Пока
  подтверждения нет, отправитель раздаёт цепочку заново; `repairRequest` с
  `reason: "no_sender_key"` заставляет раздать её этому участнику снова.

Поля `localPath`/`thumbLocalPath` в `MediaInfo` существуют только локально
(исходник вложения, ещё не выгруженный на сервер) и в конверт не попадают.

## Доставка и порядок

At-least-once. Порядок — по `seq` внутри чата. Клиент дедуплицирует входящие по
`msgId`, свои отправки — по `clientMsgId`. Конверт, который не удалось
расшифровать, складывается в `pendingDecrypt` целиком — при любой причине: это
единственная локальная копия. Он переигрывается, когда в чате появляется ключ, и
проходами при старте движка, на реконнекте и по кругу в фоне; счётчик попыток и
срок жизни лежат на той же строке. `edit`/`reaction`/`deleted`, чья цель ещё не
в БД, складываются в `pendingApply` и применяются при появлении оригинала.

Что переигрыванием не берётся, чинится через отправителя (`repairRequest` →
`repair`). Сам seq записан в `historyGap` с причиной и счётчиком: пагинация
вверх не ходит за ним на сервер снова, а нейтральная заглушка в ленте
появляется, только когда попытки ремонта потрачены.

## Пуши

APNs уходит немедленно для каждого контентного `msg` — независимо от presence и
живых сокетов. Исключения: `service:true`, собственное эхо автора, muted-чат,
блокировка. Mute со сроком (`mutedUntil`) истекает сам: `UserSessionDO` снимает
флаг при первой же проверке после срока — на пуше и в снапшоте `/api/chats`.
Дедуп на клиенте: `willPresent` гасит баннер, если сообщение уже показано по WS
(матч по chatId/msgId, см. `NotificationDecision`).

```
POST {APNS_HOST}/3/device/{apnsToken}
заголовки: apns-topic, apns-push-type: alert, apns-priority: 10,
           apns-collapse-id: <msgId>     // повторная доставка не плодит баннеры
{
  "aps": {
    "alert": {"title": "Msngr", "body": "Новое сообщение"},
    "badge": <суммарный unread пользователя>,
    "sound": "default",
    "mutable-content": 1,
    "thread-id": "<chatId>"
  },
  "chatId": "...", "msgId": "..."
}
```

Текста сообщения в пуше нет. Бейдж: `UserSessionDO` держит в storage кэш unread
по чатам (`unreadCache`), инвалидирует его по входящему `msg` и собственному
`read`, а в момент отправки пуша лениво пересчитывает инвалидированные чаты
запросом `GET /unread-count?userId=` к `ConversationDO` (`lastSeq` минус
read-марка). Приближение: muted-чаты входят в бейдж до прочтения.

Dev без Apple-аккаунта: `APNS_HOST` (в `server/.dev.vars` — `http://localhost:9871`)
уводит пуши в мок `server/tools/apns-mock.mjs`, который доставляет их в симулятор
через `xcrun simctl push` (apnsToken = UDID симулятора). На не-яблочном хосте
запрос уходит без JWT-подписи, p8-ключ не нужен, `apns-topic` по умолчанию
`ai.enface.Msngr`. Ограничение канала: `simctl push` не запускает Notification
Service Extension — см. `docs/research/nse-simulator-experiment.md`.

## Версии

Обратной совместимости нет (см. `docs/PROCESS.md`), но точки для неё заложены:
`v` в E2E-конверте, версия схемы БД в миграторе GRDB, `migrations` в
`wrangler.jsonc`. Версия протокола в рукопожатии (`hello`) пока не передаётся.
