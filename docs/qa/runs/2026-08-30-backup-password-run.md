# Backup under the user's own password, and restore after the last logout — live run

2026-08-30, simulator `fable-ipad` (iPad Pro 11", 27D0AF17), account
`kb88042278`, plus the shared stand for the owner's `mac` account.

## What changed

- `BackupSeal` seals under a typed password as `v: 2`: PBKDF2-HMAC-SHA256,
  600k rounds, a random 16-byte salt riding in the file; the recovery-code
  path stays `v: 1` and opens as before. `open` dispatches on the file's
  version, so one field on the restore screen serves both.
- Turning backup on now offers the choice: a generated code (with tap-to-copy
  on the code row) or a typed password entered twice.
- The restore screen reads the picked file's version and asks for a recovery
  code or a backup password accordingly.
- The server keeps an `accountIdentity` record in the user's object that
  device revocation does not touch, and `/api/restore/start` verifies against
  it: logging out of the last device — the exact state a backup is for — no
  longer answers `account_has_no_devices` (the owner hit this live).
- The Backup and Restore screens got their Russian strings; they had shipped
  English-only.

## What was seen

Turn on → «Use my own password» → the password typed twice → Continue sealed
and exported `msngr-kb88042278.msngrbackup` (2 КБ) to On my iPad; the Backup
screen showed the run («Последняя копия», «Размер»). A tap on a generated
code put `10H5-5M47-…` on the pasteboard (`simctl pbpaste` read it back).
Then Выйти wiped the device, «Restore from a backup» picked the file, the
screen asked for «Backup password» (a `v: 2` file), and the account came back
with «Избранное» and its history — the full password round trip with no
account left on the device in between.

The owner's `mac` account on the shared stand, dead-ended on
`account_has_no_devices`, was healed: the fixed server deployed to adad, the
account identity extracted from the owner's own backup file and written back
through a one-off route (registered and immediately revoked, leaving only
`accountIdentity`), the route removed; `/api/restore/start` for `mac` now
issues a nonce.

## What holds the behaviour

- `BackupSealTests` (units, 6): both round trips, a wrong password refused,
  whitespace-trimmed passphrase, per-seal salt, an empty passphrase refused.
- Smoke `restore: registered / logout of the only device / start with zero
  devices / claim adds a device back / the restored device authenticates` —
  ALL PASS against a throwaway stand.
- Two red smokes on the way were the stand's own launch, not the code: a
  stand started without `CMID_MIN_AGE:0 CMID_SWEEP_EVERY:0` fails `cmid swept
  behind the sender's ack` honestly (the sweep waits its 72 hours), and a
  persist dir reused across runs leaks queued pushes into `no push for own
  echo`. `scripts/smoke-stand.sh` is the reference launch.
- `scripts/grid.py` labelled iPad screenshots @3x and every read-off tap
  missed; the scale now comes from the device type.
