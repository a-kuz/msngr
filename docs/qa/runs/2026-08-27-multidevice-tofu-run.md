# TOFU covers every device of a peer, not just the first

Run on 2026-08-27 against the shared stand on :8787, in-process through the
core (`MultiDeviceTofuTests`, alongside the CoreIntegrationTests harness).

## The gap under test

The send path checks a recipient's identity key on first use and blocks when
it changes (`E2EEManager.encryptPairwise`). The loop runs over every device
the recipient has, but nothing exercised the case where the *first* device is
trusted and a *second* one carries a different key — the shape an
impersonating device would take. The roadmap had this as verified only in
principle.

## How

- Two accounts register through the real core.
- Bob links a genuine second device over the DeviceLink flow (begin → approve
  → poll → claim), so provisioning's own identity-match check passes.
- That second device then republishes an identity of its own through
  `/api/identity`. `keys-update` overwrites one device's `ik:` record and does
  not bump `devicesVersion`, so the account now holds two devices that disagree
  on their signing key.
- Alice writes to Bob for the first time. The device set is read cold and
  returns both keys in device-id (ULID) order — the legitimate device first.

## Seen

- The message is blocked: `status = -1`, `failReason = identity_changed`, and
  it never takes a `seq`.
- Bob's `trustedIdentity` row holds the divergent key in `changedPending`,
  which is what the chat's accept banner clears.

Because the legitimate device sorts first, a check that stopped at the first
device would have trusted it and let the send through; the block proves the
loop reaches the second device. `keys-update` leaving `devicesVersion`
untouched means a silent post-cache key rotation would not invalidate a peer's
cached list on its own — noted for a separate look, out of scope here.
