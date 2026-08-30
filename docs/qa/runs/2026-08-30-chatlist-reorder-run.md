# The chat list reorders in one motion — live run

2026-08-30, iPad Pro 11" simulator (fable-ipad), the alfa fixture. Reported by
the owner from an iPhone with two videos of pinning and unpinning
(`2026-08-30-chatlist-reorder/owner-device-before.mp4`): the row flew over its
neighbours and a gap stood open for the length of the spring, and in airplane
mode the same thing, so the server was never part of it.

## What the frames showed

Reproduced on the simulator with `simctl recordVideo` at 30 fps
(`swiftui-list-before.mp4`). Three things stacked up:

1. SwiftUI List animated the move as a removal and an insertion: the row faded
   out mid-flight over the header and neighbours while its destination sat
   open until the spring ran out.
2. Once the container was a UIKit collection list, the batch still landed in
   one frame: SwiftUI runs `updateUIView` twice for one emission, and the
   second `apply` of the same order ended the first one's slide on the spot.
3. A row that had just been under a swipe started its move from a stale frame —
   it vanished and came in from beyond the edge, while the same move from the
   context menu slid cleanly.

## What changed

The list's container is `ChatListCollection`: a `UICollectionView` with a list
layout and a diffable snapshot, the rows still `ChatRowView` through
`UIHostingConfiguration`, swipes and the folder menu as UIKit actions, the
requests header and the archive row as their own sections. An unchanged order
is only reconfigured, never re-applied, so the slide is not interrupted. A pin
from a swipe waits for the swipe to close, reissues the row as a fresh cell
(nothing visible changes) and gives it a moment to settle before the move.
Pin/Unpin is also in the row's context menu now.

## Watched

- Unpin from the swipe (`swipe-unpin-after.mp4`): the swipe closes, then the
  row slides down from its own place while the rows below slide up in the same
  motion; no gap, no jump, no disappearance.
- Unpin from the context menu (`menu-unpin-after.mp4`): the same slide, with
  no wait.
- The rest of the list on the new container: tap opens the chat, requests keep
  their header, archive row present, trailing swipe shows Archive/Mute/Delete,
  the long horizontal swipe still switches the folder tab, the folder empty
  state overlays as before.

MsngrTests: 285 passed.
