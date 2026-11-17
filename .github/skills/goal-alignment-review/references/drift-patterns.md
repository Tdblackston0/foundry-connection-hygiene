# Drift patterns

Named failure modes. Each one feels like good engineering in the moment. Use the **Tell** to detect it in the gate, and the **Fix** in the checkpoint.

| # | Pattern | What it looks like | Tell | Fix |
|---|---|---|---|---|
| 1 | **Caution creep** | Output accumulates disclaimers, "Unknown"/"Investigate" states, "not verified" placeholders. Result becomes safe to publish and impossible to act on. | A status field grows past 4 values; summary has an "interpret carefully" section; the key number is replaced by text. | Collapse statuses to ≤ 4. Put caveats in one `warnings[]` list. The headline number is always computed. |
| 2 | **Defensible-over-useful** | Agent optimizes for "nobody can say this is wrong" instead of "the user can act on this." | Phrases like "evidence package", "audit trail", "review hint, not instruction" when the goal was a decision. | Re-read *"Done looks like"*. If the user wanted a decision, output a decision. |
| 3 | **Scope widening** | Adjacent systems get pulled in because the data was *there*. (A neighbouring service's inventory inside a tool scoped to one resource type; a competitor section in a one-product deck.) | A second API/service/SDK appears that `GOAL.md` never names. | Check Non-goals. Delete the collector and its outputs. |
| 4 | **Generalization** | One customer's case becomes a framework for all cases. Config files, plugin points, abstraction layers. | Config files for a single customer, strategy patterns, mode switches with one real mode, "framework" in the folder name. | Build for the acceptance test. Generalize when a second real case exists. |
| 5 | **Proxy-metric substitution** | The real goal is hard to measure, so the agent measures something easier and reports that instead. | Goal names an outcome number or decision; output reports counts of intermediate things instead. | Compute the goal metric even if imperfect; label assumptions; do not replace it. |
| 6 | **Historical completeness** | Agent includes every version/variant/history because omitting feels lossy. | Walking all versions, all drafts, all branches by default. | Default to *current*. Make history opt-in. |
| 7 | **Tool-for-tool's-sake** | A technology is added because it is available or novel, not because a criterion needs it. | "We could also use X here"; MCP/agent/LLM added to a deterministic step. | Gate it: which criterion requires it? |
| 8 | **Premature hardening** | Retries, allow-lists, sanitizing, and validation layers that exceed the domain logic; a three-page risk appendix in a two-page memo. | Security/robustness code exceeds domain code. | Keep what a failure would actually cause. Delete the rest. |
| 9 | **Output multiplication** | One question, eight files. | Artifacts > success criteria. | One machine-readable file, one human file. |
| 10 | **Goal rewriting** | The agent quietly reinterprets the goal to match what it built, or edits `GOAL.md`. | Checkpoint report paraphrases the goal instead of quoting it. | `GOAL.md` is immutable. Quote it. |
| 11 | **Blocker inflation** | One unknown anywhere blocks every conclusion everywhere. | A global `BlocksAnalysis`-style flag; one 403 nulls the whole report. | Scope failures to the smallest unit (row, project). Degrade, don't abort. |
| 12 | **Momentum** | Agent continues the last plan after the user's correction changed the goal. | User said "simpler"; next diff is larger. | On any correction, re-run Capture or add an Amendment before writing code. |

## Quick gate questions

Ask these in order; stop at the first "no":

1. Which success criterion number does this serve? (If none → do not build.)
2. Would the acceptance test fail without it? (If no → it is `Supporting` at best; keep it minimal.)
3. Does it make the result more *actionable* or only more *defensible*? (Defensible-only → pattern 1/2.)
4. Does it introduce a system, concept, or artifact not named in `GOAL.md`? (Yes → pattern 3/7/9; ask the user.)
