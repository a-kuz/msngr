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

### Push on a missed call
A closed app never learns it was called: the `callLog` frame is service, so
no push and no badge. The caller's device, on giving up (`cancel`/`timeout`),
should raise exactly one notification on the callee. The server cannot tell a
missed call from any other frame — the signaling is E2EE — so the shape is
the caller sending the callLog envelope push-raising (NSE decrypts and shows
«Пропущенный звонок») without letting it grow unread as a message. Needs a
frame that pushes but does not count; today those two travel together on the
`service` flag.

### Self-hosted TURN (coturn on adad)
STUN-only ICE fails where both ends sit behind symmetric NAT (typical LTE).
coturn on the adad server relays those calls; a package install and a
10-line config, plus the `turn:` entry with credentials in
`WebRTCTransport.iceServers`. Installing anything on the shared server is
the owner's call.

## Features not built yet

### 1:1 video
The transport is already WebRTC: add the camera track next to the audio one,
a local preview, the remote stream rendered full-screen in CallScreen, a
camera on/off toggle and front/back flip. The signaling does not change
(the SDP renegotiates media by itself); the offer may carry `video: true`
so the ringing screen can say what kind of call it is.

### Picture-in-picture
The ongoing call shrinks into a floating tile instead of owning the whole
screen: in-app first (the user browses chats while talking; the tile returns
to the full screen on tap), then the system PiP (AVPictureInPictureController
over the remote video track) when the app goes to background. In-app PiP is
simulator-checkable; system PiP for video calls needs a device entitlement
check.

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

### Caller named as in my address book
The ringing screen, CallScreen, the call row and the future missed-call push
show the peer's self-chosen profile name. Where my synced address book holds
their number, my local name for them should win — the same resolution
contact discovery already does at match time, applied at display time. One
lookup point (local db: matched contact name by userId) used by CallScreen,
CallMessageView and the chat header.

### Ring and dial sounds
The call is silent until media flows: no dial tone for the caller, no
ringtone for the callee, no hang-up click. Local audio assets played by
CallManager phase transitions; respect the mute switch and stop cleanly on
`connected`.

### ICE restart on network change
Today `disconnected` just waits and `failed` hangs up. A Wi-Fi→LTE move
should trigger an ICE restart (new offer with `iceRestart: true` over the
same signaling) instead of dropping the call. Testable on the simulator by
toggling the host network only roughly; the honest check is a device walking
out of Wi-Fi range.

### Ephemeral relay frame for ICE candidates
Candidate batches ride the chat journal as service frames: a few rows per
call that nobody ever reads again. A relay-only frame (like `typing`,
encrypted but not journaled) keeps the journal clean. Touches
`server/src/types.ts` and the DO relay path — coordinate with the
orchestrator, other branches edit those files.
