---
name: goal-alignment-review
description: keep agent work anchored to the user's original request. use at the start of any build/refactor task to capture the goal in GOAL.md, as a gate before adding any new file, feature, abstraction, output, or safeguard, and as a checkpoint after each milestone or before a PR to grade what was produced against the original goal and name what to delete. trigger on phrases like "are we still on track", "review this against the original request", "did we drift", "does this answer the question", "goal check", "scope check", or whenever the agent is about to widen scope, add caveats, or build something the user did not ask for.
---

# Goal Alignment Review

Agents drift. Over a long task they optimize for what is *defensible*, *complete*, or *interesting* instead of what was *asked*. This skill makes the original request a durable artifact and forces every addition to justify itself against it.

This skill is domain-agnostic. It applies to code, scripts, infrastructure, documents, decks, architecture, agent prompts, and customer deliverables. See [references/project-types.md](references/project-types.md) for how "evidence" and "drift" look in each. A worked example lives in [references/example-goal.md](references/example-goal.md).

## The contract: `GOAL.md`

`GOAL.md` at repo root is the single source of truth. It is **immutable** once written; only the user can amend it, and amendments are appended as a dated `## Amendment` with the reason — never edited in place. Use [references/goal-template.md](references/goal-template.md).

If `GOAL.md` is missing when this skill is invoked, **stop and write it first** from the user's request. Do not infer scope the user did not state. Ask one round of questions only if the success criteria are genuinely unknowable; otherwise write your best reading and mark unknowns with `[ASSUMED]`.

## Three modes

### Mode 1 — Capture (start of task)

1. Read the user's request verbatim. Copy it into `GOAL.md` under `## Original request` unchanged.
2. Extract: **goal** (one sentence, outcome not output), **who it's for**, **success criteria** (observable, countable), **non-goals** (things adjacent that are explicitly out), **acceptance test** (concrete input → expected output), **"done looks like"** (what the user will actually do with the result).
3. Write `GOAL.md`. Confirm with the user in ≤ 5 lines. Proceed only after that.

### Mode 2 — Gate (before every addition)

Before creating a new file, function, output artifact, config, dependency, safeguard, disclaimer, or abstraction, answer in one line in your reasoning:

> `GATE: <thing> → serves <success criterion #N | acceptance test | explicitly requested in turn X>`

If you cannot complete that sentence from `GOAL.md`, **do not build it**. Say instead: *"This would add X. It is not in GOAL.md. Add it as an amendment, or skip?"* Then wait.

Gate heuristics — any of these is a red flag; see [references/drift-patterns.md](references/drift-patterns.md) for the full catalogue:

- The addition makes the output *safer to publish* but not *more useful to act on*.
- You are adding a second source/system/API the user never mentioned.
- You are generalizing from the user's one case to "all cases."
- A disposition, status, or verdict field now has more than four values.
- You are writing a caveat that explains why the result cannot be trusted.
- The "simple" version would already pass the acceptance test.

### Mode 3 — Checkpoint (milestone, pre-PR, or on request)

Produce the report in [references/review-template.md](references/review-template.md). Rules:

1. **Re-read `GOAL.md` first, then the output. Never the reverse.** Reading the output first anchors you to defending it.
2. For each success criterion, cite the **specific file/line/output value** that satisfies it. "The code handles this" is not evidence; a value in an output file is.
3. **Run the acceptance test** if it is executable. Paste the actual result next to the expected result.
4. Classify every file, function, and output artifact: `Required` (maps to a criterion), `Supporting` (needed to make a Required thing work), `Unjustified` (maps to nothing). List every `Unjustified` item under **Delete**.
5. Verdict vocabulary — exactly one: `Meets`, `Partial`, `Drifted`, `Scope creep`. Definitions are in the template. `Drifted` and `Scope creep` are different failures with different fixes.
6. End with the **single next action** that most moves toward `Meets`. Not a list.

Optionally run `scripts/drift_check.py` for a mechanical first pass (artifact counts, vocabulary vs. GOAL.md, caveat density). It works on any text-based repo and is a heuristic, not a verdict.

## Hard rules

- Never edit `GOAL.md` to match what was built. The build moves; the goal does not.
- Never soften a verdict because the work was effortful or well-engineered. Quality of execution is not alignment.
- When asked "does this answer the question," answer **yes / no / partly** in the first sentence, then evidence. No preamble.
- Prefer deleting over documenting. If a thing is `Unjustified`, the fix is removal, not a README section explaining it.
- Keep this skill's own output short. A checkpoint report should fit on one screen.
