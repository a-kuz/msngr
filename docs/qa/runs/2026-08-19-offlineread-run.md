# Offline read: live run 2026-08-19

The owner's plane scenario from the defect log: unread accumulates, the stand
dies, opening the chat zeroes the counter with no network, and the read mark
reaches the server after the network returns — with no unread resurrection on
the reader after sync. The code path (`markRead` writes `myReadUpTo` and zeroes
`unreadCount` in one transaction, the server send drains as a `pendingAction`
on reconnect) had never been seen running. No product change was needed: every
step behaved as specified.

Screenshots — `2026-08-19-offlineread/`.

## Stand

Two own simulators, iPhone 17, iOS 26.5, deleted after the run:
`offlineread-a` (51C30EAC) as `offr_reader` / Reader and `offlineread-b`
(FD8FC557) as `offr_sender` / Sender. Own `wrangler dev` on :8847 with
`--persist-to .wrangler-offlineread` and `APNS_HOST:http://localhost:9887`
(apns-mock on that port), migrations applied into the same persist dir. Both
apps launched with `SIMCTL_CHILD_MSNGR_SERVER=http://localhost:8847`. Build
from the working tree at 66961c7. Offline means this wrangler killed; online
means it started again with the same `--persist-to`.

Setup before the scenario: Sender opened the chat through global search, the
first messages arrived as a chat request on the reader, and the request was
accepted online (an unaccepted request is never marked read by design, so the
scenario needs an accepted chat). Messages 1–10 were read online during setup;
the scenario proper ran on messages 11–15.

## Run

| # | Step | Expectation | Fact |
|---|------|-------------|------|
| 1 | Sender sends 5 messages (11–15), reader sits on the chat list, online | row badge 5 | `01`: badge 5 on the Sender row, «Все» tab counts 1 chat |
| 2 | The stand is killed | badge stays 5 | `02`: badge 5, list unchanged |
| 3 | Reader opens the chat, no network | all 15 messages there, «5 непрочитанных» divider, header «подключение…» | `03` |
| 4 | Reader goes back to the list, still no network | badge gone | `04`: no badge, no tab counter |
| 5 | Sender meanwhile, still no network | 11–15 delivered, not read | `05`: 11–15 with grey double ticks, 1–10 orange from setup |
| 6 | The stand comes back with the same persist | read mark reaches the sender | `06`: 11–15 orange double ticks, within a minute of the port answering |
| 7 | Reader after sync | unread does not resurrect | `07`: list still clean |

The reconnect after the stand returned took under a minute for both apps
(exponential backoff; the simulator's network never changed, so `NWPathMonitor`
does not fire — same observation as the 2026-08-14 offline run).

## Verdict

PASS on all steps, no code changed. The defect-log entry moves to Closed with
a pointer here.
