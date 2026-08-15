# Протокол

Источник истины — код: `server/src/index.ts` (роутер), `server/src/types.ts`
(фреймы), `server/src/do/*.ts` (логика DO), `ios/MsngrKit/Sources/MsngrCore/Protocol.swift`
(клиентское зеркало).

## Транспорт

- HTTP `/api/*` — регистрация, ключи, профили, чаты, медиа, контакты, блокировки.
- WS `/ws?token=…&v=…` — один сокет на устройство, JSON-фреймы `{t, ...}`.
  Апгрейд авторизуется в Worker, сам сокет держит `UserSessionDO`.
  `v` is the client's protocol version, read before auth: below the server's
  floor the upgrade answers `426 client_too_old` with both numbers, and the
  client stops reconnecting instead of retrying into silence.
- Auth: токен устройства (`Authorization: Bearer <token>` или `?token=`),
  в D1 хранится SHA-256 токена. Логина как отдельной операции нет: восстановление
  доступа — новая регистрация.
- Отзыв токена: `devices.revoked_at`. Проверяется в middleware авторизации, так
  что отозванный токен даёт 401 и на `/api/*`, и на апгрейде `/ws`. Отзыв рвёт
  живые сокеты этого устройства (код закрытия 4401) и стирает его APNs-токен,
  так что до устройства перестают доходить и пуши. Срока жизни у токена нет:
  он действует, пока не отозван.
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
GET  /api/sessions                → {sessions:[{deviceId,name,createdAt,lastSeen,hasPushToken,current}]}
POST /api/logout                  отозвать токен текущего устройства
POST /api/sessions/:deviceId/revoke   отозвать токен другого своего устройства
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
GET  /api/chats/:id/history       ?fromSeq=&toSeq=&limit=&dir=back
                                  → {msgs:[StoredMsg], scanned, lastScannedSeq}
POST /api/chats/:id/accept        принять message request
POST /api/chats/:id/members       {add[], remove[]}
POST /api/chats/:id/delete        удалить чат у себя: группу покидает, переписку
                                  убирает из своего списка (журнал и участие
                                  остаются, собеседник ничего не узнаёт); своя
                                  read-марка при этом уходит в конец журнала
POST /api/chats/:id/settings      {title?, avatarId?, description?}
POST /api/chats/:id/admins        {userId, admin:bool}
POST /api/chats/:id/pin-message   {msgId|null}
POST /api/chats/:id/flags         {pinned?, muted?, mutedUntil?, archived?} — локальные
                                  для пользователя; mutedUntil — секунды, null = бессрочно
GET  /api/chats/:id/fanout        fanout queue of the chat →
                                  {pending, cursor, targets, attempt, oldestMs, armed};
                                  oldestMs is the head job's wait, armed says a drain
                                  is coming — a queue standing still is oldestMs growing
POST /api/chats/:id/invite        → {code, link:"msngr://join/<code>"}
POST /api/join/:code              → {chatId}
POST /api/media                   raw body (ciphertext) → {mediaId, size}
GET  /api/media/:id               стрим блоба, поддерживает Range (206)
POST /api/push-token              {apnsToken, env}
POST /api/phone                   {phoneHash|null}
POST /api/contacts/discover       {hashes[]} → {matches[]}  (до 5000 хэшей, чанками по 100)
POST /api/block                   {userId, blocked}
GET  /api/blocked                 → {blocked:[userId]}
POST /api/dev/fault               {failEvents} — dev hook: the caller's own session
                                  object rejects that many frame deliveries
```

Права: удалять участников и менять настройки группы может только админ; добавить
может админ, а не-админ — только самого себя; вступление по инвайт-ссылке
разрешено не-участнику (`viaInvite`); создать инвайт может любой участник чата.
Блокировки — в разделе ниже.

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
{t:"sync",  cursors:{chatId: lastSeq, ...}}    // весь известный клиенту мир
{t:"catchup", cursors:{chatId: cursor, ...}}   // следующая порция догона
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
{t:"hello",   serverTime, protocol, minProtocol}
{t:"sent",    chatId, clientMsgId, msgId, seq, ts}
{t:"msg",     chatId, seq, msgId, from, fromDevice, sentAt, ts, body, service?}
{t:"receipt", chatId, kind:"delivered"|"read", upToSeq, by}
{t:"typing",  chatId, from, kind}
{t:"presence",userId, online, lastSeen}
{t:"chat",    chatId, event:"created"|"members"|"settings"|"pinned"|"sync", state}
{t:"deleted", chatId, msgIds, forAll, by}
{t:"syncState", chatId, cursor, more}
{t:"syncDone", more}
{t:"error",   error, chatId?, clientMsgId?}
{t:"pong"}
```

`error` — отказ по клиентскому фрейму; `error` несёт машиночитаемый код
(`blocked`, `not_member`, `send_failed`). На `send` он приходит вместо `sent`
с тем же `clientMsgId`.

`state` в `chat`-фрейме — полный снапшот чата: `members` (userId, role, joinedAt,
accepted), `title`, `avatarId`, `description`, `pinnedMsgId`, `lastSeq`,
`readMarks`, `deliveredMarks`. Профили участников фрейм не несёт: клиент
дотягивает недостающих через `GET /api/users/:id`.

## Delivery order

`sent` leaves as soon as the message owns a `seq` and is written, before any
recipient sees the frame and before APNs is called. Frames of one chat reach a
recipient in the order the chat produced them; a `msg` frame can be delivered
twice (a retried fanout pass), so the client dedupes by `msgId`.

## Presence

`UserSessionDO` считает пользователя онлайн, пока хотя бы один сокет присылал
`ping` не позже 35 секунд назад (`PRESENCE_TTL_MS`); клиент пингует каждые 12 с.
Открытый, но замолчавший сокет онлайном не считается — iOS держит соединение
минутами после сворачивания. Смену статуса рассылает alarm DO, `bg`/`fg`
переключают его сразу.

## Catch-up after a reconnect

Catch-up is pulled by the client one portion at a time. The cursors live on the
client, the object serves a portion and goes back to its event loop, so live
traffic waits for one portion instead of the whole backlog and a connection cut
short resumes from the last confirmed cursor.

1. The client sends `sync` with a cursor per chat it knows. Chats missing from
   the map are new to it: the object replays their state in a `chat` frame with
   `event: "sync"` and puts them into the portion at cursor 0.
2. The object reads one `/history` page per chat (at most 128 records, the
   Durable Objects batch read limit), sends the `msg` frames and answers
   `{t:"syncState", chatId, cursor, more}`. The cursor moves along scanned
   records rather than delivered ones, so a page filtered out by a block does
   not stall the catch-up.
3. A chat whose page came back short is caught up: its tombstones (`deleted`)
   and current `readMarks`/`deliveredMarks` (`receipt`) follow — what happened
   to already delivered messages while the client was offline.
4. `{t:"syncDone", more}` closes the portion. `more` is true when some chat is
   still behind, or when the portion ran out of budget before reaching every
   chat it was asked about: one portion reads at most 128 records over at most
   32 chats. The client then sends `catchup` with the chats that are still
   behind — those whose `syncState` said `more`, plus those it got no
   `syncState` for — and repeats until `more` is false.

The client stores the confirmed cursor per chat, so a catch-up interrupted
halfway resumes where it stopped instead of starting over. The cursor of the
next `sync` is the larger of that cursor and `syncedSeq` (the contiguously
applied prefix): a seq that never reaches this device — a message held back by
a block, for instance — stalls `syncedSeq` forever, and the catch-up cursor is
what moves past it.

Tombstones are skipped as `msg` frames in a page and arrive as `deleted`.

## Блокировки

Список блокировок — таблица `blocks` в D1, направленная: строка `(user_id,
blocked_id)` значит «user_id заблокировал blocked_id». `ConversationDO`
direct-чата читает пару лениво и держит в памяти; `POST /api/block` сбрасывает
этот кэш фреймом `/block-changed` (чат при этом может ещё не существовать).
В группах блокировки не проверяются.

Поведение в существующем direct-чате — как принято в мессенджерах: заблокированный
по ответам сервера не отличает блокировку от молчания собеседника.

- Заблокированный шлёт `send`: сервер отвечает обычным `sent` (сообщение
  получает `seq` и остаётся в его собственной истории), но не рассылает его
  получателю, не шлёт пуш и помечает запись `blockedFor: <userId блокирующего>`.
  Такое сообщение не попадает ни в `/history` блокирующего, ни в его `sync` —
  в том числе после снятия блокировки.
- Блокирующий шлёт `send` тому, кого заблокировал: явный отказ, фрейм
  `{t:"error", error:"blocked"}` (HTTP-эквивалент — 403 `blocked`). Он знает
  про свою блокировку, скрывать нечего.
- При блокировке в любую сторону `receipt`, `typing` и `presence` между парой
  не рассылаются, а `delivered`/`read`-марки заблокированного даже не
  записываются: они видны в `state` `chat`-фрейма.
- Создать direct с тем, кто заблокировал (или кого заблокировали), нельзя:
  403 `blocked`.

`/history` отдаёт рядом с `msgs` два счётчика: `scanned` — сколько записей
прочитано до фильтрации, `lastScannedSeq` — `seq` последней прочитанной. По ним
двигается курсор в `sync`, иначе страница, целиком выпавшая из выдачи по
блокировке, останавливала бы доигрывание.

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
  "chatId": "...", "msgId": "...", "seq": <позиция в чате>,
  "sentAt": <мс>, "badgeStamp": <номер счётчика>,
  "from": "<userId автора>", "fromDevice": "<deviceId автора>",
  "ts": <серверные секунды>,
  "env": "<E2E-конверт этого устройства, компактным JSON>"
}
```

`env` — то самое сообщение, а не ссылка на него: расширение расшифровывает его
и пишет в базу, поэтому прочитанное в баннере остаётся в чате даже без сети
(`PushMessageWriter`). Конверт режется под адресата: у `pw` остаётся один бокс
`userId/deviceId`, `skm` едет целиком. `from`/`fromDevice` называют отправителя
— по ним выбирается сессия, которой открывать.

APNs не принимает payload больше 4 КБ и отказывает целиком, поэтому `env`
выбрасывается первым: остальное доезжает, а сообщение приходит следующим
соединением. Так уходят вложения — картинка с текстом за границей влезает,
большое медиа нет.

Бейдж считает сервер: `aps.badge` — суммарный unread пользователя по чатам,
заявка до принятия в него не входит. Клиент число не пересчитывает, а только
сообщает своё, когда сам сдвинул прочитанное.

`badgeStamp` — порядковый номер счётчика, который `UserSessionDO` выдаёт на
каждую рассылку пуша. APNs доставляет лавину в произвольном порядке, и по
`badgeStamp` устройство отличает свежий счётчик от обогнавшего его старого:
меньший номер на иконку не попадает (`BadgeStore`).

Ответ APNs разбирается:

- `410` — токен устройства мёртв: запись удаляется и из storage `UserSessionDO`,
  и из `devices.apns_token` в D1;
- `429` и `5xx` — до двух повторов с задержкой 500 мс и 1500 мс;
- `403 ExpiredProviderToken` — принудительный перевыпуск JWT и одна повторная
  попытка;
- `400` и остальное — код и `reason` уходят в лог, повтора нет.

Устройства обрабатываются независимо: отказ по одному токену не отменяет
отправку на остальные.

Провайдерский JWT (ES256, p8) принадлежит синглтон-объекту `ApnsTokenDO`
(имя `apns-jwt`): кэш лежит в его storage и живёт 3000 секунд. Владелец один,
потому что Apple ограничивает частоту генерации токена, а изолятов, в которых
живут `UserSessionDO`, может быть много. Принудительный перевыпуск не чаще
одного раза в минуту.

Бейдж: `UserSessionDO` держит в storage кэш unread
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

## Схема D1 и миграции

Схема живёт в `server/migrations/` нумерованными файлами (`0001_init.sql`,
`0002_…`), применяет их штатный раннер wrangler; каталог и таблица журнала
заданы в `wrangler.jsonc` (`migrations_dir`, `migrations_table: d1_migrations`).

```
npm run migrate:local     # локальная база wrangler dev
npm run migrate           # удалённая база
npm run deploy            # миграции на удалённой базе, затем wrangler deploy
```

Новая миграция — новый файл со следующим номером; ранее применённые файлы не
редактируются, раннер сверяется с `d1_migrations`.

## Versions

There is no backward compatibility (see `docs/PROCESS.md`), but every mismatch
has a place to be named instead of a silence or a crash.

- Protocol. `server/src/version.ts` holds `PROTOCOL_VERSION` and
  `MIN_CLIENT_PROTOCOL`; `MsngrProtocol.version` is the client's side of the
  same number. It travels in the upgrade (`/ws?v=`), and the server states both
  numbers back in `hello` and in `GET /api/version` (no auth). A client below
  the floor is refused with `426 client_too_old`, the reconnect loop stops and
  the app shows that it is out of date.
- Envelope. `v` in the E2E envelope. An envelope above
  `MsngrProtocol.envelopeVersion` is kept as it arrived and marked unreadable;
  no repair is asked for, because a fresh copy would come back in the same
  format, and the message opens once a build that knows the format runs.
- Database schema. The GRDB migrator: a file carrying migrations this binary
  does not register is not opened and not wiped
  (`AppDatabaseError.schemaFromNewerVersion`, `StorageOwnership.startOver`).
  Starting over on clean storage is the user's call.
- Server storage: D1 migrations in `server/migrations/`, DO tags `migrations`
  in `wrangler.jsonc`.
