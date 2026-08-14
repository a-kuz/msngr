# Msngr — архитектура

Мессенджер со сквозным шифрованием: клиенты для iOS и macOS, бэкенд на
Cloudflare Workers.

```
server/           Worker: HTTP API (hono), WS, Durable Objects, D1, R2, APNs
ios/MsngrKit/     переносимое ядро (Swift Package): MsngrCrypto + MsngrCore
ios/Msngr/        iOS-приложение (SwiftUI + UIKit для ленты сообщений)
ios/MsngrMac/     macOS-клиент на том же ядре
ios/NotificationService/  NSE: превью пуша из общей БД
docs/             протокол, крипто-флоу, UI, процесс, аудиты, QA
```

## Бэкенд

- **Worker (роутер)** — весь HTTP API и апгрейд `/ws`. Авторизует сокет и
  передаёт его в `UserSessionDO` пользователя.
- **UserSessionDO** — по одному на пользователя. Держит WS всех его устройств
  (WebSocket Hibernation API), чат-лист с локальными флагами (pinned/muted/
  archived), presence, APNs-токены, кэш непрочитанного для бейджа. Всё, что
  адресовано пользователю, проходит через его DO — единая точка fan-in.
- **ConversationDO** — по одному на чат. Хранит членство с ролями и флагом
  `accepted` (message requests), журнал сообщений (ciphertext + метаданные),
  read/delivered-марки, закреплённое сообщение, настройки. Присваивает
  монотонные `seq`, дедуплицирует отправку по `clientMsgId`, после записи
  рассылает событие в `UserSessionDO` каждого участника.
- **D1** — пользователи, устройства с хэшами токенов, identity-ключи и
  prekey-бандлы, блокировки, инвайты, реестр медиа.
- **R2** — блобы медиа, зашифрованные на клиенте.
- **APNs** — token-based auth (p8, ES256, JWT кэшируется). Пуш уходит на каждое
  контентное сообщение немедленно, независимо от живых сокетов; дубль гасит
  клиент.

Direct-чат адресуется детерминированным именем `direct:<id>:<id>`, поэтому
дедуплицируется без индекса. Хранилище DO — SQLite-backed
(`new_sqlite_classes` в `wrangler.jsonc`).

## Протокол

Один WS на устройство, JSON-фреймы `{t, ...}`. Клиент шлёт `sync`, `send`,
`recv`, `read`, `typing`, `delete`, `ping`, `bg`, `fg`; сервер — `hello`,
`sent`, `msg`, `receipt`, `typing`, `presence`, `chat`, `deleted`, `pong`.
Доставка at-least-once, порядок по `seq`, идемпотентность по `clientMsgId`.
После реконнекта клиент присылает per-chat курсоры, сервер доигрывает
пропущенные сообщения батчами, а следом тумбстоуны и read/delivered-марки.
Всё остальное (регистрация, ключи, профили, медиа, контакты) — HTTP.

Полная спецификация: `docs/protocol.md`.

## E2EE

- Identity устройства: пара ключей X25519 (DH) + Ed25519 (подписи). CryptoKit не
  умеет XEd25519, поэтому ключи раздельные.
- 1:1 — X3DH (identity + signed prekey + one-time prekey) → Double Ratchet.
  Корневая и цепочечные KDF — HKDF-SHA256 и HMAC-SHA256, шифрование —
  ChaChaPoly, заголовок ratchet идёт в associated data. Пропуски и
  переупорядочивание — через skipped message keys (до 1000 подряд, 2000 в
  хранении).
- Группы — sender keys: своя цепочка на чат, раздаётся pairwise-каналом внутри
  обычного сообщения, каждое групповое сообщение подписано Ed25519. Выход
  участника ротирует нашу цепочку.
- Медиа — случайный ключ на файл (ChaChaPoly), ключ и SHA-256 ciphertext едут
  внутри E2E-сообщения, сервер видит только блоб.
- Верификация — safety numbers (60 цифр, 5200 итераций SHA-512).
- Приватные ключи и состояния сессий лежат в БД, зашифрованные мастер-ключом;
  сам мастер-ключ — файл в контейнере app group под Data Protection.

Подробности флоу: `docs/crypto-flows.md`.

## Клиентское ядро (MsngrKit)

- **MsngrCrypto** — X3DH, Double Ratchet, sender keys, шифрование медиа, safety
  numbers. Без зависимостей, кроме CryptoKit.
- **MsngrCore** — GRDB-хранилище (SQLite в WAL) как единственный источник правды
  для UI, `WSClient` (реконнект с backoff до 12 с, мгновенный реконнект по
  `NWPathMonitor`, ping/pong keepalive), `SyncEngine` (применение фреймов,
  outbox, очередь сервисных действий, дотяжка профилей, автопополнение
  prekeys), `E2EEManager`, `MediaManager`, `APIClient`, BlurHash, мозаика
  альбомов, image pipeline.

Очереди в БД: `outbox` (исходящие, состояния `ready`/`inflight`/`blocked`),
`pendingAction` (read-марки, delete-for-all, accept — схлопываются и дренятся
при подключении), `pendingDecrypt` (сообщения, пришедшие раньше своего ключа),
`pendingApply` (правки, реакции и тумбстоуны без оригинала).

## Хранилище

Единая точка вычисления путей — `StorageLocation`/`AppContainer`. Корень —
контейнер app group `group.ai.enface.msngr`, чтобы NSE читал те же файлы; без
группы (macOS, тесты) — Application Support. Содержимое: `msngr.sqlite`,
`.masterkey`, `avatars/`, `media-outgoing/`.

Переезд из Application Support в контейнер делает `StorageMigration`: копия во
временный каталог внутри нового корня, перемещение на место, только потом
удаление оригиналов. Файл БД переносится последним — до этого новый корень
считается незанятым, поэтому прерванный перенос доводится до конца на следующем
запуске. Файлы получают `completeUntilFirstUserAuthentication`, чтобы
расширение читало их при заблокированном экране.

## iOS-клиент

- Лента сообщений — `UICollectionView` с ручным диффом и предрассчитанным
  layout-планом (кэш замеров), инвертированный скролл, пагинация вверх без
  прыжков. Остальной UI — SwiftUI.
- Оффлайн-first: UI читает только БД через `ValueObservation`, сеть — фоновая
  синхронизация. Отправка работает без сети: сообщение и вложение ложатся в
  outbox, выгрузка и шифрование происходят при подключении.
- Пуши: APNs + Notification Service Extension, который берёт уже расшифрованный
  текст из общей БД (ключи для показа превью не нужны). In-app баннер при
  активном приложении, дедуп с системным пушем по msgId, бейдж из локального
  `unreadCount`.
- Пин-код с Face ID, блюр в app switcher, авто-лок.
- Голосовые: `AVAudioRecorder` в m4a/AAC, waveform из реальных амплитуд,
  slide-to-cancel и lock.

## Принципы

- Сервер никогда не видит plaintext сообщений и медиа.
- Клиент никогда не блокируется сетью: UI ← SQLite, сеть — фоном.
- Один WS на устройство; всё остальное — HTTP.
- Обратная совместимость не поддерживается, точки для версионирования заложены
  (см. `docs/PROCESS.md`).
