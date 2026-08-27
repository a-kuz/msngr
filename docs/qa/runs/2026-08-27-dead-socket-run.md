# A dead socket caught by the clock

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5) with
the `alfa` home of a private trio, against a stand of its own on :8803 (the
same setup as `2026-08-27-offline-queue-run.md`).

## How

Killing the stand is the easy case: the kernel resets the connection and the
client hears about it at once. A socket that goes silent is the one the
watchdog exists for, so both processes of the stand (`wrangler dev` and its
`workerd`) were stopped with `SIGSTOP`: the TCP connection stays open, every
frame the client sends is acknowledged by the kernel, nothing ever answers.
The header strip was screenshotted every 2 s and the times of its changes
logged; 55 s later both processes got `SIGCONT`.

## Seen

```
14:38:31  stand frozen                       header «был(а) 8 мин. назад»
14:38:48  header → «подключение…»            17 s after the freeze
14:39:26  stand thawed
14:39:30  header → «был(а) 15 мин. назад»    4 s after the thaw
```

Seventeen seconds is the rule as written: 12 s of quiet before the client
asks with a ping, 4 s for the pong, and the once-a-second tick that notices.
The reconnect after the thaw took the first backoff step.

## A trap for the next run

`pkill -STOP -f "port 8803"` matches `wrangler dev --port 8803` and misses
`workerd`, whose arguments spell the port as `--socket-addr=entry=localhost:8803`;
with only the parent frozen the stand keeps serving and the header never
moves. The processes have to be found separately and signalled one by one.

## Not covered

The socket dying in the background (the app not in front): the run kept the
chat on screen.
