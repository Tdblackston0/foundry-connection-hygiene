# Foundry Connection Inventory

`Get-FoundryConnectionInventory.ps1` is a single-file, read-only PowerShell 7 script that inventories every connection in a Microsoft Foundry (`AIServices`) account, resolves active references across agents and toolboxes, identifies duplicate connection targets, and projects connection headroom.

No resources are created, modified, or deleted. All requests are `GET` calls against Azure Resource Manager (`2025-06-01`) and the Foundry Agents data plane (`v1`).

---

## Prerequisites

1. **PowerShell 7.0+** (`pwsh`)
   ```powershell
   $PSVersionTable.PSVersion
   ```
2. **`Az.Accounts` module**
   ```powershell
   if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
       Install-Module -Name Az.Accounts -Scope CurrentUser
   }
   ```
3. **Azure RBAC permissions**
   - **Reader** on the Microsoft Foundry account (`https://management.azure.com/`).
   - **Azure AI User** (or equivalent read role for agent and toolbox definitions) on each project in the account (`https://ai.azure.com/`).
4. **Network access**
   - If the Foundry account uses private endpoints, run the script from a workstation, VM, or runner with network routing and private DNS resolution to `*.services.ai.azure.com`.

---

## How to Run

### 1. Sign in to Azure

```powershell
Connect-AzAccount -Tenant "<YOUR-TENANT-ID>"
Set-AzContext -SubscriptionId "<YOUR-SUBSCRIPTION-ID>"
```

### 2. Run a standard inventory

Evaluates latest (non-draft) agent versions, the toolbox versions those agents reference, and each toolbox's default version:

```powershell
./Get-FoundryConnectionInventory.ps1 `
  -SubscriptionId "<YOUR-SUBSCRIPTION-ID>" `
  -ResourceGroup  "<YOUR-RESOURCE-GROUP>" `
  -AccountName    "<YOUR-FOUNDRY-ACCOUNT>"
```

### 3. Examples

**Include historical agent and toolbox versions (`references.stale`):**
```powershell
./Get-FoundryConnectionInventory.ps1 `
  -SubscriptionId "<YOUR-SUBSCRIPTION-ID>" `
  -ResourceGroup  "<YOUR-RESOURCE-GROUP>" `
  -AccountName    "<YOUR-FOUNDRY-ACCOUNT>" `
  -IncludeHistoricalVersions
```

**Specify a custom output folder, connection limit, and verbose progress:**
```powershell
./Get-FoundryConnectionInventory.ps1 `
  -SubscriptionId  "<YOUR-SUBSCRIPTION-ID>" `
  -ResourceGroup   "<YOUR-RESOURCE-GROUP>" `
  -AccountName     "<YOUR-FOUNDRY-ACCOUNT>" `
  -OutputPath      "./my-reports" `
  -ConnectionLimit 120 `
  -Verbose
```

**Dry run (print `GET` endpoints without calling Azure):**
```powershell
./Get-FoundryConnectionInventory.ps1 `
  -SubscriptionId "<YOUR-SUBSCRIPTION-ID>" `
  -ResourceGroup  "<YOUR-RESOURCE-GROUP>" `
  -AccountName    "<YOUR-FOUNDRY-ACCOUNT>" `
  -DryRun
```

---

## Parameters

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| `-SubscriptionId` | Yes | — | Azure subscription ID containing the Foundry account. |
| `-ResourceGroup` | Yes | — | Resource group name containing the Foundry account. |
| `-AccountName` | Yes | — | Microsoft Foundry (`AIServices`) account name. |
| `-OutputPath` | No | `./reports` | Directory where the `run-<utc>` output folder is created. |
| `-ConnectionLimit` | No | `120` | Account connection cap used to calculate headroom projections. |
| `-IncludeHistoricalVersions` | No | `$false` | Also walk non-latest agent versions and unreferenced non-default toolbox versions into `references.stale`. |
| `-DryRun` | No | `$false` | Print the `GET` endpoints that would be called and exit without making network requests. |

---

## Output Contract

Each run creates `$OutputPath/run-<utc>/` containing three files:

1. **`inventory.json`** — `{ run: {...}, headroom: {...}, connections: [...], duplicateGroups: [...], warnings: [...] }`. Machine-readable contract with camelCase keys, ISO-8601 UTC timestamps, and sanitized `target` URIs (credentials, query strings, and fragments stripped).
2. **`connections.csv`** — One row per logical connection with columns:
   `Name, Category, Target, AuthType, IsDefault, Scopes, ActiveRefs, StaleRefs, DuplicateGroup, Disposition, SurvivorCandidate, Reason`
3. **`summary.md`** — Concise human summary (≤ 25 lines): headroom line, disposition counts, `Retire` + `Consolidate` action table, and warnings.

---

## Disposition Rules (Applied in Order, First Match Wins)

1. `Review` — collection failed for **this connection's project(s)** (HTTP error on agents/toolboxes/connections list). Failures in *other* projects do not affect this row.
2. `Retire` — `health = NotConnected` (e.g., OAuth2 consent incomplete/token absent, expired credentials, or empty target). Reason names the referencing tool so the toolbox can be fixed.
3. `Consolidate` — `duplicateGroup` has ≥ 2 logical connections. `survivorCandidate` = the group member with highest `activeCount`; tie → `isDefault = true`; tie → account-scoped; tie → earliest `created`. The survivor itself gets `Keep`.
4. `Keep` — `activeCount ≥ 1`, **or** `isDefault = true` with category in `AppInsights | AzureOpenAI | AzureStorageAccount | CosmosDB` (platform defaults).
5. `Retire` — `activeCount = 0`.

