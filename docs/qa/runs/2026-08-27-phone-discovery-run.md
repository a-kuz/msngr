# Discovery over the address book finds accounts by the number's hash

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803.

## The change under test

The client could ask `/api/contacts/discover`, but nothing ever uploaded the
account's own hash: `setPhoneHash` had no caller, so no account was
discoverable. Settings grew a «Телефон» section: the number is normalized to
E.164 and hashed on the device (`Phone.e164`/`Phone.hash`, shared with the
address-book sync), the hash goes to `/api/phone`, the raw number stays on
the device in a `kv` row. An emptied field takes the hash down. A number
that does not normalize keeps the screen open with the reason in the footer.

## How

- Bravo's and charlie's hashes were published to the stand over `/api/phone`
  with their fixture tokens (+79260000002 and +79260000003).
- A vCard with «Boris Bravov, +7 926 000-00-02» and «Carl Charliev,
  8 926 000-00-03» went to the simulator through `simctl addmedia`; contact
  access was pre-granted.
- Alfa typed +79260000001 into Настройки → Телефон and hit Готово.

## Seen

- The stand answered a discover for alfa's own hash with alfa's account, and
  the `kv` row `myPhone` held the E.164 form: the hash upload is wired.
- «Новый чат» showed a «Контакты» section with both accounts under their
  address-book names — «Boris Bravov» over the profile's «Bravo Service»,
  the book name taking precedence — and charlie matched through the 8-form
  number folded into +7.
- The tap on the row opened the direct chat with Bravo.

`PhoneTests` holds the normalization (international form, separators, the
8 → +7 fold, refusal of short and local forms) and the hash determinism the
match depends on.
