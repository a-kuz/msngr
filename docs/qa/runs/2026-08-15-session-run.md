# Сессия переживает перезапуск на чистой установке (#56)

Стенд: симулятор `msngr-ms-agent` (iPhone 17, iOS 26.5), свой `wrangler dev` на
:8802 с отдельным `--persist-to`, приложение запущено через
`SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8802`.

## Причина

`AppState.sessionFileURL` указывал прямо в Application Support
(`FileManager.urls(for: .applicationSupportDirectory)`), а этот каталог iOS в
свежем контейнере не создаёт. Запись шла через `try?`, поэтому отказ был
невидим: регистрация проходила, экран чатов открывался, но `session.json` на
диск не попадал.

Остальные данные при этом сохранялись: БД и мастер-ключ лежат в контейнере app
group, каталог которого создаёт `AppContainer.resolve()`. Сессия была
единственным файлом мимо `StorageLocation`.

Замер на живом контейнере до фикса — в `Library` только `Caches`,
`HTTPStorages`, `Preferences`, `Saved Application State`, `SplashBoard`;
каталога `Application Support` нет.

## Прогон до фикса (код HEAD 8c30820)

1. `01-before-register-screen.png` — чистая установка, экран регистрации.
2. `02-before-registered.png` — регистрация `sessfix1`, открылся список чатов.
3. `03-before-relaunch-lost-session.png` — `simctl terminate` + `launch`, снова
   экран регистрации. В контейнере группы: `.masterkey`, `msngr.sqlite`,
   `avatars`, `media-outgoing`; `session.json` отсутствует.

## Прогон после фикса

Контейнер снесён (`simctl uninstall`), поставлена сборка с фиксом.

4. `04-after-registered.png` — регистрация `sessfix2`. В контейнере группы
   появился `session.json` (155 байт).
5. `05-after-relaunch-session-kept.png` — `simctl terminate` + `launch`,
   пользователь на месте, открывается список чатов.
