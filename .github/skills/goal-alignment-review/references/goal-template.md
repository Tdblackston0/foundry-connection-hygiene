# GOAL.md template

Copy to repo root as `GOAL.md`. Fill every section. Mark anything the user did not state with `[ASSUMED]`. Keep the whole file under 60 lines — if it is longer, the goal is not clear yet.

```markdown
# GOAL

**Status:** Locked <YYYY-MM-DD>   <!-- only the user changes this -->

## Original request
<!-- verbatim, unedited, including typos -->

## Goal (one sentence, outcome not output)
<!-- Good: "The platform team can see which items to retire to get under the limit" -->
<!-- Bad:  "A script that inventories items" (that is an output, not an outcome) -->

## Who uses the result, and what do they do with it?
<!-- "The ops team runs it weekly and acts on the resulting list." -->

## Success criteria (observable, countable)
1.
2.
3.
<!-- Each must be checkable by looking at an output, not at code. -->
<!-- Good: "Output states the projected count after cleanup." -->
<!-- Bad:  "Output is accurate and trustworthy." -->

## Non-goals (adjacent things that are explicitly OUT)
-
-
<!-- Write these down even if they seem obvious. This is where drift enters. -->

## Acceptance test
**Input:** <concrete fixture / account / sample>
**Expected output:**
-
-
<!-- Specific values. If the agent cannot run this, the test is not concrete enough. -->

## "Done" looks like
<!-- One or two sentences describing the moment the user considers this finished. -->
<!-- "I run one command, read one number, and hand the list to the customer." -->

## Amendments
<!-- Append only. Never edit sections above. -->
<!-- ### <YYYY-MM-DD> — <what changed> — <why, in the user's words> -->
```

## Worked example

See [example-goal.md](example-goal.md).
