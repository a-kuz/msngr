# Link preview card — live run

2026-08-30, iPad Pro 11" simulator (fable-ipad), the shared stand, the alfa and
bravo fixture homes. The feature under test: a text message carrying a link
gets a card — the page's title, description, host and picture — fetched by the
sender's client and carried inside the encrypted payload. The server never
sees the page; the receiver never fetches it.

## Sender (alfa, the Standup group)

1. Typed `card take two https://github.com/torvalds/linux` into the composer.
   Within two seconds the strip over the field showed «GitHub - torvalds/linux:
   Linux kernel source tree» with the page's description — the card built from
   the live page.
2. Sent. The outgoing bubble carries the card under the text: accent bar,
   title, two lines of description, `github.com`, and the page's picture as a
   square thumbnail on the right. The time moved under the card.
3. Tapped the card — SFSafariViewController opened on the page.

## The cross

4. Typed the same link again, pressed the strip's cross, sent. The bubble came
   out bare; the row's `linkPreview` column is NULL.

## Receiver (bravo, same group)

5. Swapped the home to bravo. The incoming message shows the same card —
   title, description, host and the thumbnail, which travelled as an encrypted
   blob through R2 and was decrypted on this side. Nothing on bravo fetched
   github.com.
6. Tapped the incoming card — the torvalds/linux page opened in the built-in
   browser.

## The setting

7. Privacy gained a «Link previews» toggle (local to the device). With it off,
   typing a link raises no strip and no request; back on, the same text builds
   the card again. The toggle rows on that screen would not answer simulator
   taps (the neighbouring Typing toggle would not flip either — the input
   channel, not the code), so the off/on halves were driven through the
   backing UserDefaults key and the app relaunched between them.

## Checks

- MsngrKit `swift test`: all green (LinkPreviewTests — the Open Graph parse,
  the fallback title, the relative image URL, the non-http image dropped, the
  length caps, firstLink order, the row round trip, retrySend's rebuilt
  payload carrying the card).
- MsngrTests `LinkCardLayoutTests` 6/6: the card sits under the text, grows
  the bubble, pushes the time below itself, keeps reaction capsules under it,
  disappears on a tombstone.
