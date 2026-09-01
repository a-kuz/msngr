# Calls roadmap

What the calls block still owes, one item per line of work. Shipped so far,
for orientation: 1:1 audio over WebRTC (E2EE signaling as `call` service
frames, glare, busy, dial timeout), the call row in the feed (`callLog`),
"who can call me" (tier + named exceptions, enforced on the callee, `canCall`
on the user card), the peer named as in the owner's address book, the in-app
fold into a floating tile, our own TURN (coturn on the stand), the ringback
and the ringtone, ICE restart under a live call, ICE candidates off the
journal (the ephemeral `callRelay` frame), the missed-call push
(`service` + `notify`), and 1:1 video with the self-view, the flip and the
signalled camera-off, and the three-way call: the invite from the call
screen, a short-lived mesh of exactly three with the invited-by row.

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

### 1:1 video: what remains
The core is shipped: the camera toggle in the call renegotiates the same
call, the peer's stream renders full-screen, the self-view floats in the
corner with a front/back flip, the renegotiation offer carries whether the
camera is on (off reaches the peer as a state change, not a frozen frame),
and the simulator exercises the whole pipeline through a synthetic
capturer. What remains: a video-call entry point before the call starts
(`video: true` on the first offer so the ringing screen says so), and the
device check with a real camera.

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

## Polish

### ICE restart: the device check
The restart itself is shipped: a disconnect the caller sees for longer than
the delay sends a fresh offer with new ICE credentials over the same
signaling, and the callee answers it on the live transport. What remains is
the honest check — a device walking out of Wi-Fi range into LTE.

