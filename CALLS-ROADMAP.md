# Calls roadmap

What the calls block still owes, one item per line of work. Shipped so far,
for orientation: 1:1 audio over WebRTC (E2EE signaling as `call` service
frames, glare, busy, dial timeout), the call row in the feed (`callLog`), and
"who can call me" (tier + named exceptions, enforced on the callee, `canCall`
on the user card).

Each item below stands on its own unless its "needs" line says otherwise.

## Blocked on a decision or a certificate

### VoIP push for incoming calls
Today a call rings only while the app holds a live socket: the offer is a
service frame and raises no push. A closed app needs a PushKit VoIP push (or
a call-typed alert push) sent alongside the offer. Blocked by the missing K2
dev certificate — real APNs to a device does not work at all yet
(memory: device-push-signing); the simulator cannot check this path either
way, so the whole item is device work.

### CallKit
The system incoming-call screen on the lock screen, the green bar, the call
in the system log. Only worth building together with the VoIP push (CallKit
without a wake-up path only covers the app-open case the in-app screen
already handles), and not verifiable on the simulator.

### Push on a missed call: the device check
The mechanics are shipped: the caller's missed-call `callLog` travels
`service` + `notify` — a push without unread — and the banner says
«Пропущенный звонок». The NSE path (decrypt, write the row, rewrite the
banner) is device work, blocked with the rest of device pushes on the K2
certificate; on the simulator only the server side is verifiable and is
covered by the smoke test.

## Features not built yet

### 1:1 video
The transport is already WebRTC: add the camera track next to the audio one,
a local preview, the remote stream rendered full-screen in CallScreen, a
camera on/off toggle and front/back flip. The signaling does not change
(the SDP renegotiates media by itself); the offer may carry `video: true`
so the ringing screen can say what kind of call it is.

### System picture-in-picture
The in-app fold (the floating tile over the chats) is shipped; what remains
is the system PiP — AVPictureInPictureController over the remote video track
when the app goes to background. Needs 1:1 video first, and a device for the
entitlement check.

### Group calls
A different animal: P2P mesh does not scale past three, so this is an SFU —
self-hosted LiveKit or mediasoup on adad — plus room signaling, a member
grid in the UI, and per-member mute state. Big enough to be its own block;
nothing in the current 1:1 code has to change ahead of it.

### Inviting a third person into a call
From a running 1:1 call, "add person": picks a contact, they get an
incoming-call invite, the call becomes a three-way conference. Needs the SFU
(or a short-lived mesh for exactly three); the invite itself is one more
signaling frame (`invite`, carrying the room) into the third person's direct
chat. UI: the add button on CallScreen and a joining state.

### Invited-by bubble in the chat
When someone is invited into a call, the direct chat between inviter and
invitee gets a row that says so — «X пригласил Y в звонок», the way group
events leave a line. Rides the same pattern as `callLog` (service on the
wire, a row in the feed); worth doing together with the invite frame so the
row is written by the inviter exactly once.

## Polish

### ICE restart: the device check
The restart itself is shipped: a disconnect the caller sees for longer than
the delay sends a fresh offer with new ICE credentials over the same
signaling, and the callee answers it on the live transport. What remains is
the honest check — a device walking out of Wi-Fi range into LTE.

### Ephemeral relay frame for ICE candidates
Candidate batches ride the chat journal as service frames: a few rows per
call that nobody ever reads again. A relay-only frame (like `typing`,
encrypted but not journaled) keeps the journal clean. Touches
`server/src/types.ts` and the DO relay path — coordinate with the
orchestrator, other branches edit those files.
