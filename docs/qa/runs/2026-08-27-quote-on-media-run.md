# The quote renders on every media kind

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5), the
`alfa` home against a private stand on :8803, in the direct chat with Charlie.
Each case: the media message is sent, then armed for reply with a right swipe
and answered with text.

## Seen

- **Photo** (seeded via `simctl addmedia`, sent through the picker): the reply
  strip read «Alfa Service / Фото», and the sent bubble's quote reads
  «Вы / 📷 Фото» over the reply text.
- **Video** (a 2 s clip through the same picker, transcoded on send): the
  quote reads «Вы / 🎥 Видео».
- **Voice** (recorded by holding the mic, 0:02): the quote reads
  «Вы / 🎤 Голосовое сообщение».
- **File** (a PDF seeded into the Files app and sent through «Файл»): the
  quote reads «Вы / 📎 quote-doc.pdf» — the file's own name, not a generic
  kind.

All four match the spec's reply strip (docs/ui-spec.md: author at 13 pt
semibold, the preview line under it); the preview is textual by design, no
thumbnail is promised. The album case and the peer-side rendering were live
earlier (qa/runs/2026-08-21-swipe-reply).

## In passing

The first hold on the mic raised the system microphone alert — granted, the
second hold recorded normally. The fixture's `install` pre-grants this, but
the home on this simulator predates the grant list's application to it.
