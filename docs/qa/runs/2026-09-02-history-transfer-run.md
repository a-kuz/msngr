# The history moves to a linked device — live run, 2026-09-02

Main at 578c57b plus the history-transfer change committed right after this
run, against the shared stand freshly reseeded after the D1 merge (`alfa`,
`bravo`, `charlie`). Simulators: `gate-runner` as bravo (the approving
device), `fable-charlie` as charlie, a fresh `fable-link` (B8B5C726) with no
account.

## How it travels

The approving device builds the backup payload (`AccountBackup.buildPayload`:
chats, members, messages, the media blobs, folders, palette and the
notification text setting), encodes it, encrypts it the way an attachment is
encrypted and uploads it to `/api/media`; the pointer — media id, key, hash,
size — goes into the provisioning bundle, which is sealed to the new device's
ephemeral key, so the server holds a blob it cannot open and a bundle it cannot
read. The new device opens the bundle, claims, fetches the blob, writes the
rows and the media cache, then primes the chat list from the server snapshot,
so its first sync starts at the end of each journal and pagination never asks
for what the history already brought. Ratchet state is not carried, as with a
backup: the new device's sessions start fresh.

## What was run

1. `fable-link`: «Войти по коду» — the code and its QR, 118 s on the clock.
2. A screenshot of that screen added to bravo's library; bravo: Settings →
   Устройства → Добавить устройство → «Считать код с фото» → the picture →
   «fable-link» → «Подтвердить». The stand logged `POST /api/media` and the
   approve one second apart (18:50:55 UTC).
3. `fable-link`: «Войти как @bravo? / Bravo Service» → «Войти». The stand
   logged the claim and `GET /api/media/<blob>` in the same second.
4. The chat list came up with Charlie Service, Random, Standup, Design, Alfa
   Service and Избранное, each with its last line and time. Random opened on
   its three messages, bravo's own «Same here.» with its double tick.
5. Both databases hold 18 messages in 6 chats; the linked device has zero
   `pendingDecrypt` rows and zero ratchet sessions before its first send.
6. From the linked device, «from the linked device 2153» to Charlie Service
   with charlie's app killed: charlie's extension journal answered
   `received → stored → show`, the row decrypted.
7. The linked device was revoked through `POST /api/sessions/:id/revoke` and
   the simulator deleted.

## What got in the way

The first attempt claimed 410 Gone: the provisioning session lives two
minutes, and driving both simulators by screenshots took longer. The second
attempt ran the whole flow in 27 seconds.
