# Worked example — GOAL.md for a resource-hygiene tool

A real case where a simple request drifted into a large, unusable evidence package. Use it to calibrate how concrete the criteria and acceptance test need to be.


```markdown
# GOAL

**Status:** Locked 2026-11-16

## Original request
Problem: Customer is reaching the 120 connections limit in foundry. [...] I need something simple and easy for the customer to deploy [...]

## Goal
The customer's platform team can see which Foundry connections to retire or consolidate to get and stay under the account connection limit.

## Who uses the result, and what do they do with it?
Customer Foundry platform admins. They run it, read the headroom number, and act on the Retire/Consolidate list. Later, a Foundry agent reads the JSON and writes the customer-facing plan.

## Success criteria
1. One row per logical connection (account projections deduped), with Keep / Consolidate / Retire / Review.
2. Output states current count, count after Retire, count after Retire+Consolidate, against the limit.
3. Every Consolidate row names a survivor.
4. One partially-failed project degrades only that project's rows, never the whole report.
5. Deployable by the customer with one script and Az.Accounts only.

## Non-goals
- Azure AI Search index / indexer / alias hygiene.
- Proving non-usage beyond Foundry agent and toolbox definitions.
- Deleting or modifying any resource.
- Defending the output against audit; it is a planning input, not evidence.

## Acceptance test
**Input:** account `<YOUR-FOUNDRY-ACCOUNT>`, fixture run-20261116T175822499Z
**Expected output:** 5 connections (not 10); 1 duplicate group (`remotetool|https://mcp.ai.azure.com`); `FoundryMCPServerpreview` → Consolidate, survivor `FoundryMCPServerpreview2`; headroom 5 → 4; exactly one warning.

## "Done" looks like
I run one command against the customer's account and can tell them in one sentence how many connections they can drop.
```
