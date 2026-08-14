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
POST /api/chats                   {kind:"direct"|"group", memberIds[], title?} → {chatId}
GET  /api/chats                   снапшот: [{flags, state}] + профили всех участников
GET  /api/chats/:id/history       ?fromSeq=&toSeq=&limit=&dir=back
                                  → {msgs:[StoredMsg], scanned, lastScannedSeq}
POST /api/chats/:id/accept        принять message request
POST /api/chats/:id/members       {add[], remove[]}
POST /api/chats/:id/leave
POST /api/chats/:id/settings      {title?, avatarId?, description?}
POST /api/chats/:id/admins        {userId, admin:bool}
POST /api/chats/:id/pin-message   {msgId|null}
POST /api/chats/:id/flags         {pinned?, muted?, archived?} — локальные для пользователя
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
Блокировки — в разделе ниже.

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
   батчи не кончатся (ограничения на одну пачку нет); курсор двигается по
   `lastScannedSeq`, а не по числу отданных сообщений;
3. затем шлёт `deleted`-фреймы по тумбстоунам и `receipt`-фреймы по текущим
   `readMarks`/`deliveredMarks` — то, что случилось, пока клиент был офлайн.

Тумбстоуны в истории пропускаются как `msg` и приходят отдельными `deleted`.
Курсор клиента двигается только по непрерывному префиксу, поэтому дыра в
доставке не приводит к потере истории.

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
получателя. В группах все участники считаются принявшими.

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
{kind, text?, media?, album?, replyTo?, fwd?, targetMsgId?, emoji?, ttlSeconds?}
```

- `kind`: `text` | `photo` | `video` | `file` | `voice` | `album` | `contact` |
  `edit` | `reaction` | `disappearing`;
- `media` / `album` — `MediaInfo`: `type, mediaId, key, hash, size, mime, name?,
  w?, h?, dur?, waveform?, blurhash?, thumbMediaId?, thumbKey?, thumbHash?`;
- `replyTo` — `{msgId, authorId, text, kind}`, `fwd` — `{fromUserId, fromName}`;
- `edit` и `reaction` адресуются `targetMsgId`, `emoji: null` снимает реакцию;
- `disappearing` несёт `ttlSeconds` — новый TTL чата.

Поля `localPath`/`thumbLocalPath` в `MediaInfo` существуют только локально
(исходник вложения, ещё не выгруженный на сервер) и в конверт не попадают.

## Доставка и порядок

At-least-once. Порядок — по `seq` внутри чата. Клиент дедуплицирует входящие по
`msgId`, свои отправки — по `clientMsgId`. Сообщение, пришедшее раньше своего
ключа (групповое до sender key, `dr` раньше своего `pk`), складывается в
`pendingDecrypt` и переигрывается, когда ключ приходит. `edit`/`reaction`/
`deleted`, чья цель ещё не в БД, складываются в `pendingApply` и применяются
при появлении оригинала.

## Пуши

APNs уходит немедленно для каждого контентного `msg` — независимо от presence и
живых сокетов. Исключения: `service:true`, собственное эхо автора, muted-чат.
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

## Версии

Обратной совместимости нет (см. `docs/PROCESS.md`), но точки для неё заложены:
`v` в E2E-конверте, версия схемы БД в миграторе GRDB, миграции D1 в
`server/migrations/`, `migrations` (теги DO) в `wrangler.jsonc`. Версия
протокола в рукопожатии (`hello`) пока не передаётся.
