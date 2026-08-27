# The unread banner's dismissal, frame by frame

Run on 2026-08-27 on the `solo-live` simulator (`iPhone 17`, iOS 26.5),
recorded with `simctl io recordVideo` (variable frame rate, ~62 frames around
the event) while alfa sent a message with the banner reading «900
непрочитанных сообщений» and the feed standing at the banner.

## Seen

The send dismisses the banner and jumps the feed to the bottom in the same
beat. Across the recording the banner band changes in exactly one frame step:
the frames before it show the banner over the history, the next frame shows
the feed at the bottom without it. There is no separate disappearance
animation, and under the jump to the bottom none would be visible — the
banner stands mid-history, far from where the feed lands.

The other dismissal paths (background, the shade) remove the banner while the
screen is not visible at all, so the send path is the only one where an
animation could ever be seen.
