# Переезд хранилища в контейнер app group: живой апгрейд

Дата: ночь с 2026-08-14 на 2026-08-15. Стенд агента: симуляторы `appgroup-a2` (29841E7E, юзер
`agsender2`) и `appgroup-b2` (FA80F7EF, юзер `bobby22`), собственный
`wrangler dev` на :8793 с отдельным `--persist-to`. Симуляторы удалены после
прогона.

## Что проверялось

Установленная сборка без entitlement хранит БД и `.masterkey` в Application
Support. Сборка с entitlement считает пути от контейнера группы. Апгрейд
поверх установленной сборки не должен выглядеть как чистая установка:
аккаунт, история и ratchet-сессии обязаны пережить переезд.

## До миграции

Сборка из коммита 4234a3d, entitlement ещё нет. Два юзера, чат с тремя
сообщениями в обе стороны, расшифровка и галочки прочтения работают.

![до миграции](2026-08-14-appgroup/before-chat-sender.png)

```
Application Support: .masterkey  media-outgoing/  msngr.sqlite  msngr.sqlite-shm  msngr.sqlite-wal  session.json
$ xcrun simctl get_app_container 29841E7E… ai.enface.Msngr groups
(пусто)
md5 .masterkey = 2360c33147fa0bf683c97daa44775061
userId = 01M0116XAC707HC9N6CJSPNEZS
```

## Апгрейд

`xcrun simctl install` поверх, без удаления приложения. Контейнер группы
создаёт installd в момент установки:

```
group.ai.enface.msngr  …/data/Containers/Shared/AppGroup/1792FEB3-…
```

После первого запуска новой сборки:

```
группа:              .masterkey  avatars/  media-outgoing/  msngr.sqlite  msngr.sqlite-shm  msngr.sqlite-wal
Application Support: session.json
md5 .masterkey = 2360c33147fa0bf683c97daa44775061   (тот же файл)
select count(*) from message = 3                    (вся история)
```

## После миграции

Аккаунт тот же (`agsender2`, userId не изменился), история на месте. Обмен
новыми сообщениями в обе стороны: `Posle migracii A` уходит и
расшифровывается у bobby22, ответ приходит и расшифровывается у agsender2.
Ratchet-состояния и identity пережили переезд: при смене мастер-ключа
расшифровка сломалась бы, при смене identity собеседник получил бы
предупреждение о смене ключа.

![после миграции](2026-08-14-appgroup/after-chat-sender.png)

Повторный запуск ничего не переносит заново, БД остаётся той же (5
сообщений), список чатов не меняется:

![после перезапуска](2026-08-14-appgroup/after-relaunch-chatlist.png)

## Тесты

- `swift test` в MsngrKit: 53 теста, из них 8 на перенос хранилища.
- MsngrTests на симуляторе агента: 48 тестов.
- Сборка Msngr под симулятор: BUILD SUCCEEDED.
- `scripts/collect-crashes.sh --since 60`: крашей нет.

## Что осталось непроверенным

Класс защиты файлов (`completeUntilFirstUserAuthentication`) на симуляторе не
проверить: Data Protection там не реализована, так что ни факт применения
атрибута, ни доступ к БД при заблокированном экране на симуляторе не
воспроизводятся. Проверять на устройстве.
