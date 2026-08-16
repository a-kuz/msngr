# Dynamic Type — live run, 2026-08-16

Text sizing now follows the system setting. Screenshots: `runs/2026-08-16-dynamic-type/`.

Stand: own `wrangler dev` on :8809 with its own `--persist-to`, two own simulators
(`msngr-typescale` as Alisa, `msngr-typescale-b` as Boris), both deleted afterwards.
Sizes are switched with `xcrun simctl ui <udid> content_size <value>` while the app
keeps running — nothing here was checked by restarting.

## What was covered

Three sizes end to end: `extra-small`, `large` (default), and
`accessibility-extra-extra-extra-large` (AX5), plus `accessibility-extra-large`
for the cases where AX5 hides too much of the screen at once.

| Screen | XS | default | AX5 |
| --- | --- | --- | --- |

The composer is in every chat screenshot: field, attach button, mic, placeholder.

## The feed re-measures, and the reader stays put

partly visible at the top of the screen, 56 at the bottom.

`accessibility-extra-large` without leaving the screen. Every bubble is
re-measured onto two lines, and message 38 is still the partly visible one at the
top, in the same place. The anchor survives a change that moves every height in
the list.

## Extremes

  takes its height from the text it holds, so "5 непрочитанных сообщений" stays
  on one line and inside its stripe at both sizes.
  time and the unread badge share one line at every size: the time and the badge
  keep their ideal width, and a long name truncates instead of squeezing them.
  The preview wraps to its second line.
- **Chat header.** Title and subtitle stop growing well before the accessibility
  sizes — the inline navigation bar keeps its height whatever the text does, and
  a name that no longer fits is shortened with an ellipsis as before.
  emoji and stays inline with the text and the time, inside the bubble.
- **Composer.** The field grows with its font (one line at the bottom, six at the
  ceiling), the placeholder tracks it, and the round buttons grow with a cap so
  the bar stays a bar.

## Fixed during the run

The name in settings was truncated at AX5 (`.headline` in a `TextField`, which
cannot wrap). It now uses a capped role and shows in full — compare

## Not chased

Boris's messages reached Alisa only after her app was relaunched, once, after her
simulator had been through a language change and several terminate/launch cycles.
Nothing in this change touches sync or the socket, and the messages did arrive
over the socket when they came. Left unexplained rather than guessed at.
