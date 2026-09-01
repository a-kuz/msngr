# Run: the verified mark after a safety-number comparison, 2026-09-01

The safety-number screen area in the direct chat's info gains the mark: with
the 60-digit number unfolded, a «Проверено» toggle sits under it with the
wording that it is for numbers compared out of band; while the number is
folded, a set mark shows as a static seal row.

The storage was already in the schema (`trustedIdentity.verified`, cleared by
`acceptChangedKey`); the core now exposes it (`E2EEManager.setVerified` /
`isVerified` under the crypto gate), and the clearing on a key change is
pinned by `KeyChangeTests.testVerifiedMarkClearsOnKeyChange` — the same key
keeps the mark, an accepted new key drops it.

The live run (the alfa fixture, the Charlie Service direct chat):

- «Код безопасности» unfolds the number with the toggle off —
  `2026-09-01-verified-on.png`.
- The toggle set, the app killed and relaunched: the info screen shows the
  static «Проверено» seal with the number folded —
  `2026-09-01-verified-mark.png`. The mark lives in the local trust table:
  it does not sync anywhere, exactly like the trust it annotates.

Comparing by QR stays open — the simulator has no camera.
