# Project types — what "evidence" and "drift" look like

The skill's three modes are the same everywhere. What changes is **what counts as evidence** for a criterion and **which drift patterns dominate**. Pick the row that matches, or the closest one.

| Project type | What the acceptance test looks like | Evidence for "Met" | Dominant drift patterns | Typical "Delete" items |
|---|---|---|---|---|
| **Script / CLI / automation** | Fixture input → exact expected output values | A value in an output file; a passing test; exit code | #1 caution creep, #3 scope widening, #8 premature hardening, #9 output multiplication | Extra collectors, extra CSVs, config files for one case, defensive layers |
| **Application / service / API** | A request → response contract; a user flow that completes | Passing integration test; the screen/endpoint doing the thing | #4 generalization, #7 tool-for-tool's-sake, #6 historical completeness | Abstraction layers with one implementation, feature flags nobody toggles, second storage/queue |
| **Infrastructure / IaC (Bicep, Terraform, pipelines)** | `deploy` succeeds and resource X exists with property Y | `what-if`/plan output; resource properties after deploy | #3 scope widening, #8 premature hardening, #4 generalization | Modules for resources not in scope, parameters with one value, policy/alerting not requested |
| **Agent / prompt / MCP tool** | Given input conversation → agent produces output matching rubric | Transcript of the agent run against the fixture; rubric score | #7 tool-for-tool's-sake, #1 caution creep (hedging instructions), #12 momentum | Extra tools the agent never calls, instruction paragraphs that restate caveats, orchestration for one agent |
| **Document / memo / README / runbook** | The named reader can answer the question or perform the task after reading it once | The sentence/section that answers each criterion; a dry run of the runbook | #2 defensible-over-useful, #9 output multiplication (appendices), #5 proxy substitution (background instead of answer) | Background sections, appendices, "considerations" lists with no recommendation |
| **Slide deck / executive briefing** | Audience leaves knowing X and deciding Y | The slide that states X; the slide that asks for Y | #2 defensible-over-useful, #3 scope widening (adjacent products), #9 (slide count) | Backup slides promoted to main deck, product overviews, slides without a takeaway title |
| **Architecture / design** | The design answers the stated constraints and the named decision is made | Decision record; constraint → component mapping | #4 generalization, #7 tool-for-tool's-sake, #6 (every option documented) | Options nobody is choosing, future-state diagrams not requested, "phase 3" |
| **Analysis / report / recommendation** | The decision-maker can act on a single recommendation with its basis | The recommendation sentence; the numbers behind it | #5 proxy substitution, #1 caution creep, #2 | Methodology sections longer than findings, alternative scenarios not asked for |
| **Learning / enablement content (lab, workshop, hackathon)** | A participant with the stated starting skill completes the exercise in the stated time | A dry run by someone at that level; timing | #3 scope widening (one more module), #4 (platform for all workshops) | Optional modules, prerequisites beyond the stated audience, reusable framework scaffolding |

## Cross-type rules

- **Outcome, not output.** The goal sentence names what the *user of the result* can now do, not the artifact. A deck is not a goal; a decision is.
- **One primary artifact.** Every type above has one thing the reader/runner uses. Everything else is `Supporting` or `Unjustified`.
- **Evidence is external to the work.** Code existing, a slide existing, a paragraph existing — none are evidence. The value, the test result, the reader's ability to act are.
- **Non-goals are where drift enters.** For every type, the most common drift is pulling in the adjacent thing. Write the non-goals even when they feel obvious.
- **Corrections reset the goal check.** When the user says "simpler", "shorter", "that's not what I meant", or "just…", re-run Capture or add an Amendment before touching the work (pattern #12).
