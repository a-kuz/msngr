# Group calls in a room on the SFU

2026-09-02, three simulators on the shared stand: `alfa`, `bravo` and
`charlie` (the fixture homes) on group-calls-a/b/c, the group `Standup`.
The SFU is `msngr-livekit.service` on adad (LiveKit 1.13.6 in docker, host
networking), reached over `sfu.a-kuz.online` through the same cloudflared
tunnel as the stand; the Worker mints the room ticket.

## What was checked

1. alfa taps the phone in the Standup header. alfa's screen shows the stage
   with itself alone and «Вызов…»; bravo and charlie ring with «Alfa Service
   — Входящий групповой звонок». The SFU log shows alfa's RTC session and its
   audio track. The card «Групповой звонок» lands in Standup on every side.
2. bravo accepts: alfa's stage shows Bravo full-screen, the clock starts.
   charlie accepts: the stage splits top and bottom, Bravo above, Charlie
   below, alfa's own tile floating in the corner.
3. alfa taps the video button in the header for a second call. Every side
   joins with the camera on (the simulator's synthetic pattern): on bravo the
   screen is alfa's stream above and charlie's below, the self view in the
   corner with the flip button, names on the tiles. The SFU reports every
   track with `encryption: GCM` — fourteen entries for the run — so what it
   forwards is ciphertext.
4. charlie hangs up: alfa's stage shows bravo alone, full-screen. alfa hangs
   up: bravo stays in the room alone. bravo hangs up: the card in Standup
   reads «Групповой звонок завершён» with the members and the duration.
5. A card whose call died with its app (the app was killed mid-call while it
   was the only participant): a tap on it joins the empty room; after the
   empty-room timeout the call ends on its own and the card closes. Before
   the fix the card had stayed live for the rest of the day.
6. The 1:1 upgrade: alfa dials charlie from their chat, charlie answers over
   the peer-to-peer transport. alfa taps the add button and picks bravo. Both
   alfa and charlie move into the room in place — the stage replaces the
   avatar, the clock keeps running (2:14 → 2:15) — and the card lands in the
   chat. bravo never rang: the alfa–bravo pairwise session is the severed one
   from `defects.md` (bravo's log: `unreadable … reason=no_session`), so the
   invite over that chat could not be read. Not a call defect.

## Found on the way

- On the second and third simulators the LiveKit audio engine refused the
  microphone the first time (`Audio Engine Error -4010`); those participants
  showed as muted on the others' tiles. The publish is retried once a second
  later and a second refusal joins muted; a device check is still owed. The
  first simulator's microphone always worked, so this reads as the host's
  audio input being shared by several simulators.
- The synthetic camera's publish timed out until the frames were started
  before the publish: a buffer track learns its dimensions from its first
  frame, and the SDK waits for them.
- A card row whose text was edited (from «Групповой звонок» to «… завершён»
  and back through member changes) once drew its title over the icon area;
  reproduced only once, noted in `defects.md`.

## The afternoon pass: every red line worked through

1. The alfa–bravo pair. A message alfa sent sat on bravo as `no_session` and
   its repair was never asked for: bravo's pile of 9749 deferred envelopes is
   swept two hundred at a time, and the newest one waited for the window.
   With the sweep taking each chat's newest envelope first (3dc519e) the
   request left on the first pass, alfa answered over a rebuilt session and
   the message opened thirty seconds after it was sent; the next messages
   both ways opened directly, and alfa dialed bravo 1:1 and they talked.
2. On alfa the delivered message then vanished from the open chat: six
   hundred seq-less «code changed» lines sorted above it and filled the feed
   window. With system lines anchored to the seq they follow (404f78c) the
   chat reads in order: the calls, the invite line, the card, the three
   messages with their ticks at the bottom.
3. The microphone on the second simulator. Reproduced with the permission
   granted well in advance: the audio unit's input is `2 ch, 0 Hz` while the
   first simulator's app runs, and `1 ch, 44100 Hz` once that app is killed,
   after which the same simulator publishes. The host's microphone belongs to
   one simulator at a time. What was the product's: the mute control read
   live with no track up; it now reads muted and the unmute retries the
   input (e9c809c). On bravo's screen the button and the self tile both show
   the microphone off.
4. A member removed from the chat mid-call. In a throwaway group alfa+bravo,
   alfa called, bravo joined, the API removed bravo from the group: the
   Worker took bravo out of the room through the SFU (b036da6), bravo's
   client logged `room disconnected` in the same second and the SFU logged
   `SERVICE_REQUEST_REMOVE_PARTICIPANT`. The first attempt did nothing: from
   adad the tunnel's hostname answers 404 over IPv6 and the Worker took that
   404 for «participant not there». The stand now talks to its own SFU over
   `LIVEKIT_API_URL=http://localhost:7880`, and only twirp's own
   `not_found` counts as done.

## Commands

```
scripts/fixture.py install alfa|bravo|charlie <udid> --launch
cd ios/MsngrKit && swift test --filter "CallManagerTests|CallSignalTests"   # 60 green
cd server && BASE_URL=http://localhost:8803 PUSH_PORT=9873 node test/smoke.mjs   # ALL PASS
ssh adad journalctl -u msngr-livekit -f
```
