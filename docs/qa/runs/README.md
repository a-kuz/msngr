# Run reports

One file per run, `YYYY-MM-DD-topic-run.md`. Text only — screenshots and
recordings are not kept here. They age within a day, they weighed more than a
hundred megabytes, and nothing was ever read from them twice. Take them while
you work, look at them, describe what you saw.

English, like everything else in the repository.

## What a report says

Start with what was run and against what: which devices, which stand, which
build. A report that does not say where it ran cannot be repeated.

Then the result, plainly. What worked, what did not, and what was not covered.
An unverified claim is worth less than an admitted gap, so name the gaps —
"the peer had no device, so nothing here proves the receiving side" is a useful
sentence and a silent omission is not.

Numbers where there are numbers: rates, counts, durations, sizes. "Faster" is
not a result; "19 to 26 messages a second before, 1540 after, same snapshot"
is one. A screenshot cannot carry a number into the future, but a sentence can.

Defects found along the way belong here too, including the ones left unfixed.
If something looked wrong and turned out to be fine, that is worth a line as
well — it stops the next person re-investigating it.

## What it does not need

No preamble about what the task was, no restating of the instructions, no
summary of the summary. The reader has the commit history and the code; the
report is for what neither of those shows — what actually happened when a
person used the thing.
