# Language choice

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5) with
a private `alfa` home against a stand of its own on :8803.

## What there is

The bundle carries `en.lproj` and `ru.lproj`, so iOS lists the app under
Settings → Приложения → Msngr with «Предпочитаемый язык → Язык», Русский and
English to choose from. The app's own settings gained a row «Язык» with the
current language as its value («Русский» / "English") that opens the app's
page in Settings through `UIApplication.openSettingsURLString`.

## Seen

- The row reads «Язык, Русский» in the Russian run and "Language, English"
  once the app's language was set to English (`defaults write ai.enface.Msngr
  AppleLanguages -array en`, a cold relaunch): the list read "Chats", "Saved
  Messages", the row's value followed.
- Settings → Приложения → Msngr → Язык offers Русский and English.
- The tap on the row opened Settings; on the simulator it landed on the root
  of Settings rather than the app's page, and the app's page was reached by
  hand through Приложения. Whether the deep link lands on the page on a device
  is the owner's to see; the row's value and the catalog are proven either way.

## Not covered

Choosing the language in Settings by tap: the picker's row did not take the
synthetic tap, so the switch was made through `defaults` instead; the effect
on the app is the same setting.
