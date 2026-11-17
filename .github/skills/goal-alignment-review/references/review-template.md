# Checkpoint review template

Fill every section. Fit on one screen. Quote `GOAL.md`; do not paraphrase it.

```markdown
## Goal alignment checkpoint — <date> — <milestone/PR>

**Goal (quoted):** "<one sentence from GOAL.md>"
**Verdict:** Meets | Partial | Drifted | Scope creep

### Success criteria
| # | Criterion (quoted) | Evidence (file:line or output value) | Status |
|---|---|---|---|
| 1 | "..." | `output.json` → `summary.total: 5` | ✅ Met |
| 2 | "..." | — | ❌ Missing |
| 3 | "..." | `summary.md` L4 — states "TBD" where a number was required | ⚠️ Substituted (pattern 5) |

### Acceptance test
**Expected:** <from GOAL.md>
**Actual:** <paste real output, or "not runnable because ...">
**Result:** Pass | Fail | Not run

### Inventory of what was built
| Item | Class | Maps to |
|---|---|---|
| `main.ps1` / `report.docx` | Required | #1, #2 |
| retry helper / glossary | Supporting | #1 |
| `extra-inventory.csv` / appendix C | Unjustified | — (Non-goal) |

### Delete
- `extra-inventory.csv` and its collector (Non-goal)
- validation block nobody asked for (pattern 8)

### Drift patterns observed
- #1 Caution creep — 9 disclaimer lines in the summary
- #11 Blocker inflation — one unknown nulls every conclusion

### Single next action
<one sentence; the change that most moves toward Meets>
```

## Verdict definitions

| Verdict | Meaning | Typical fix |
|---|---|---|
| **Meets** | Every criterion has evidence; acceptance test passes; no `Unjustified` items (or only trivial ones). | Ship. |
| **Partial** | On the right path; some criteria missing or weak; nothing out of scope. | Finish the missing criteria. |
| **Drifted** | Work moved *away* from the goal: criteria are being satisfied by proxies, substituted, or buried. Scope may be right but direction is wrong. | Re-read GOAL.md; rewrite the parts that substitute. Often means simplifying. |
| **Scope creep** | Criteria may be met, but significant `Unjustified` work exists that adds cost, surface, or confusion. | Delete. Do not document. |

`Drifted` and `Scope creep` can co-occur. Report the dominant one as the verdict and name the other under patterns.

## Evidence rules

- A criterion is **Met** only when you can point at a concrete output value, line, or test result. Code existing is not evidence that the output is right.
- A criterion is **Substituted** when the output contains a different, easier thing in its place (pattern 5). This is worse than Missing because it looks done.
- If the acceptance test cannot be run, say why in one line and mark the verdict no higher than `Partial`.
