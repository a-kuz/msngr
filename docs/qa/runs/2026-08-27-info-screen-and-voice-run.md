# The info screen's add-member and invite link; the voice plate

Run on 2026-08-27 on a fresh `iPhone 17` simulator (`solo-live`, iOS 26.5)
with the `alfa` home, against the shared stand on :8787. The build is the
working tree of these commits.

## Adding a member and the invite link (ROADMAP, groups)

In `Design` (alfa is its admin) the info screen's member rows swipe to
«Сделать админом» / «Удалить»; removing Charlie left the list at Alfa and
Bravo. «Добавить участника» then opened an empty sheet: it searched the
server only from the second typed character and offered nothing before that,
so the usual case, adding someone you already talk to, meant typing a name.
And a failed add closed the sheet as if it had worked.

Fixed in the same run: the sheet lists the people this device knows (the
`user` table, minus yourself, the blocked and the current members) before any
query; a query of two characters or more replaces the list with the server's
answer; a failed add keeps the sheet open and marks the row «Не добавлен».
Re-run: the sheet opened with Charlie in it, one tap put him back, the member
list read three names. «Ссылка-приглашение» turned into «Скопировано!» and
the pasteboard held `msngr://join/nNABiE7--NsH`. Joining by the link is
covered by the smoke (four checks); the fixtures have no fourth user to join
with live.

## The voice plate (the owner's report of the same day)

Reproduced with the simulator's text size at accessibility XXXL: the plate is
78 pt there while the wave and the label were laid out for 42, and the
duration label was capped at 60 pt. After the fix the plate lays itself out
from its height (play button centred, the wave over the label, the label as
wide as its text), the wave uses the whole height it has, and the loudness is
normalised to the 95th percentile of the RMS per bucket with a square root
lift, so one click no longer flattens the speech. Seen at the default size
and at XXXL: wave 22 pt tall in a 42 pt plate, 46 pt in a 78 pt plate,
«0:03» and «13:08 ✓» on one bottom line in both.

A second finding behind it: on a cold start the feed measured against the
default text size while the screen already drew at the reader's one — the
`TypeScale` snapshot is taken in `App.init` from `UIScreen.main`, which can
still answer «large» at that moment. One launch showed a 42 pt plate under
huge text, the next a 78 pt one. The snapshot now also takes the category of
the scene that activates, and the feed re-checks it against its own traits
before it appears. Two cold launches at XXXL after the fix: 78 pt both times.

Units: `BubbleLayoutTests.testVoiceTimeStaysOnThePlateAtEverySize` (the time
shares the plate's bottom line at four categories),
`RecordingGestureTests.testWaveformScaleIgnoresASingleSpike`.

## Not covered

A real recording on the device: the wave here comes from the debug seed's
tone and its synthetic amplitudes. The normalisation is unit-tested; how a
spoken take looks is for the owner's next look at the device.
