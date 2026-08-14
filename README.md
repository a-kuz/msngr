# Msngr

Мессенджер со сквозным шифрованием: клиенты для iOS и macOS, бэкенд на
Cloudflare Workers. Прода нет, это разработческий стенд.

## Что внутри

- **server/** — Cloudflare Worker: HTTP API (hono) и WebSocket, два Durable
  Object'а (`UserSessionDO` — сокеты устройств пользователя, чат-лист,
  presence, пуши; `ConversationDO` — журнал чата, членство, `seq`, fan-out),
  D1 (пользователи, устройства, prekeys, блокировки, инвайты), R2 (медиа), APNs.
- **ios/MsngrKit/** — переносимое ядро, Swift Package:
  - `MsngrCrypto` — X3DH, Double Ratchet, sender keys, шифрование медиа, safety numbers;
  - `MsngrCore` — GRDB-хранилище, WS-клиент, SyncEngine, E2EE-пайплайн, медиа,
    BlurHash, мозаика альбомов, image pipeline.
- **ios/Msngr/** — iOS-приложение: SwiftUI, лента сообщений на UICollectionView.
- **ios/MsngrMac/** — macOS-клиент на том же ядре (удобно как второй собеседник).
- **ios/NotificationService/** — NSE: превью пуша из общей БД.

Что умеет: чаты 1:1 и группы (роли и инвайт-ссылки), текст, фото, видео, файлы,
голосовые, альбомы, реплаи, форварды, реакции, правка, удаление у себя и у всех,
typing, онлайн и last seen, галочки доставки и прочтения, message requests,
закреплённые чаты и сообщения, архив, mute, черновики, поиск по списку чатов,
блокировки, контакт-дискавери по хэшам номеров, TOFU и safety numbers, пин-код
с Face ID, офлайн-очередь отправки. Звонков нет.

## Запуск

### Бэкенд

```bash
cd server
npm install
npx wrangler d1 execute msngr --local --file=schema.sql   # один раз
npx wrangler dev --port 8787
```

Серверный смоук (нужен запущенный `wrangler dev`, 63 проверки API/WS/DO/пушей):

```bash
cd server && node test/smoke.mjs
```

Смоук поднимает собственный приёмник пушей на :9871, поэтому дев-мок APNs на
это время надо остановить.

### iOS

```bash
cd ios
brew install xcodegen                  # если ещё нет
xcodegen generate                      # .xcodeproj не в git, генерируется отсюда
xcodebuild -project Msngr.xcodeproj -scheme Msngr \
  -destination 'id=<UDID симулятора>' build
```

Сервер по умолчанию `http://localhost:8787`, переопределяется переменной
окружения схемы `MSNGR_SERVER`. Симулятор ходит на localhost хоста напрямую.

### Тесты ядра

```bash
cd ios/MsngrKit && swift test          # крипто, синк, офлайн, миграции, BlurHash, мозаика
```

Тесты приложения (раскладка бабблов, лента, плашка непрочитанных, решения по
уведомлениям, валидация регистрации) и UI-смоук — через xcodebuild:

```bash
cd ios
xcodebuild -project Msngr.xcodeproj -scheme Msngr -destination 'id=<UDID>' \
  test -only-testing:MsngrTests
```

Полный гейт качества — `make check` в корне (см. `docs/PROCESS.md`).

### macOS

```bash
cd ios
xcodebuild -project Msngr.xcodeproj -scheme MsngrMac -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Msngr-*/Build/Products/Debug/MsngrMac.app
```

### Пуши на дев-стенде

Apple-аккаунт не нужен: `APNS_HOST` в `server/.dev.vars` уводит пуши в мок,
который доставляет их в симулятор через `simctl`.

```bash
cd server && node tools/apns-mock.mjs --log        # слушает :9871
```

APNs-токеном на симуляторе регистрируется UDID (`SIMULATOR_UDID`). Ограничение
канала: `simctl push` не запускает Notification Service Extension —
`docs/research/nse-simulator-experiment.md`.

## Деплой бэкенда

```bash
npx wrangler d1 create msngr           # database_id → wrangler.jsonc
npx wrangler r2 bucket create msngr-media
npx wrangler d1 execute msngr --remote --file=server/schema.sql
npx wrangler secret put APNS_KEY_P8    # содержимое .p8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_TOPIC     # bundle id приложения
npx wrangler deploy
```

## Документация

- `CLAUDE.md` — правила работы в репозитории для агентов.
- `ARCHITECTURE.md` — компоненты и принципы.
- `docs/protocol.md` — HTTP/WS-протокол, E2E-конверт, пуши.
- `docs/crypto-flows.md` — первый контакт, TOFU, группы, контакт-дискавери.
- `docs/ui-spec.md` — поведение клиента: лента, баббл, анимации, палитры.
- `docs/PROCESS.md` — гейт качества, матрица состояний, стенды.
- `docs/audits/`, `docs/qa/`, `docs/research/` — аудиты, прогоны, исследования.
