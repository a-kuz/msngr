# NSE на симуляторе: эксперимент

Дата: 2026-08-14. Стенд: macOS 25.5, Xcode 26.6 (17F113), симулятор `nse-test`
(iPhone 17 Pro, iOS 26.5), собственный, удалён после прогона.

## Вердикт

`xcrun simctl push` **не запускает Notification Service Extension** — ни в
одном из трёх состояний приложения (foreground, background, killed). Баннер
показывается ровно тем содержимым, что лежит в payload.

Это ограничение канала доставки, а не нашего кода: контрольное расширение без
единой зависимости в отдельном приложении ведёт себя так же.

Отдельный результат, положительный: **Communication Notifications (аватарки и
имя отправителя) работают на симуляторе без платного аккаунта**, если контент
формирует само приложение. Проверено на локальных уведомлениях.

## Что было в репозитории до эксперимента

Таргет `NotificationService` уже описан в `ios/project.yml` (app-extension,
`NSExtensionPointIdentifier: com.apple.usernotifications.service`, встраивается
в Msngr через `embed: true`), код — `ios/NotificationService/NotificationService.swift`
из коммита ee0538b. Собирался и раньше; проверено, что `.appex` попадает в
`Msngr.app/PlugIns/` и регистрируется системой:

```
$ xcrun simctl spawn <udid> pluginkit -mv | grep enface
ai.enface.Msngr.NotificationService(1.0)  2B42A7EB-…  …/Msngr.app/PlugIns/NotificationService.appex
```

Оба entitlements-файла были пустыми `<dict/>`: xcodegen перегенерирует их из
`project.yml`, поэтому app group добавлена туда (`entitlements.properties`), а
не правкой .entitlements.

## Что делает NSE сейчас

`didReceive` логирует `[NSE] didReceive run=<uuid>`, дописывает строку в
`nse-marker.log` в контейнере app group и (только в DEBUG) префиксует заголовок
строкой `NSE: `. `serviceExtensionTimeWillExpire` отдаёт `bestAttempt`. Три
независимых канала наблюдения — баннер, файл, unified log — чтобы не спутать
«расширение не отработало» с «отработало, но не увидели».

`SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` для таргета проверен, ветка
живая.

## Ход эксперимента

Payload по `docs/protocol.md` (`mutable-content: 1`, `thread-id`, `badge: 3`,
`chatId`, `msgId`), команда `xcrun simctl push <udid> ai.enface.Msngr payload.json`.

| состояние | баннер | маркер-файл | NSLog от NSE |
|---|---|---|---|
| foreground | «Msngr / Новое сообщение», без префикса | нет | нет |
| background | то же | нет | нет |
| killed | то же, бейдж 3 на иконке | нет | нет |


Бейдж из payload применяется, `thread-id` доходит (виден в логе SpringBoard как
`threadIdentifier: chat-demo`) — то есть уведомление доставляется полностью,
пропущен ровно этап мутации.

## Почему не запускается

Полный debug-лог симулятора в момент пуша показывает путь доставки:

```
CoreSimulatorBridge [com.apple.UserNotifications:Connections] [ai.enface.Msngr] Creating a user notification center
CoreSimulatorBridge [ai.enface.Msngr] Adding notification request 9C6D-779F to destinations: Default
usernotificationsd  [com.apple.CoreSimulator.CoreSimulatorBridge] Entitlement check success: simulator
usernotificationsd  Forwarding addRequest: ai.enface.Msngr
SpringBoard          … trigger: <UNPushNotificationTrigger: …; contentAvailable: NO, mutableContent: YES>>
SpringBoard          [ai.enface.Msngr] Saving notification 9C6D-779F: YES [ … pipelineState: pending]
```

`simctl push` — это вызов `addNotificationRequest:forBundleIdentifier:` от
процесса CoreSimulatorBridge, то есть локальное уведомление с подставленным
push-триггером, а не трафик через apsd. Точка расширения
`com.apple.usernotifications.service` за весь прогон не запрашивается ни разу
(0 вхождений в 18406 строк лога), pkd в доставке не участвует. Флаг
`mutableContent: YES` система видит и игнорирует.

Крэш-репортов расширения нет (ни в `~/Library/Logs/DiagnosticReports`, ни в
`CrashReporter` симулятора) — процесс не падает, он не стартует.

### Контроль

Отдельное приложение `NSEProbe` с расширением без зависимостей (только
UserNotifications, запись файла в свой Documents, NSLog, подмена title/body) —
результат тот же: баннер исходный, файла нет, лога нет. Значит дело не в
MsngrKit, не в GRDB, не в app group и не в debug-dylib.

Apsd в симуляторе живой и держит соединение с 5223 — путь настоящего APNs
существует, но требует токен устройства и ключ APNs, то есть платный аккаунт.

## Что осталось непроверенным

Ни один вопрос, ответ на который требует живого процесса расширения, на
симуляторе не закрыть:

- подмена `body`/`subtitle` силами NSE и её вид в баннере и на локскрине;
- `serviceExtensionTimeWillExpire` и 30-секундный бюджет;
- доступ к контейнеру app group и к Keychain из процесса расширения;
- лимит памяти расширения (24 МБ) на реальной расшифровке.

Косвенно: entitlements расширения на симуляторе формируются корректно —
`NotificationService.appex-Simulated.xcent` содержит `application-identifier` и
`com.apple.security.application-groups: group.ai.enface.msngr`. Это аргумент за
то, что доступ будет, но не доказательство.

## App groups на симуляторе

Работают без платного аккаунта. installd создаёт контейнер при установке:

```
$ xcrun simctl get_app_container <udid> ai.enface.Msngr groups
group.ai.enface.msngr  …/data/Containers/Shared/AppGroup/A560C895-…
```

Контейнер появляется именно из-за entitlement: у NSEProbe, где группа не
объявлена, команда возвращает пустой ответ.

Ловушка при диагностике: `codesign -d --entitlements` и файл `*.app.xcent` на
симуляторных сборках показывают пустой словарь. Реальные entitlements лежат
рядом в `*-Simulated.xcent` (и `.der`), их и читает installd.

Entitlement заведён вместе с переносом файлов (`StorageLocation`,
`StorageMigration` в MsngrCore): включение группы меняет корень хранилища с
Application Support на контейнер группы, а вместе с ним переезжают
`msngr.sqlite` и `.masterkey`. Без переноса для уже установленных сборок это
выглядело бы как чистая установка со сменой identity-ключей; живой апгрейд
проверен в `docs/qa/runs/2026-08-14-appgroup-run.md`.

Мастер-ключ, которым NSE будет расшифровывать превью, хранится файлом
`.masterkey` в контейнере app group (`SharedFileMasterKey`,
`ios/MsngrKit/Sources/MsngrCore/KeyStore.swift`), не в Keychain — отдельная
группа доступа Keychain для расшифровки в расширении не нужна.

## Аватарки в уведомлениях (Communication Notifications)

Проверялось на приложении NSEProbe локальными уведомлениями: рендерингом
занимается SpringBoard, и для него безразлично, кто сформировал контент —
приложение или расширение. Поэтому результат переносится на NSE, когда тот
заработает на устройстве.

Что нужно, чтобы аватар нарисовался (все три условия обязательны, при любом
пропущенном `updating(from:)` молча возвращает контент без изменений и ошибку
не бросает):

1. entitlement `com.apple.developer.usernotifications.communication`;
2. `NSUserActivityTypes` в Info.plist со строкой `INSendMessageIntent`;
3. в `recipients` интента — `INPerson` с `isMe: true`.

Донат интента (`INInteraction.donate`) не нужен: на чистой установке, где
донатов не было ни разу, аватар рисуется. Донат остаётся нужен для других
вещей (Siri-предложения, шторка «Поделиться»), но не для баннера.

Платный аккаунт не требуется: сборка с этим entitlement проходит подписью
«Sign to Run Locally», ключ попадает в `NSEProbe.app-Simulated.xcent`.

Один на один — круглый аватар отправителя, заголовок заменяется на его имя,
иконка приложения уходит в угловой бейдж:


Группа (`speakableGroupName` + два `recipients`) — заголовок остаётся именем
отправителя, название группы становится subtitle, аватар всё равно
отправителя; картинка, назначенная параметру `speakableGroupName`, в баннере не
используется:


Без entitlement — обычный баннер с иконкой приложения, никакой диагностики:


Аватар передаётся как `INImage(imageData:)`, то есть NSE должен получить
байты картинки локально, без сети. Удобное хранилище — файлы в контейнере app
которые пишет приложение при обновлении профиля. Размер: 180×180 достаточно,
баннер показывает аватар мелко.

## Что это значит для планирования

До покупки аккаунта можно делать почти всю содержательную часть, если NSE
останется тонким адаптером:

- вся логика превью (расшифровка, выбор текста, «Имя: текст» для групп,
  плейсхолдеры для медиа, gap-fill по пропущенным msgId, счёт бейджа) живёт в
  MsngrCore и покрывается юнит-тестами — там симулятор вообще не нужен;
- визуальную часть (аватарки, группы, thread-id, длинные тексты) можно
  доводить сегодня: приложение строит контент тем же кодом и постит локальное
  уведомление. Это же даёт e2e-проверку на симуляторе на дев-стенде;
- в `didReceive` остаётся только склейка: прочитать userInfo, дёрнуть билдер,
  отдать contentHandler.

Чего до устройства с платным аккаунтом не узнать: что расширение вообще
поднимается, укладывается ли в 30 с и в лимит памяти, видит ли app group и
Keychain из своего процесса. Это риск для сроков, но не для архитектуры —
запускать его придётся один раз, когда аккаунт появится.

Дев-стенд с `apns-mock` остаётся полезным для проверки серверной части (что
пуш ушёл, с каким payload, с каким бейджем), но проверить им превью нельзя.
Стоит завести в моке или в приложении режим «показать превью локально», иначе
любая правка NSE будет непроверяемой.

## Воспроизведение

```
cd ios && xcodegen
xcodebuild -project ios/Msngr.xcodeproj -scheme Msngr -destination "id=<udid>" build
xcrun simctl install <udid> <…>/Msngr.app
xcrun simctl push <udid> ai.enface.Msngr payload.json
xcrun simctl spawn <udid> log stream --level debug --predicate 'eventMessage CONTAINS "[NSE]"'
xcrun simctl get_app_container <udid> ai.enface.Msngr group.ai.enface.msngr
```
