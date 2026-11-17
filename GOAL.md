# GOAL

**Status:** Locked 2026-11-16

## Original request
Problem: Customer is reaching the 120 connections limit in Foundry. Build `Get-FoundryConnectionInventory.ps1` — a single-file, read-only PowerShell 7 script (≤ 250 lines) that inventories every connection in a Microsoft Foundry account, determines which are actively referenced, flags true duplicates, and emits a mechanical disposition and headroom projection (`inventory.json`, `connections.csv`, and `summary.md`) that a downstream agent will reason over.

## Goal
The customer's platform team can see which Foundry connections to retire or consolidate to get and stay under the account connection limit.

## Who uses the result, and what do they do with it?
Customer Foundry platform admins run one read-only PowerShell 7 command (`Az.Accounts` only), read the headroom projection, and act on the `Retire` / `Consolidate` list; a downstream Foundry agent consumes `inventory.json` to produce the remediation plan.

## Success criteria
1. One row per logical connection (account and project projections deduplicated by `name` + `created` to the second), with disposition `Keep | Consolidate | Retire | Review`.
2. Output states `limit`, `current`, `currentRaw`, `afterRetire`, `afterRetireAndConsolidate`, `percentOfLimit`, and `warnAt80Percent`.
3. Every `Consolidate` row names a `survivorCandidate` chosen by highest `activeCount`, then `isDefault`, then account scope, then earliest `created`.
4. Active references include only latest (non-draft) agent direct tools, latest agent → referenced toolbox version tools, and default toolbox version tools (`stale` populated only with `-IncludeHistoricalVersions`).
5. A collection failure in one project marks only that project's rows `Review`, never blocking the entire account report.
6. Single-file script (`Get-FoundryConnectionInventory.ps1`, ≤ 250 lines, `Az.Accounts` only, `-DryRun` supported) writing only `inventory.json`, `connections.csv`, and `summary.md` (≤ 25 lines).

## Non-goals
- Azure AI Search index, indexer, knowledge source, or alias inventory and ownership mapping.
- Proving non-usage outside Foundry agent and toolbox definitions.
- Custom config files (`customer.local.json`), SSRF allow-lists, DNS pre-checks, or CSV-injection prefixes.
- Deleting or modifying any Azure resource (`PUT` / `PATCH` / `DELETE`).

## Acceptance test
**Input:** fixture `run-20261116T175822499Z-7b2b10ba`
**Expected output:**
- `connections.length == 5` (`currentRaw == 10`); every connection has `scopes` containing both `account` and `project:manufacturing-operations-agent`.
- Exactly one `duplicateGroup`: `remotetool|https://mcp.ai.azure.com` with members `FoundryMCPServerpreview`, `FoundryMCPServerpreview2`.
- `FoundryMCPServerpreview2` → `Keep` (active via `agent/manufacturing-operations@11 -> toolbox/finance-approvals@5`).
- `MicrosoftLearn` → `Keep` (active via `agent/manufacturing-operations@11 -> toolbox/finance-approvals@5`).
- `FoundryMCPServerpreview` → `Consolidate`, `survivorCandidate = FoundryMCPServerpreview2` (active only via `toolbox/finance-approvals@1` default).
- `WorkIQ` → `Keep` (referenced by `toolbox/finance-approvals@1` default); `references.stale` empty unless `-IncludeHistoricalVersions`.
- `manufacturingoperatiof3hgu6` (`AppInsights`) → `Keep` via platform-default rule.
- `headroom.current == 5`, `afterRetireAndConsolidate == 4`.
- `warnings` has 1 entry about toolbox skills/opaque tools and zero `BlocksAnalysis` fields; script exits 0 with no write HTTP verbs.

## "Done" looks like
I run one command against the customer's Foundry account and can tell them in one sentence how many connections they can drop, backed by `inventory.json` and `summary.md`.

## Amendments

### 2026-11-16 — Connection health + latest-version semantics
A connection that is referenced but not established is a Retire candidate. Toolbox *default* version does not count as active; the agent-pinned version and the toolbox *latest* version do. Expected fixture result: WorkIQ → Retire (NotConnected); FoundryMCPServerpreview → Consolidate (stale-only reference, survivor FoundryMCPServerpreview2); headroom 5 → 3 after Retire+Consolidate.

