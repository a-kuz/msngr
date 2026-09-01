# A second device of the same account, and a card change — live run

2026-09-01, simulators fable-a and fable-b (iPhone 17), stand `wrangler dev`
on :8809.

## Linking the second device

1. Registered `carduser` («Card User») on fable-a.
2. fable-b → «Уже есть аккаунт — войти по коду» shows a one-time code with a
   countdown; fable-a → Настройки → Активные устройства → Добавить
   устройство takes the code, then shows the joining device by name and asks
   to confirm. Confirmed; fable-b asked «Войти как @carduser?» and landed in
   the chat list of the account.
3. The devices screen on fable-a lists both: fable-a «Это устройство» and
   fable-b with its added-at time (`2026-09-01-second-device-list.png`).

Two codes expired along the way (the countdown is ~2 minutes and the manual
walk to the settings took longer): the new-device side says «Код больше не
действует. Начните заново» with a retry, the entering side says «Код истёк.
Попросите показать новый.» — both honest states, no dead ends.

## The card change

1. On fable-a renamed the profile «Card User» → «Card Renamed»
   (`2026-09-01-card-change-a.png`).
2. fable-b, with no action taken on it, shows «Card Renamed» in its own
   settings (`2026-09-01-card-change-b.png`): the card change reached the
   other device of the account.
