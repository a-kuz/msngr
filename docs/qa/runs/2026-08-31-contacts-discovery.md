# The contact book, and who can find me by number

Date: 2026-08-31. Simulator `fable-priv` (created and deleted for the run),
the alfa fixture home, the shared stand (migration 0010 applied).

## The shape

A user's address book is a set of phone hashes in their own UserDO
(`/contacts-sync`, written by `POST /api/contacts/discover`). Contact-ness is
answered against the peer's current `users.phone_hash` at the moment of the
question (`isContactOf`), so a number registering or changing hands
propagates into nobody's book. D1 keeps one row per user; the book scales in
the owner's object. (The PhoneNumberDO-style reverse index of back-core is
not needed until a "your contact joined" push exists.)

Enforced on top of it:
- `phone_discovery` (everyone / contacts / nobody) gates contact discovery —
  "contacts" answers only searchers whose number the found user holds;
- the "contacts" tier of last seen (presenceVisible, the presence fanout) and
  of the avatar and bio (cards, search, chat lists, the avatar bytes) is
  enforced instead of counting as everyone. The one-frame profile broadcast
  blanks the card for every peer under the contacts tier; contacts get the
  full card from every pull path.

## Checks

- smoke (throwaway stand): the discovery block — a stranger loses the match
  under "contacts", gains it after the found user lists the searcher's
  number, loses it under "nobody"; the bio shows to a contact and blanks to
  a stranger; plus the full suite — ALL PASS.
- `tsc --noEmit` clean; `swift test` 531 tests, 0 failures.
- Live on the simulator: the Privacy screen shows «Кто может найти меня по
  номеру» with Все / Мои контакты / Никто; picking «Никто» landed
  `phoneDiscovery: "nobody"` in `GET /api/privacy` on the shared stand
  (returned to «Все» after the run).
