# Msngr — архитектура

Мессенджер уровня Telegram/WhatsApp: iOS-клиент + бэкенд на Cloudflare Workers.

## Компоненты

```
ios/            SwiftUI/UIKit клиент (iOS 17+), GRDB (SQLite), CryptoKit
server/         Cloudflare Worker: HTTP API, WS, Durable Objects, R2, APNs
docs/           протокол, крипто-схема
```

## Бэкенд

- **Worker (router)** — HTTP API (`/api/*`), WebSocket upgrade (`/ws`), выдача R2-ссылок на медиа.
- **UserSessionDO** — по одному на пользователя. Держит все WS-соединения его устройств,
  очередь недоставленных событий (inbox, storage DO), счётчики непрочитанного, push-токены.
  Всё, что адресовано пользователю, проходит через его DO — единая точка fan-in.
- **ConversationDO** — по одному на чат (1:1 и группа). Хранит: членство, роли,
  журнал сообщений (ciphertext + метаданные), pin'ы, настройки. Присваивает
  монотонные seq сообщениям. Fan-out: после записи рассылает событие в UserSessionDO
  каждого участника.
- **D1** — справочник пользователей (username → userId, публичные identity-ключи,
  профили), device registry, prekey-бандлы.
- **R2** — медиа-блобы (зашифрованы на клиенте, сервер видит только ciphertext).
- **Push** — APNs token-based auth (p8). UserSessionDO шлёт пуш, если ни одно
  устройство не онлайн. Тело пуша не содержит plaintext (только chatId/msgId,
  для превью — mutable-content + Notification Service Extension расшифровывает локально).

## Протокол (WS)

JSON-фреймы `{t: <type>, ...}` поверх одного WS на устройство. Клиент шлёт команды
(send, ack, typing, read, ...), сервер шлёт события (msg, receipt, presence, ...).
Доставка: at-least-once + идемпотентность по clientMsgId; порядок — по seq внутри чата.
Resume: клиент присылает per-chat курсоры, сервер доигрывает пропущенное.
Полная спецификация: docs/protocol.md.

## E2EE (docs/crypto.md)

- Identity: Curve25519 (подпись Ed25519 + DH X25519), генерируется на устройстве,
  приватные ключи не покидают Keychain/Secure Enclave.
- 1:1: X3DH (identity + signed prekey + one-time prekeys) → Double Ratchet
  (root/chain KDF на HKDF-SHA256, сообщения — AES-256-GCM... фактически ChaChaPoly из CryptoKit).
- Группы: Sender Keys — каждый участник имеет sender key (chain key + подпись),
  раздаётся участникам pairwise-каналами; ротация при выходе участника.
- Медиа: файл шифруется случайным ключом (ChaChaPoly), ключ+хэш едут внутри E2E-сообщения,
  сервер хранит только блоб в R2.
- Верификация: safety numbers (QR/цифры) из identity-ключей.

## iOS-клиент

- **UI**: SwiftUI, кастомный чат-лист на UICollectionView (производительность списка
  сообщений уровня TG: инвертированный скролл, прелоад, ячейки-бабблы с inline-временем).
- **Хранилище**: GRDB (SQLite, WAL) — единственный источник правды для UI (offline-first).
  Всё, что пришло/отправлено, сначала пишется в БД; UI наблюдает через ValueObservation.
- **Сеть**: URLSessionWebSocketTask + очередь исходящих в БД (outbox): отправка работает
  офлайн, ретраи с backoff, идемпотентность по clientMsgId.
- **Крипто**: CryptoKit; ratchet-состояния в SQLite (шифруются ключом из Keychain).
- **Пин/блокировка**: локальный пин + FaceID, блюр в app switcher, авто-лок.
- **Голосовые**: AVAudioEngine запись (opus/aac), waveform, slide-to-cancel, lock,
  playback c ускорением, продолжение проигрывания по чатам.
- **Пуши**: APNs + Notification Service Extension (расшифровка для превью), badge,
  mute per-chat.

## Функциональный объём (всё обязательно)

Чаты 1:1 и группы (роли admin/member, invite-links), текст, фото/видео/файлы/голосовые,
реплаи, форварды, редактирование, удаление (для себя/для всех), реакции, typing,
онлайн/last seen, галочки доставки/прочтения, поиск (по чатам и сообщениям, локальный),
закреплённые чаты и сообщения, архив, mute, черновики, пересылка при офлайне,
профили (имя, юзернейм, аватар, bio), контакты, блокировка пользователей,
мультидевайс-фундамент (device registry), disappearing messages.
Звонки — вне объёма (явно исключены).

## Принципы

- Сервер никогда не видит plaintext сообщений и медиа.
- Клиент никогда не блокируется сетью: UI ← SQLite, сеть — фоновая синхронизация.
- Один WS на устройство; всё остальное — HTTP (auth, prekeys, медиа, профили).
