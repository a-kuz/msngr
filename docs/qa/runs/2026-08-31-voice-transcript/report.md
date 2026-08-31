# Voice transcript on the device — live run, 2026-08-31

Simulator `fable-tr` (iPhone 17, iOS 26.5), a fresh `trvoice` account, the
shared stand. The voice message is a real take: `say -v Milena` spoke into the
host microphone while the record button was held.

## What ran

1. A 7-second voice note was recorded and sent in the self chat; the bubble
   shows the «Aa» transcript button at the right edge of the waveform.
2. The simulator ships no speech models — `SpeechTranscriber.supportedLocales`
   is empty and `SFSpeechRecognizer.supportsOnDeviceRecognition` is false — so
   a tap on a fresh take correctly cannot recognize there. The button hides
   itself on messages with nothing cached once the availability probe answers
   (`folded.png` shows it back once a transcript exists).
3. The recognition path itself was proven on the host with a probe making the
   same calls (`/tmp/tr-probe`, macOS 26): SpeechAnalyzer lists 30 locales with
   no Russian, and the SFSpeechRecognizer fallback pinned to on-device
   recognition transcribed the same take exactly — «Привет это проверка
   транскрипта голосового сообщения» — with per-word timings. That fallback is
   what the app runs for Russian.
4. The UI cycle ran live with the probe's transcript and timings written onto
   the message row: the «Aa» tap unfolds the text under the waveform and the
   bubble grows in place (`unfolded.png`); playback underlines the words as
   they are spoken, the boundary interpolating inside the current word —
   mid-run it stands inside «транскрипта», later inside «сообщения»
   (`karaoke-mid.png`, `karaoke-late.png`); at the end of playback the
   underline clears; a second tap folds the bubble back single-storey
   (`folded.png`). The unfolded state survives a relaunch (it is a database
   column).

## Checks

- `TranscriptTests` in MsngrCoreTests — 4 tests: the transcript, its spans and
  the unfolded flag round-trip through the database; a message without one
  reads back empty; `spokenLength` interpolates inside the current word and
  counts UTF-16 units. Green.
- `BubbleLayoutTests.testVoiceTranscriptUnfoldsUnderTheWaveform` — folded
  draws no text, unfolded puts the transcript under the waveform and grows the
  cell. Green.
- Full suites: MsngrTests 304/304, MsngrCoreTests 497 (18 integration skips).

## Not verified here

Recognition end to end inside the app needs a device: the simulator has no
speech models of either API. The exact calls are proven by the host probe; the
first run on a device is what closes this for real.
