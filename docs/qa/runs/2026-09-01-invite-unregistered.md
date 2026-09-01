# Run: inviting people who are not registered, 2026-09-01

The new chat sheet's contact discovery now keeps what it could not match:
every synced book number whose hash found no user lands in a «Пригласить в
Msngr» section, one row per person, and the row opens the system share sheet
with an invite text carrying the sender's handle.

The live run (an own simulator, a fresh user against an own stand):

1. «Найти по контактам» → the system contacts dialog → full access. The
   simulator's six sample contacts carry US numbers with no country code;
   `Phone.e164` rightly refuses them all, so the section starts empty —
   only plausible international numbers are invitable by design.
2. A contact with «8 (921) 987-65-43» added to the book: the 8-form folds
   into +7, discovery finds no such user, and the section shows the row —
   named by the number, since the contact has no name
   (`2026-09-01-invite-section.png`).
3. The row opens the share sheet over the text «Я в Msngr, мой юзернейм
   @coordfail1. Присоединяйся!» with the system destinations
   (`2026-09-01-invite-share.png`). There is no store page yet, so the text
   carries the handle rather than a link.

Matched contacts still land in the Contacts section; the invite list sorts
by name and never shows registered people.
