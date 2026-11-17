#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $AccountName,
    [string] $OutputPath = './reports',
    [int]    $ConnectionLimit = 120,
    [switch] $IncludeHistoricalVersions,
    [switch] $DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ArmApiVersion = '2025-06-01'
$script:AgentsApiVersion = 'v1'
$script:PlatformDefaultCategories = @('AppInsights', 'AzureOpenAI', 'AzureStorageAccount', 'CosmosDB')

function Format-TargetUri ([AllowNull()][string]$Target) {
    $uri = $null
    if ($Target -and [uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) {
        $b = [UriBuilder]::new($uri); $b.UserName = ''; $b.Password = ''; $b.Query = ''; $b.Fragment = ''
        return $b.Uri.GetLeftPart([UriPartial]::Path).TrimEnd('/')
    }
    return ''
}

function ConvertTo-HygieneConnection ([Parameter(Mandatory)]$Connection) {
    $id = [string]$Connection.id
    if ($id -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.CognitiveServices/accounts/[^/]+(?:/projects/([^/]+))?/connections/([^/]+)$') { throw "Unsupported connection resource ID: $id" }
    $project = if ($Matches[1]) { [string]$Matches[1] } else { '' }; $name = if ($Connection.PSObject.Properties['name'] -and $Connection.name) { ([string]$Connection.name -split '/')[-1] } else { [string]$Matches[2] }
    $props = if ($Connection.PSObject.Properties['properties'] -and $Connection.properties) { $Connection.properties } else { [pscustomobject]@{} }
    $sys = if ($Connection.PSObject.Properties['systemData'] -and $Connection.systemData) { $Connection.systemData } else { [pscustomobject]@{} }
    $rawCreated = if ($props.PSObject.Properties['createdDate'] -and $props.createdDate) { $props.createdDate } elseif ($sys.PSObject.Properties['createdAt'] -and $sys.createdAt) { $sys.createdAt } else { $null }
    $rawTarget = if ($props.PSObject.Properties['target'] -and $props.target) { [string]$props.target } else { '' }; $cat = if ($props.PSObject.Properties['category'] -and $props.category) { [string]$props.category } else { '' }
    $auth = if ($props.PSObject.Properties['authType'] -and $props.authType) { [string]$props.authType } else { '' }; $isDef = [bool]($props.PSObject.Properties['isDefault'] -and $props.isDefault -eq $true)
    $err = if ($props.PSObject.Properties['error'] -and $props.error) { [string]$props.error } else { '' }; $creds = if ($props.PSObject.Properties['credentials']) { $props.credentials } else { $null }
    $exp = if ($props.PSObject.Properties['expiryTime'] -and $props.expiryTime) { [datetimeoffset]$props.expiryTime } else { $null }
    $health = 'Connected'; $hReason = "$auth established"
    if ($err) { $health = 'NotConnected'; $hReason = "Connection error: $err" }
    elseif ($auth -eq 'OAuth2' -and -not $creds -and (-not $exp -or $exp -le [datetimeoffset]::UtcNow)) { $health = 'NotConnected'; $hReason = 'OAuth2 consent incomplete' }
    elseif ($exp -and $exp -le [datetimeoffset]::UtcNow) { $health = 'NotConnected'; $hReason = 'Credentials expired' }
    elseif (-not $rawTarget -and -not ($isDef -and $cat -in $script:PlatformDefaultCategories)) { $health = 'NotConnected'; $hReason = 'Target is empty' }
    elseif ($auth -notin @('ApiKey', 'AAD', 'None', 'SAS', 'ManagedIdentity', 'UserEntraToken', 'ProjectManagedIdentity', 'AccountManagedIdentity', 'OAuth2', 'PAT', 'CustomKeys')) { $health = 'Unverified'; $hReason = "Health state not exposed for authType '$auth'" }
    return [pscustomobject]@{
        Id = $id; Scope = if ($project) { "project:$project" } else { 'account' }; Project = $project; Name = $name; Category = $cat; Target = (Format-TargetUri $rawTarget); AuthType = $auth; IsDefault = $isDef
        Created = if ($rawCreated) { ([datetimeoffset]$rawCreated).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }; Health = $health; HealthReason = $hReason
    }
}

function Merge-LogicalConnections ([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RawConnections) {
    $byKey = @{}; $list = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $RawConnections) {
        $key = "$($r.Name.ToLowerInvariant())|$($r.Created)"
        $h = if ($r.PSObject.Properties['Health'] -and $r.Health) { [string]$r.Health } elseif ($r.AuthType -eq 'OAuth2') { 'NotConnected' } elseif (-not $r.Target -and -not ($r.IsDefault -and $r.Category -in $script:PlatformDefaultCategories)) { 'NotConnected' } else { 'Connected' }
        $hr = if ($r.PSObject.Properties['HealthReason'] -and $r.HealthReason) { [string]$r.HealthReason } elseif ($h -eq 'NotConnected' -and $r.AuthType -eq 'OAuth2') { 'OAuth2 consent incomplete' } elseif ($h -eq 'NotConnected') { 'Target is empty' } else { "$($r.AuthType) established" }
        if (-not $byKey.ContainsKey($key)) {
            $obj = [pscustomobject]@{ name = $r.Name; category = $r.Category; target = $r.Target; authType = $r.AuthType; isDefault = [bool]$r.IsDefault; created = $r.Created; health = $h; healthReason = $hr; scopes = [System.Collections.Generic.List[string]]::new(); ids = [ordered]@{}; references = [pscustomobject]@{ active = @(); stale = @(); activeCount = 0; staleCount = 0 }; duplicateGroup = $null; disposition = 'Keep'; reason = ''; survivorCandidate = $null }
            $byKey[$key] = $obj; $list.Add($obj)
        }
        $entry = $byKey[$key]; if ($r.IsDefault) { $entry.isDefault = $true }; if ($r.Scope -notin $entry.scopes) { $entry.scopes.Add($r.Scope) }; $entry.ids[$r.Scope] = $r.Id
    }
    foreach ($entry in $list) { $entry.scopes = @($entry.scopes) }
    return $list.ToArray()
}

function Find-ConnectionReferences ($Node, [int]$Depth = 0) {
    $found = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Node -or $Depth -gt 50 -or $Node -is [string] -or $Node -is [ValueType]) { return $found.ToArray() }
    if ($Node -is [System.Collections.IList]) { foreach ($item in $Node) { foreach ($r in @(Find-ConnectionReferences $item ($Depth + 1))) { $found.Add($r) } }; return $found.ToArray() }
    $keys = if ($Node -is [System.Collections.IDictionary]) { @($Node.Keys) } else { @($Node.PSObject.Properties.Name) }
    foreach ($k in $keys) {
        $val = if ($Node -is [System.Collections.IDictionary]) { $Node[$k] } else { $Node.$k }
        if ($k -in @('project_connection_id', 'connection_id', 'connection_name', 'connectionId', 'connectionName')) { if ($val) { $found.Add([string]$val) } }
        elseif ($k -notmatch '(?i)^(instructions|prompt|description|metadata|credential|secret|password|token|api.?key|headers|environment)$') { foreach ($r in @(Find-ConnectionReferences $val ($Depth + 1))) { $found.Add($r) } }
    }
    return $found.ToArray()
}

function Resolve-LogicalConnection ([string]$Reference, [string]$Project, [object[]]$Connections) {
    if ($Reference.StartsWith('/')) { return @($Connections | Where-Object { @($_.ids.GetEnumerator() | ForEach-Object { $_.Value }) -icontains $Reference } | Select-Object -First 1) }
    return @($Connections | Where-Object { $_.name -ieq $Reference -and ($_.scopes -icontains "project:$Project" -or $_.scopes -icontains 'account') } | Select-Object -First 1)
}

function Resolve-ConnectionReferences ([object[]]$Connections, [object[]]$ProjectsData, [switch]$IncludeHistoricalVersions) {
    $warnings = [System.Collections.Generic.List[string]]::new(); $warnings.Add('Toolbox skills and opaque tools are not inspected for connection references.')
    $toolboxesOut = [System.Collections.Generic.List[object]]::new(); $activeMap = @{}; $staleMap = @{}
    foreach ($c in $Connections) { $activeMap[$c.name] = [System.Collections.Generic.List[object]]::new(); $staleMap[$c.name] = [System.Collections.Generic.List[object]]::new() }
    $addToolRefs = {
        param($Tool, [string]$Proj, [string]$Path, [bool]$IsActive)
        if ($null -eq $Tool) { return }
        $tType = if ($Tool.PSObject.Properties['type']) { [string]$Tool.type } else { '' }; $tName = if ($Tool.PSObject.Properties['name'] -and $Tool.name) { [string]$Tool.name } else { $tType }
        foreach ($r in @(Find-ConnectionReferences $Tool)) {
            $match = @(Resolve-LogicalConnection -Reference $r -Project $Proj -Connections $Connections)
            if ($match.Count -eq 1) {
                $map = if ($IsActive) { $activeMap } else { $staleMap }; $bucket = $map[$match[0].name]
                if (-not @($bucket | Where-Object { $_.project -eq $Proj -and $_.path -eq $Path -and $_.toolName -eq $tName }).Count) { $bucket.Add([pscustomobject]@{ project = $Proj; path = $Path; toolType = $tType; toolName = $tName }) }
            }
        }
    }
    foreach ($pd in $ProjectsData) {
        $proj = [string]$pd.Project; $tbLookup = @{}; $tbDefault = @{}; $tbLatest = @{}; $activeTbUsed = @{}; $anyTbUsed = @{}
        foreach ($tb in @($pd.Toolboxes)) {
            $defVer = [string]$tb.default_version; $tbDefault[$tb.name] = $defVer
            $sortedVers = @(@($tb.versions) | Sort-Object @{ e = { $n = 0; if ([int]::TryParse([string]$_.version, [ref]$n)) { $n } else { -1 } }; d = $true }, @{ e = { [string]$_.version }; d = $true })
            $latVer = if ($sortedVers.Count -gt 0) { [string]$sortedVers[0].version } else { $defVer }; $tbLatest[$tb.name] = $latVer
            $toolboxesOut.Add([pscustomobject]@{ project = $proj; name = [string]$tb.name; defaultVersion = $defVer; latestVersion = $latVer })
            if ($defVer -and $latVer -and $defVer -ne $latVer) { $warnings.Add("Toolbox $($tb.name) default is v$defVer but latest is v$latVer; update the default or retire v$defVer.") }
            foreach ($tbv in @($tb.versions)) { $tbLookup["$($tb.name)|$($tbv.version)"] = $tbv }
        }
        foreach ($ag in @($pd.Agents)) {
            $vList = @($ag.versionList)
            $nonPrompt = @($vList | Where-Object { $_.PSObject.Properties['definition'] -and $_.definition -and $_.definition.PSObject.Properties['kind'] -and $_.definition.kind -ne 'prompt' })
            if (($ag.PSObject.Properties['kind'] -and $ag.kind -ne 'prompt') -or $nonPrompt.Count -gt 0) { $warnings.Add("Skipped agent '$($ag.name)' in project '$proj': kind is not 'prompt'."); continue }
            $latestVer = if ($ag.PSObject.Properties['versions'] -and $ag.versions -and $ag.versions.PSObject.Properties['latest'] -and $ag.versions.latest) { [string]$ag.versions.latest.version } else { [string](@($vList | Where-Object { -not ($_.PSObject.Properties['draft'] -and $_.draft) } | Select-Object -First 1).version) }
            foreach ($av in $vList) {
                $isLatest = (-not ($av.PSObject.Properties['draft'] -and $av.draft -eq $true)) -and ([string]$av.version -eq $latestVer)
                if (-not $isLatest -and -not $IncludeHistoricalVersions) { continue }
                $tools = if ($av.PSObject.Properties['definition'] -and $av.definition -and $av.definition.PSObject.Properties['tools']) { @($av.definition.tools) } else { @() }
                foreach ($tool in $tools) {
                    if ($null -eq $tool) { continue }
                    $tType = if ($tool.PSObject.Properties['type']) { [string]$tool.type } else { '' }; $srvUrl = if ($tool.PSObject.Properties['server_url']) { [string]$tool.server_url } else { '' }
                    if ($tType -eq 'mcp' -and $srvUrl -match '/api/projects/([^/?#]+)/toolboxes/([^/?#]+)(?:/versions/([^/?#]+))?/mcp/?(?:[?#]|$)') {
                        $tbName = [uri]::UnescapeDataString($Matches[2]); $tbVer = if ($Matches[3]) { [uri]::UnescapeDataString($Matches[3]) } else { $tbLatest[$tbName] }
                        $anyTbUsed["$tbName|$tbVer"] = $true; if ($isLatest) { $activeTbUsed["$tbName|$tbVer"] = $true }
                        if ($tbLookup.ContainsKey("$tbName|$tbVer")) { foreach ($tbTool in @($tbLookup["$tbName|$tbVer"].tools)) { & $addToolRefs $tbTool $proj "agent/$($ag.name)@$($av.version) -> toolbox/$tbName@$tbVer" $isLatest } }
                    } else { & $addToolRefs $tool $proj "agent/$($ag.name)@$($av.version)" $isLatest }
                }
            }
        }
        foreach ($tb in @($pd.Toolboxes)) {
            $defVer = $tbDefault[$tb.name]; $latVer = $tbLatest[$tb.name]
            foreach ($tbv in @($tb.versions)) {
                $verStr = [string]$tbv.version
                if ($verStr -eq $latVer -and -not $activeTbUsed.ContainsKey("$($tb.name)|$verStr")) { foreach ($tbTool in @($tbv.tools)) { & $addToolRefs $tbTool $proj "toolbox/$($tb.name)@$verStr" $true } }
                elseif (($verStr -eq $defVer -and $defVer -ne $latVer) -or ($IncludeHistoricalVersions -and $verStr -ne $latVer -and -not $anyTbUsed.ContainsKey("$($tb.name)|$verStr"))) { foreach ($tbTool in @($tbv.tools)) { & $addToolRefs $tbTool $proj "toolbox/$($tb.name)@$verStr" $false } }
            }
        }
    }
    $unv = @($Connections | Where-Object { $_.health -eq 'Unverified' } | ForEach-Object { $_.name }); if ($unv.Count -gt 0) { $warnings.Add("Connection health is Unverified for: $($unv -join ', ').") }
    foreach ($c in $Connections) { $act = @($activeMap[$c.name]); $stl = @($staleMap[$c.name]); $c.references = [pscustomobject]@{ active = $act; stale = $stl; activeCount = $act.Count; staleCount = $stl.Count } }
    return [pscustomobject]@{ Connections = $Connections; Toolboxes = $toolboxesOut.ToArray(); Warnings = @($warnings) }
}

function Set-ConnectionDispositions ([object[]]$Connections, [string[]]$FailedProjects = @(), [int]$ConnectionLimit = 120, [int]$RawCount = 0) {
    $dupGroups = [System.Collections.Generic.List[object]]::new(); $survivors = @{}
    $grouped = @($Connections | Where-Object { $_.category -and $_.target -and $_.health -ne 'NotConnected' } | Group-Object -Property { "$($_.category.ToLowerInvariant())|$($_.target)" } | Where-Object { $_.Count -ge 2 })
    foreach ($g in $grouped) {
        $members = @($g.Group); $ordered = @($members | Sort-Object @{ e = { $_.references.activeCount }; d = $true }, @{ e = { [int]$_.isDefault }; d = $true }, @{ e = { [int]($_.scopes -icontains 'account') }; d = $true }, @{ e = { $_.created }; a = $true })
        $survivor = $ordered[0]; $survivors[$g.Name] = $survivor.name; foreach ($m in $members) { $m.duplicateGroup = $g.Name }
        $dupGroups.Add([pscustomobject]@{ group = $g.Name; members = @($members.name); survivorCandidate = $survivor.name })
    }
    foreach ($c in $Connections) {
        $cProjects = @($c.scopes | Where-Object { $_ -like 'project:*' } | ForEach-Object { $_.Substring(8) })
        $failedHere = @(if ($cProjects.Count -gt 0) { $cProjects | Where-Object { $_ -in $FailedProjects } } elseif ($c.scopes -icontains 'account') { $FailedProjects })
        $c.survivorCandidate = $null
        if ($failedHere.Count -gt 0) { $c.disposition = 'Review'; $c.reason = "Collection failed for project(s): $($failedHere -join ', ')." }
        elseif ($c.health -eq 'NotConnected') {
            $c.disposition = 'Retire'; $allRefs = @($c.references.active) + @($c.references.stale)
            $refDesc = if ($allRefs.Count -gt 0) { "referenced by " + (($allRefs | ForEach-Object { "$($_.path) tool $($_.toolType)" }) -join ', ') } else { 'no references' }
            $c.reason = "Not established ($($c.healthReason)); $refDesc."
        } elseif ($c.duplicateGroup -and $survivors[$c.duplicateGroup] -ne $c.name) {
            $c.disposition = 'Consolidate'; $c.survivorCandidate = $survivors[$c.duplicateGroup]
            $via = if ($c.references.activeCount -gt 0) { "active only via $($c.references.active.path -join ', ')" } elseif ($c.references.staleCount -gt 0) { "stale-only via $($c.references.stale.path -join ', ')" } else { '0 active references' }
            $c.reason = "Duplicate target $($c.target) ($via); consolidate into $($c.survivorCandidate)."
        } elseif ($c.duplicateGroup -and $survivors[$c.duplicateGroup] -eq $c.name) {
            $c.disposition = 'Keep'; $via = if ($c.references.activeCount -gt 0) { "Active via $($c.references.active.path -join ', ')" } else { 'Selected survivor' }; $c.reason = "$via for duplicate group $($c.duplicateGroup)."
        } elseif ($c.references.activeCount -ge 1) { $c.disposition = 'Keep'; $c.reason = "Active via $($c.references.active.path -join ', ')." }
        elseif ($c.isDefault -and $c.category -in $script:PlatformDefaultCategories) { $c.disposition = 'Keep'; $c.reason = "Platform default connection for $($c.category)." }
        else { $c.disposition = 'Retire'; $c.reason = 'No active references in latest agents or latest toolboxes.' }
    }
    $cur = $Connections.Count; $retireCount = @($Connections | Where-Object { $_.disposition -eq 'Retire' }).Count; $consolidateCount = @($Connections | Where-Object { $_.disposition -eq 'Consolidate' }).Count
    $pct = if ($ConnectionLimit -gt 0) { [math]::Round(($cur / $ConnectionLimit) * 100, 1) } else { 0.0 }
    $headroom = [ordered]@{ limit = $ConnectionLimit; current = $cur; currentRaw = if ($RawCount -gt 0) { $RawCount } else { $cur }; afterRetire = $cur - $retireCount; afterRetireAndConsolidate = $cur - $retireCount - $consolidateCount; percentOfLimit = $pct; warnAt80Percent = [bool]($pct -ge 80.0) }
    return [pscustomobject]@{ Connections = $Connections; DuplicateGroups = @($dupGroups); Headroom = $headroom }
}

function Invoke-HygieneRest ([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$ResourceUrl) {
    for ($attempt = 0; $attempt -le 3; $attempt++) {
        $rawTok = (Get-AzAccessToken -ResourceUrl $ResourceUrl -AsSecureString).Token; $tok = if ($rawTok -is [securestring]) { $rawTok } else { ConvertTo-SecureString ([string]$rawTok) -AsPlainText -Force }
        try { return Invoke-RestMethod -Uri $Uri -Method Get -Authentication Bearer -Token $tok -TimeoutSec 60 -ErrorAction Stop }
        catch {
            $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -in @(429, 500, 502, 503, 504) -and $attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt + 1)); continue }; throw
        }
    }
}

function Get-HygienePagedList ([string]$Uri, [string]$ResourceUrl, [string]$Field = 'value') {
    $items = [System.Collections.Generic.List[object]]::new(); $next = $Uri
    while ($next) {
        $page = Invoke-HygieneRest -Uri $next -ResourceUrl $ResourceUrl; foreach ($it in @(if ($page.PSObject.Properties[$Field]) { $page.$Field } else { @() })) { if ($null -ne $it) { $items.Add($it) } }
        $next = if ($Field -eq 'value' -and $page.PSObject.Properties['nextLink'] -and $page.nextLink) { [uri]::new([uri]$Uri, [string]$page.nextLink).AbsoluteUri }
            elseif ($Field -eq 'data' -and $page.PSObject.Properties['has_more'] -and $page.has_more -and $page.PSObject.Properties['last_id'] -and $page.last_id) { "$Uri&after=$([uri]::EscapeDataString([string]$page.last_id))" } else { $null }
    }
    return $items.ToArray()
}

$accountId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName"; $armBase = "https://management.azure.com$accountId"
if ($DryRun) {
    @("GET $armBase`?api-version=$script:ArmApiVersion", "GET $armBase/connections?api-version=$script:ArmApiVersion", "GET $armBase/projects?api-version=$script:ArmApiVersion", "GET $armBase/projects/{project}/connections?api-version=$script:ArmApiVersion", "GET https://$AccountName.services.ai.azure.com/api/projects/{project}/toolboxes?api-version=$script:AgentsApiVersion&limit=100", "GET https://$AccountName.services.ai.azure.com/api/projects/{project}/toolboxes/{name}/versions?api-version=$script:AgentsApiVersion&limit=100", "GET https://$AccountName.services.ai.azure.com/api/projects/{project}/agents?api-version=$script:AgentsApiVersion&limit=100", "GET https://$AccountName.services.ai.azure.com/api/projects/{project}/agents/{name}/versions?api-version=$script:AgentsApiVersion&limit=100") | ForEach-Object { Write-Output $_ }; return
}

$armScope = 'https://management.azure.com/'; $aiScope = 'https://ai.azure.com/'
$account = Invoke-HygieneRest -Uri "$armBase`?api-version=$script:ArmApiVersion" -ResourceUrl $armScope
$projects = @(Get-HygienePagedList -Uri "$armBase/projects?api-version=$script:ArmApiVersion" -ResourceUrl $armScope)
$rawConns = [System.Collections.Generic.List[object]]::new()
foreach ($c in @(Get-HygienePagedList -Uri "$armBase/connections?api-version=$script:ArmApiVersion" -ResourceUrl $armScope)) { $rawConns.Add((ConvertTo-HygieneConnection $c)) }
$projectsData = [System.Collections.Generic.List[object]]::new(); $failedProjects = [System.Collections.Generic.List[string]]::new()
foreach ($p in $projects) {
    $pName = ([string]$p.name -split '/')[-1]
    try {
        foreach ($c in @(Get-HygienePagedList -Uri "$armBase/projects/$([uri]::EscapeDataString($pName))/connections?api-version=$script:ArmApiVersion" -ResourceUrl $armScope)) { $rawConns.Add((ConvertTo-HygieneConnection $c)) }
        $sub = if ($account.PSObject.Properties['properties'] -and $account.properties.PSObject.Properties['customSubDomainName'] -and $account.properties.customSubDomainName) { $account.properties.customSubDomainName } else { $AccountName }
        $ep = "https://$sub.services.ai.azure.com/api/projects/$([uri]::EscapeDataString($pName))"
        $tbs = @(Get-HygienePagedList -Uri "$ep/toolboxes?api-version=$script:AgentsApiVersion&limit=100" -ResourceUrl $aiScope -Field 'data')
        foreach ($tb in $tbs) { $tb | Add-Member -NotePropertyName versions -NotePropertyValue @(Get-HygienePagedList -Uri "$ep/toolboxes/$([uri]::EscapeDataString([string]$tb.name))/versions?api-version=$script:AgentsApiVersion&limit=100" -ResourceUrl $aiScope -Field 'data') -Force }
        $ags = @(Get-HygienePagedList -Uri "$ep/agents?api-version=$script:AgentsApiVersion&limit=100" -ResourceUrl $aiScope -Field 'data')
        foreach ($ag in $ags) { $ag | Add-Member -NotePropertyName versionList -NotePropertyValue @(Get-HygienePagedList -Uri "$ep/agents/$([uri]::EscapeDataString([string]$ag.name))/versions?api-version=$script:AgentsApiVersion&limit=100" -ResourceUrl $aiScope -Field 'data') -Force }
        $projectsData.Add([pscustomobject]@{ Project = $pName; Toolboxes = $tbs; Agents = $ags })
    } catch { $failedProjects.Add($pName); Write-Verbose "Project '$pName' collection failed: $($_.Exception.Message)" }
}

$logical = @(Merge-LogicalConnections -RawConnections $rawConns.ToArray())
$refResult = Resolve-ConnectionReferences -Connections $logical -ProjectsData $projectsData.ToArray() -IncludeHistoricalVersions:$IncludeHistoricalVersions
$dispResult = Set-ConnectionDispositions -Connections $refResult.Connections -FailedProjects $failedProjects.ToArray() -ConnectionLimit $ConnectionLimit -RawCount $rawConns.Count

$runDir = Join-Path $OutputPath ("run-{0}" -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
[void](New-Item -ItemType Directory -Path $runDir -Force)
$inventory = [ordered]@{ run = [ordered]@{ timestampUtc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); subscriptionId = $SubscriptionId; resourceGroup = $ResourceGroup; accountName = $AccountName; accountId = $accountId; includeHistoricalVersions = [bool]$IncludeHistoricalVersions }; headroom = $dispResult.Headroom; connections = $dispResult.Connections; toolboxes = $refResult.Toolboxes; duplicateGroups = $dispResult.DuplicateGroups; warnings = $refResult.Warnings }
$inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDir 'inventory.json') -Encoding utf8
@($dispResult.Connections | ForEach-Object { [pscustomobject]@{ Name = $_.name; Category = $_.category; Target = $_.target; AuthType = $_.authType; IsDefault = $_.isDefault; Scopes = ($_.scopes -join ';'); ActiveRefs = $_.references.activeCount; StaleRefs = $_.references.staleCount; DuplicateGroup = [string]$_.duplicateGroup; Disposition = $_.disposition; SurvivorCandidate = [string]$_.survivorCandidate; Reason = $_.reason } }) | Export-Csv -LiteralPath (Join-Path $runDir 'connections.csv') -NoTypeInformation -Encoding utf8
$h = $dispResult.Headroom; $counts = @{}; foreach ($d in @('Keep', 'Consolidate', 'Retire', 'Review')) { $counts[$d] = @($dispResult.Connections | Where-Object disposition -eq $d).Count }
$actionRows = @($dispResult.Connections | Where-Object { $_.disposition -in @('Retire', 'Consolidate') } | ForEach-Object { "| $($_.name) | $($_.category) | $($_.target) | $($_.disposition) | $($_.survivorCandidate) | $($_.reason) |" })
if (-not $actionRows.Count) { $actionRows = @('| _None_ | - | - | - | - | - |') }
$summaryLines = @("Headroom: $($h.current)/$($h.limit) logical connections ($($h.percentOfLimit)%, raw: $($h.currentRaw)) -> $($h.afterRetire) after Retire, $($h.afterRetireAndConsolidate) after Retire+Consolidate.", "Dispositions: Keep=$($counts.Keep), Consolidate=$($counts.Consolidate), Retire=$($counts.Retire), Review=$($counts.Review)", '| Name | Category | Target | Disposition | SurvivorCandidate | Reason |', '| --- | --- | --- | --- | --- | --- |') + $actionRows + @($refResult.Warnings | ForEach-Object { "Warning: $_" }) + @('Read-only run; no resources were modified.')
$summaryLines | Set-Content -LiteralPath (Join-Path $runDir 'summary.md') -Encoding utf8
