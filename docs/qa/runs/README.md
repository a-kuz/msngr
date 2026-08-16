# Run reports

One file per run, named `YYYY-MM-DD-topic.md`. Screenshots and recordings for
that run go in a directory of the same name without the extension:

    2026-08-15-20k-chat-run.md
    2026-08-15-20k-chat/01-feed.png
    2026-08-15-20k-chat/02-marker.png

English, like everything else in the repository. Numbered file names keep the
pictures in the order they were taken.

## What a report says

Start with what was run and against what: which devices, which stand, which
build. A report that does not say where it ran cannot be repeated.

Then the result, plainly. What worked, what did not, and what was not covered.
An unverified claim is worth less than an admitted gap, so name the gaps —
"the peer had no device, so nothing here proves the receiving side" is a useful
sentence and a silent omission is not.

Numbers where there are numbers: rates, counts, durations, sizes. "Faster" is
not a result; "19 to 26 messages a second before, 1540 after, same snapshot"
is one.

Defects found along the way belong here too, including the ones left unfixed.
If something looked wrong and turned out to be fine, that is worth a line as
well — it stops the next person re-investigating it.

## What it does not need

No preamble about what the task was, no restating of the instructions, no
summary of the summary. The reader has the commit history and the code; the
report is for what neither of those shows — what actually happened when a
person used the thing.
