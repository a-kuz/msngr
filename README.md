# Msngr

Мессенджер с E2E-шифрованием: iOS + macOS клиенты, бэкенд на Cloudflare Workers.

## Что внутри

- **server/** — Cloudflare Worker: HTTP API + WebSocket, Durable Objects
  (`UserSessionDO` — соединения/inbox/пуши, `ConversationDO` — журнал чата/членство/fan-out),
  D1 (пользователи, устройства, prekeys), R2 (зашифрованные медиа), APNs.
- **ios/MsngrKit/** — переносимое ядро (Swift Package):
  - `MsngrCrypto` — X3DH, Double Ratchet, Sender Keys, шифрование медиа, safety numbers.
  - `MsngrCore` — GRDB-хранилище (offline-first), WS-клиент, SyncEngine, E2EE-pipeline,
    медиа, BlurHash, мозаика альбомов, image-pipeline.
- **ios/Msngr/** — iOS-приложение (SwiftUI + UIKit для списка сообщений).
- **ios/MsngrMac/** — macOS-приложение (то же ядро, SwiftUI split-view).
- **ios/NotificationService/** — расшифровка превью пушей.

Функции: чаты 1:1 и группы (роли, инвайты), текст/фото/видео/файлы/голосовые/альбомы,
реплаи, форварды, реакции, редактирование, удаление у себя/у всех, typing,
онлайн/last seen, галочки доставки/прочтения, message requests (как в Signal),
закреплённые чаты и сообщения, архив, mute, черновики, поиск, disappearing messages,
блокировки, контакт-дискавери по хэшам телефонов, TOFU + safety numbers,
пин-код + Face ID, офлайн-очередь. Без звонков.

## Запуск

### Бэкенд (локально)

```bash
cd server
npm install
npx wrangler d1 execute msngr --local --file=schema.sql
npx wrangler dev --port 8787
```

Смоук-тест API/WS (нужен запущенный `wrangler dev`):

```bash
cd server && node test/smoke.mjs
```

### Тесты ядра

```bash
cd ios/MsngrKit
swift test                       # крипто + утилиты (без сервера)
# интеграционные тесты SyncEngine требуют запущенный wrangler dev на :8787
```

### iOS

```bash
cd ios
brew install xcodegen            # если ещё нет
xcodegen generate
xcodebuild -project Msngr.xcodeproj -scheme Msngr \
  -destination 'platform=iOS Simulator,name=iPhone 17 dev' build
```

Сервер по умолчанию `http://localhost:8787` (переопределяется переменной окружения
схемы `MSNGR_SERVER`). Симулятор ходит на localhost хоста напрямую.

### macOS (удобно для тестирования переписки вторым клиентом)

```bash
cd ios
xcodebuild -project Msngr.xcodeproj -scheme MsngrMac -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Msngr-*/Build/Products/Debug/MsngrMac.app
```

## Деплой бэкенда

Создать D1/R2, прописать `database_id` в `wrangler.jsonc`, задать секреты APNs:

```bash
npx wrangler d1 create msngr
npx wrangler r2 bucket create msngr-media
npx wrangler d1 execute msngr --remote --file=server/schema.sql
npx wrangler secret put APNS_KEY_P8     # содержимое .p8
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_TOPIC       # bundle id приложения
npx wrangler deploy
```

## Документация

- `ARCHITECTURE.md` — компоненты и принципы.
- `docs/protocol.md` — HTTP/WS протокол, E2E-конверт.
- `docs/crypto-flows.md` — первый контакт, TOFU, контакт-дискавери.
- `docs/ui-spec.md` — детали UI (размещение времени, реакции, голосовые, мозаика, анимации).
