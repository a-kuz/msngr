# Media cache ceiling — live run

2026-08-30, iPad Pro 11" simulator (fable-ipad), the bravo fixture home.

1. Stuffed the decrypted cache (`Library/Caches/media`) to 161 MB with eight
   20 MB files dated Aug 11–18, next to bravo's real cached media.
2. Set the ceiling to 100 MB (the `mediaCacheCeiling` default the settings
   picker writes) and launched the app: startup eviction took the four oldest
   files, the cache settled at 81 MB — under the 90 MB target the 10% slack
   aims for — and every real, recently touched file survived.
3. Settings → «Данные» shows the «Лимит кэша медиа» picker (100 MB–5 GB and
   «Без лимита», default 1 GB), the cleared size next to «Очистить кэш медиа»,
   and the footer explaining that evicted media re-downloads.

MediaCacheCeilingTests (4): oldest-first eviction down to the target, zero
ceiling means unbounded, a cache hit refreshes the file against eviction,
nothing is touched under the ceiling.

Found while driving this run and filed in defects.md: with a hardware
keyboard connected, a tap around the settings sheet aborts the app on a UIKit
focus-map assertion — reports in docs/qa/crashes/, control run without the
keyboard does not crash.
