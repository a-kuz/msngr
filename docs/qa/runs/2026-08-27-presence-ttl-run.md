# Presence by ping freshness: the TTL seen live

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5) with
the `alfa` home, against the shared stand on :8787. The peer is bravo as a
headless engine: `msngrfixture typing --as bravo --to alfa --seconds 240`
opens his socket and keeps it typing.

## The question

The server drops a user from «online» not when the socket closes but when no
ping has arrived for `PRESENCE_TTL` (35 s): a socket that is open and silent
does not count. A clean close is the easy case and was seen before
(`2026-08-21-presence-names`); this run is about the silent one.

## How

With alfa's chat with Bravo open and the header reading «печатает…» (bravo's
socket is up, typing every 3 s), bravo's process was frozen with `SIGSTOP`:
the TCP connection stays open, nothing more is sent. The header strip was
screenshotted every 2 s and every change of its pixels was logged with the
clock, then the process was released and stopped.

## Seen

```
14:14:43  bravo frozen
14:14:48  «печатает…» → «в сети»        the 5 s typing expiry on alfa's side
14:15:11  «в сети» → «был(а) только что» 28 s after the freeze
```

The last ping before the freeze was up to one ping interval earlier, so the
flip lands at about 35 s after the last thing the server heard, which is the
TTL. No frame in between showed anything else in the header.

## Not covered

The way back (a frozen peer thawing and the header flipping to «в сети» on
his next ping) was not measured: the fixture was released and stopped in one
move. The clean close is covered by the earlier run.
