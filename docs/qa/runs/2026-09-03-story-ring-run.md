# The story ring and the pass under the navigation bar (B61, B62)

Run on a simulator of my own (`story-ring`, iPhone 17, iOS 26.5) logged in
as `alfa` against the shared stand (`https://msngr.a-kuz.online`), dark
appearance, the Graphite palette. The stand held live stories of `bravo`
(four by the end: two of two frames, two of one), `charlie` (one) and
`ipadonmac` (three clips, posted from the owner's device while the run was
on). Stories were added along the way with `msngrfixture story --as bravo`.

## What changed

The ring is one view, `StoryRing`, used by the tray and the chat list: one arc
per live story, clockwise from the top, a 4 pt break between arcs, a closed
ring for a single story; an unwatched arc wears the spectrum
(`Theme.storyRainbow`), a watched one is grey (`Theme.storyRingSeen`). The
ring and the online dot moved into `AvatarView`, so the dot is drawn over
the ring: it sits on the ring itself at the lower right, a fifth of the
picture's side, with a 1.5 pt halo of background cutting the ring around it,
the way Telegram places it; with no ring it straddles the rim. Before, the dot
stood in the corner of the avatar's square, which is outside the circle, and
overlapped the ring.

In the folded tray the disc of background that cuts each picture out of the
one beneath it is now 1.5 pt past the ring (or past the picture, with no
ring) instead of 5 pt past the picture whatever the ring: the thick black
band around one's own picture is gone.

The chat list's collection view and the header over it run under the
navigation bar (`ignoresSafeArea(.top)` on the container, the header padded by
the bar's height). The rows now leave through the system's soft edge under the
bar; the tray lost its opaque ground (only the folder tabs keep one) and
passes under the bar through `FadeUnderBar`: above the bar's edge a blurred
copy is drawn, thinning out with the depth, the sharp header fades over a
20 pt band below the edge, and once the tray is 42 pt under nothing of it is
drawn at all. Before, the collection view stood inside the safe area and
everything stopped at the bar's bottom edge in a hard line.

## What was watched

- `bravo` with two unwatched stories: two spectrum arcs, breaks at 12 and 6
  o'clock. After watching in the viewer, both arcs grey. After a third and a
  fourth story: three grey arcs and one spectrum arc at 9 to 12 o'clock,
  matching the server's inbox (`GET /api/stories`: `sssu` for bravo).
- `ipadonmac` with three unwatched clips: three spectrum arcs; while online,
  the dot at the lower right on the ring with the ring cut around it.
- The folded stack: own picture, then `ipadonmac`, `bravo`, `charlie`, each
  cutting a thin band out of the next; the plus badge in place.
- A scroll past the top (the list is shorter than the screen, so this is the
  bounce): rows go under the bar blurred and faded by the system, the tray
  blurs and fades with them and is gone when it is under whole; on the way
  back it comes out of the blur. Recorded with `simctl io recordVideo`,
  frames read at 30 fps.

## Along the way

- With `clockwise: true` on `Path.addArc` every arc ran the long way round
  (checked numerically in a macOS script: a quarter arc came out as three
  quarters), and three grey arcs drawn over one spectrum arc read as a closed
  grey ring. `clockwise: false` runs the arc from the start angle to the end
  angle the short way; each arc is its own subpath, since an arc added to a
  path with a current point is joined to it by a line.
- `idb ui swipe` with the default step is read by the list as a long press
  (it opened a row's context menu); `--delta 8 --duration 0.25` scrolls.
- `python3 -m urllib` gets a 403 from the stand's Cloudflare front while curl
  with the same bearer token gets 200; nothing on our side.

## Checks

- `xcodebuild build` for the app, the simulator above: succeeded.
- `xcodebuild test -only-testing:MsngrTests` on the same simulator: 338
  tests, 3 skipped, 0 failures.

## Not covered

The light appearance was seen only once, before the grey of a watched arc was
tuned; the folder tabs under the bar were not exercised (the account has no
folders). The unfolded tray was not pulled open in this run.
