# Offline matrix: live run 2026-08-14

## Stand

Simulators off-a (A39EB056) and off-b (8C6816A7), the Msngr build taken from the
simulator itself (the bundle was reinstalled without a rebuild). Own wrangler on
:8790 with isolated state (`scratchpad/offline-run/wstate`), the base URL passed
as the env variable `MSNGR_SERVER=http://localhost:8790` on `simctl launch`, with
no code changes. Offline here means this wrangler stopped, online means it
started again.

The stand of the previous agent, which died, could not be restored: its wrangler
state is not on disk (the user off-a `01KZYHSPY6…` exists in none of the D1
databases that were found) and the app tokens got 401. It was recreated from
scratch: users offa_run2 and offb_run2, a chat created, the first message «Hi
run2» delivered online.

## Run

| # | Scenario | Status |
|---|----------|--------|
| 1 | Text offline, appears at once with the clock, network back, delivered | PASS, taken by the previous run on the stand of the agent that died, not repeated here |
| 2 | Photo offline, preview at once with the clock, network back, delivered to off-b | PASS |
| 3 | Voice message offline, bubble at once, network back, plays on off-b | PASS |
| 4 | App killed offline with an unsent message, launch, message still there, network back, delivered | PASS |
| 5 | Draft: text typed and not sent, leave the chat, kill, launch, text back in the field | PASS |
| 6 | Reaction offline, visible at once, network back, reaches off-b | PASS |

## Details

### 3. Voice message offline, PASS

Offline, recorded by holding the microphone for 2.5 s: a bubble with the waveform
and a duration of 0:02 appeared instantly, status a clock (18:59). After the
network came back (the reconnect on exponential backoff took about 1 to 2
minutes): off-a shows double ticks, off-b received the voice message and it
plays, with a pause icon and orange progress along the waveform.

A note on method: `simctl privacy grant microphone` restarts the app, so the
permission has to be granted before recording. It was granted in advance and the
message was recorded after the restart and reopening the chat.

### 4. Killed offline with an unsent message, PASS

Offline, «Offline survive 4» sent (clock, 19:03), `simctl terminate` then a
relaunch. The message is still there: last in the chat list with a clock icon,
in the chat with a clock, and the whole history intact (text, photo, voice
message). After the network came back, double ticks (19:04) and off-b received
it.

### 5. Draft, PASS

The text «Draft not sent 5» was typed and not sent, the chat was left (the draft
is saved on `onDisappear`), the app killed and launched, the chat opened again,
and the text is back in the input field.

### 2. Photo offline, PASS

Wrangler stopped, the chat header showed «подключение…». A photo from the library
(plus, «Фото или видео», pick, send): a bubble with the full preview appeared in
the feed instantly, status a clock (18:56). After wrangler started: off-a shows
double ticks (`POST /api/media 200` in the log), off-b received the photo and
opened it (`GET /api/media/... 206`).

### 6. Reaction offline, PASS

off-b sent «React to me» online. Offline, on off-a: long tap, reaction picker,
❤️, and the reaction appeared on the bubble instantly while the header still said
«подключение…». After the network came back off-b sees the ❤️ on its own message.

## Observation, not a defect of the matrix

The WS reconnect after the network returns takes up to about 1 to 2 minutes
(exponential backoff; `NWPathMonitor` does not fire because the simulator's
network never changed, the offline state having been imitated by stopping the
server). Delivery of the queue after the reconnect is immediate.
