#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
$script:ArmVersion = '2025-06-01'
$script:AgentVersion = 'v1'
$script:SearchVersion = '2026-04-01'

function Add-HygieneCoverage {
    param($State, [string]$Scope, [string]$Collector, [string]$Status, [string]$Detail, [bool]$BlocksAnalysis = $false)
    $State.Coverage.Add([pscustomobject]@{
        Scope = $Scope; Collector = $Collector; Status = $Status
        BlocksAnalysis = $BlocksAnalysis; Detail = $Detail
    })
}

function Get-HygieneAzureContext {
    param([guid]$SubscriptionId, [guid]$TenantId = [guid]::Empty)
    Import-Module Az.Accounts -MinimumVersion 2.12.1 -ErrorAction Stop
    $contextArgs = @{ SubscriptionId = $SubscriptionId.ToString(); ErrorAction = 'Stop'; Scope = 'Process' }
    if ($TenantId -ne [guid]::Empty) { $contextArgs.TenantId = $TenantId.ToString() }
    $context = Set-AzContext @contextArgs
    if ($context.Environment.Name -ne 'AzureCloud') { throw 'Only Azure public cloud (AzureCloud) is supported.' }
    if ($context.Subscription.Id -ne $SubscriptionId.ToString()) { throw 'Azure subscription context mismatch.' }
    if ($TenantId -ne [guid]::Empty -and $context.Tenant.Id -ne $TenantId.ToString()) { throw 'Azure tenant context mismatch.' }
    return $context
}

function Get-HygieneToken {
    param([string]$Audience, $Context)
    $token = (Get-AzAccessToken -ResourceUrl $Audience -TenantId $Context.Tenant.Id -AsSecureString -DefaultProfile $Context).Token
    if ($token -isnot [securestring]) { throw 'Az.Accounts did not return a SecureString. Update Az.Accounts.' }
    return $token
}

function Test-HygieneEndpointResolution {
    param([uri]$Uri)
    $task = [System.Net.Dns]::GetHostAddressesAsync($Uri.DnsSafeHost)
    if (-not $task.Wait(10000) -or $task.Result.Count -eq 0) { throw 'DNS resolution failed or timed out.' }
}

function Assert-HygieneReadUri {
    param([uri]$Uri, [uri]$Root, [string]$Audience)
    if ($Uri.Scheme -ne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Fragment -or
        $Uri.Authority -ne $Root.Authority) { throw 'Unsafe endpoint or continuation link rejected.' }
    $prefix = [regex]::Escape($Root.AbsolutePath.TrimEnd('/'))
    $path = $Uri.AbsolutePath
    switch ($Audience) {
        'https://management.azure.com/' {
            if ($Uri.Host -ne 'management.azure.com' -or
                $path -notmatch "^$prefix(/connections|/projects|/projects/[^/]+/connections)?$") {
                throw 'Only the selected ARM resource and its project/connection list paths are allowed.'
            }
        }
        'https://ai.azure.com' {
            if ($Uri.Host -notmatch '^[a-zA-Z0-9.-]+\.services\.ai\.azure\.com$' -or
                $path -notmatch "^$prefix/(agents|indexes|toolboxes)(/[^/]+/versions)?$") {
                throw 'Only supported Foundry agent/index/toolbox list/version paths are allowed.'
            }
        }
        'https://search.azure.com' {
            if ($Uri.Host -notmatch '^[a-zA-Z0-9-]+\.search\.windows\.net$' -or
                $path -notmatch '^/(indexes|knowledgesources|knowledgebases|indexers|aliases)$') {
                throw 'Only Search definition list paths are allowed.'
            }
        }
        default { throw 'Unsupported token audience.' }
    }
}

function Invoke-HygieneGet {
    param([uri]$Uri, [uri]$Root, [string]$Audience, $State)
    Assert-HygieneReadUri $Uri $Root $Audience
    if (-not $State.DnsChecked.Contains($Uri.Host)) {
        try { Test-HygieneEndpointResolution $Uri } catch { throw 'DNS failed. Check private DNS, VPN/peering, and the runner network.' }
        [void]$State.DnsChecked.Add($Uri.Host)
    }
    for ($attempt = 0; $attempt -le 3; $attempt++) {
        try {
            $token = Get-HygieneToken $Audience $State.Context
        }
        catch { throw 'Token acquisition failed. Check sign-in, tenant, consent, and resource audience.' }
        try {
            # Do not follow redirects with a bearer token; every continuation is validated separately.
            return Invoke-RestMethod -Uri $Uri -Method Get -Authentication Bearer -Token $token `
                -TimeoutSec 60 -MaximumRedirection 0 -ErrorAction Stop
        }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            if ($status -in @(429, 500, 502, 503, 504) -and $attempt -lt 3) {
                $delay = [math]::Pow(2, $attempt + 1)
                $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
                if ($retryAfter -gt 0) { $delay = [math]::Min(30, $retryAfter) }
                Start-Sleep -Seconds $delay
                continue
            }
            switch ($status) {
                401 { throw 'HTTP 401. Check tenant sign-in and token audience.' }
                403 { throw 'HTTP 403. Check read permissions, firewall rules, and private endpoint access.' }
                404 { throw 'HTTP 404. Check resource/endpoint and supported API version; this is not an empty inventory.' }
                429 { throw 'HTTP 429. Retry budget exhausted; rerun later.' }
                0 { throw 'HTTPS request failed. Check routing, proxy, TLS, firewall, and private endpoint connectivity.' }
                default { throw "HTTP $status. Read request failed; check the supported API and service health." }
            }
        }
        finally { $token = $null }
    }
}

function Get-HygieneList {
    param([string]$Uri, [string]$Root, [string]$Audience, [string]$Scope, [string]$Collector, $State,
        [ValidateSet('value', 'data')][string]$ArrayField = 'value')
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $next = $Uri
    try {
        while ($next) {
            if ($seen.Count -ge 10000 -or -not $seen.Add($next)) { throw 'Repeated or excessive pagination detected.' }
            $page = Invoke-HygieneGet -Uri $next -Root $Root -Audience $Audience -State $State
            $fields = @($page.PSObject.Properties.Name)
            if ($page -is [System.Collections.IDictionary]) { $fields = @($page.Keys) }
            if ($ArrayField -notin $fields -or $null -eq $page.$ArrayField -or
                $page.$ArrayField -isnot [System.Collections.IList]) {
                throw "Unsupported response: expected an array named $ArrayField."
            }
            foreach ($item in $page.$ArrayField) { $items.Add($item) }
            $next = $null
            if ($page.nextLink) { $next = [uri]::new([uri]$Uri, [string]$page.nextLink).AbsoluteUri }
            elseif ($page.'@odata.nextLink') { $next = [uri]::new([uri]$Uri, [string]$page.'@odata.nextLink').AbsoluteUri }
            elseif ($ArrayField -eq 'data') {
                if ('has_more' -notin $fields -or $page.has_more -isnot [bool]) {
                    throw 'Unsupported agent pagination: missing boolean has_more.'
                }
                if ($page.has_more) {
                    if (-not $page.last_id) { throw 'Agent pagination has_more without last_id.' }
                    $next = "$Uri&after=$([uri]::EscapeDataString([string]$page.last_id))"
                }
            }
        }
        Add-HygieneCoverage $State $Scope $Collector 'Complete' "Read $($items.Count) definitions."
        return @{ Items = $items.ToArray(); Complete = $true }
    }
    catch {
        Add-HygieneCoverage $State $Scope $Collector 'Failed' $_.Exception.Message $true
        return @{ Items = $items.ToArray(); Complete = $false }
    }
}

function Get-HygieneTarget {
    param([string]$Target)
    $uri = $null
    if ([uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) {
        $builder = [UriBuilder]::new($uri)
        $builder.UserName = ''; $builder.Password = ''; $builder.Query = ''; $builder.Fragment = ''
        return $builder.Uri.GetLeftPart([UriPartial]::Path).TrimEnd('/')
    }
    return ''
}

function ConvertTo-HygieneConnection {
    param($Connection)
    $id = [string]$Connection.id
    if ($id -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.CognitiveServices/accounts/[^/]+(?:/projects/([^/]+))?/connections/([^/]+)$') {
        throw 'Unsupported connection resource ID.'
    }
    $project = $Matches[1]; $name = $Matches[2]
    $scope = if ($project) { 'project' } else { 'account' }
    $shared = if ($null -eq $Connection.properties.isSharedToAll) { 'Unknown' } else { [string][bool]$Connection.properties.isSharedToAll }
    $default = if ($null -eq $Connection.properties.isDefault) { 'Unknown' } else { [string][bool]$Connection.properties.isDefault }
    $targetUri = $null
    $comparisonSafe = [uri]::TryCreate([string]$Connection.properties.target, [UriKind]::Absolute, [ref]$targetUri) -and
        $targetUri.Scheme -in @('http', 'https') -and -not $targetUri.UserInfo -and -not $targetUri.Query -and -not $targetUri.Fragment
    return [pscustomobject]@{
        Id = $id; Scope = $scope; Project = $project; Name = $name
        Category = [string]$Connection.properties.category
        Target = Get-HygieneTarget $Connection.properties.target
        TargetComparisonSafe = $comparisonSafe
        AuthType = [string]$Connection.properties.authType
        IsShared = $shared; IsDefault = $default
        Created = [string]$Connection.systemData.createdAt
        Protection = if ($shared -eq 'True' -or $default -eq 'True') { 'Protected' } else { 'RequiresReview' }
        ReferenceStatus = 'Unknown'
    }
}

function Resolve-HygieneConnection {
    param([string]$Reference, [string]$Project, [object[]]$Connections)
    if ($Reference.StartsWith('/')) { return @($Connections | Where-Object { $_.Id -eq $Reference }) }
    return @($Connections | Where-Object {
        $_.Name -eq $Reference -and ($_.Project -eq $Project -or ($_.Scope -eq 'account' -and $_.IsShared -eq 'True'))
    })
}

function Find-HygieneReference {
    param($Node, [string]$Project, [string]$Source, $State, [int]$Depth = 0, [string]$ToolType = '', [string]$ToolName = '')
    if ($null -eq $Node) { return }
    if ($Depth -gt 50) { throw 'Agent definition nesting exceeds supported depth.' }
    if ($Node -is [System.Collections.IList]) {
        foreach ($child in $Node) { Find-HygieneReference $child $Project $Source $State ($Depth + 1) $ToolType $ToolName }
        return
    }
    if ($Node -is [string] -or $Node -is [ValueType]) { return }
    $keys = @($Node.PSObject.Properties.Name)
    if ($Node -is [System.Collections.IDictionary]) { $keys = @($Node.Keys) }
    foreach ($key in $keys) {
        if ($key -in @('project_connection_id', 'connection_id', 'connection_name', 'connectionId', 'connectionName')) {
            $reference = [string]$Node.$key
            if ($reference -notmatch '^(?:[a-zA-Z0-9_.-]{1,128}|/subscriptions/[^/?#]+/resourceGroups/[^/?#]+/providers/Microsoft\.CognitiveServices/accounts/[^/?#]+(?:/projects/[^/?#]+)?/connections/[a-zA-Z0-9_.-]{1,128})$') {
                Add-HygieneCoverage $State $Project 'ReferenceResolution' 'Unsupported' 'A connection reference has an unsupported format; its raw value was not exported.' $true
                continue
            }
            $resolved = @(Resolve-HygieneConnection $reference $Project $State.Connections.ToArray())
            $status = if ($resolved.Count -eq 1) { 'Resolved' } elseif ($resolved.Count -gt 1) { 'Ambiguous' } else { 'Unresolved' }
            $id = if ($resolved.Count -eq 1) { $resolved[0].Id } else { '' }
            $indexName = if ($Node.index_name) { $Node.index_name } else { $Node.indexName }
            $State.Evidence.Add([pscustomobject]@{
                Project = $Project; Source = $Source; Field = $key; Reference = $reference
                ConnectionId = $id; Resolution = $status
                VersionState = if ($State.SourceStates) { [string]$State.SourceStates["$Project|$Source"] } else { '' }
                ToolType = $ToolType; ToolName = $ToolName; IndexName = [string]$indexName
            })
            if ($status -ne 'Resolved') {
                Add-HygieneCoverage $State $Project 'ReferenceResolution' 'Unsupported' "$status connection reference; manual review required." $true
            }
            if ($resolved.Count -eq 1 -and $indexName) {
                $State.IndexReferences.Add([pscustomobject]@{
                    Target = $resolved[0].Target; Index = [string]$indexName; Source = $Source
                })
            }
        }
        elseif ($key -notmatch '(?i)instructions|prompt|description|metadata|credential|secret|password|token|api.?key|headers|environment') {
            Find-HygieneReference $Node.$key $Project $Source $State ($Depth + 1) $ToolType $ToolName
        }
    }
}

function Get-HygieneVersionState {
    param($Version, $Latest, [string]$Kind)
    if ($Kind -eq 'Agent' -and $Version.draft -eq $true) { return 'Draft' }
    if (-not $Latest -or -not $Version.version) { return 'Unknown' }
    if ([string]$Version.version -eq [string]$Latest) {
        if ($Kind -eq 'Agent') { return 'Latest' }
        return 'Default'
    }
    if ($Kind -eq 'Agent') { return 'Historical' }
    return 'NonDefault'
}

function Add-HygieneToolboxLink {
    param($Tool, [string]$Endpoint, [string]$Project, [string]$Agent, [string]$Version, [string]$VersionState, $State)
    $uri = $null
    if (-not [uri]::TryCreate([string]$Tool.server_url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
        $uri.Host -ne ([uri]$Endpoint).Host -or
        $uri.AbsolutePath -notmatch '^/api/projects/([^/]+)/toolboxes/([^/]+)(?:/versions/([^/]+))?/mcp/?$') {
        Add-HygieneCoverage $State $Project 'McpDependencies' 'Unsupported' 'External or unrecognized MCP endpoint: downstream connections cannot be inspected.' $true
        return
    }
    $State.ToolboxLinks.Add([pscustomobject]@{
        Project = $Project; Agent = $Agent; AgentVersion = $Version; AgentVersionState = $VersionState
        ToolboxProject = [uri]::UnescapeDataString($Matches[1])
        Toolbox = [uri]::UnescapeDataString($Matches[2])
        RequestedVersion = [uri]::UnescapeDataString([string]$Matches[3])
    })
}

function Add-HygieneToolboxEvidence {
    param($State)
    foreach ($ref in @($State.Evidence | Where-Object { $_.Source -match '^agent/[^/]+/version/[^/]+$' })) {
        $parts = $ref.Source -split '/'
        $connection = @($State.Connections | Where-Object Id -eq $ref.ConnectionId | Select-Object -First 1)
        $State.DependencyPaths.Add([pscustomobject]@{
            Project = $ref.Project; Agent = $parts[1]; AgentVersion = $parts[3]; AgentVersionState = $ref.VersionState
            ToolboxProject = ''; Toolbox = ''; ToolboxVersion = ''; ToolboxVersionState = ''
            ToolType = $ref.ToolType; ToolName = $ref.ToolName; ConnectionId = $ref.ConnectionId; Reference = $ref.Reference
            Backend = if ($connection.Count) { $connection[0].Target } else { '' }
            IndexName = $ref.IndexName; Resolution = $ref.Resolution
        })
    }
    foreach ($link in $State.ToolboxLinks) {
        $versions = @($State.ToolboxVersions | Where-Object {
            $_.Project -eq $link.ToolboxProject -and $_.Toolbox -eq $link.Toolbox
        })
        $selected = if ($link.RequestedVersion) {
            @($versions | Where-Object Version -eq $link.RequestedVersion)
        } else {
            @($versions | Where-Object VersionState -eq 'Default')
        }
        if ($selected.Count -ne 1) {
            Add-HygieneCoverage $State $link.Project 'ToolboxResolution' 'Unsupported' 'An agent toolbox endpoint could not be resolved to one inventoried version.' $true
            $State.DependencyPaths.Add([pscustomobject]@{
                Project = $link.Project; Agent = $link.Agent; AgentVersion = $link.AgentVersion
                AgentVersionState = $link.AgentVersionState; ToolboxProject = $link.ToolboxProject
                Toolbox = $link.Toolbox; ToolboxVersion = $link.RequestedVersion
                ToolboxVersionState = 'Unknown'; ToolType = 'mcp'; ToolName = ''; ConnectionId = ''; Reference = ''
                Backend = ''; IndexName = ''; Resolution = 'UnresolvedToolbox'
            })
            continue
        }
        $box = $selected[0]
        $refs = @($State.Evidence | Where-Object { $_.Project -eq $box.Project -and $_.Source -eq $box.Source })
        if (-not $refs.Count) {
            $State.DependencyPaths.Add([pscustomobject]@{
                Project = $link.Project; Agent = $link.Agent; AgentVersion = $link.AgentVersion
                AgentVersionState = $link.AgentVersionState; ToolboxProject = $box.Project
                Toolbox = $box.Toolbox; ToolboxVersion = $box.Version; ToolboxVersionState = $box.VersionState
                ToolType = ''; ToolName = ''; ConnectionId = ''; Reference = ''; Backend = ''; IndexName = ''
                Resolution = 'NoConnectionReferenceFound'
            })
        }
        foreach ($ref in $refs) {
            $connection = @($State.Connections | Where-Object Id -eq $ref.ConnectionId | Select-Object -First 1)
            $State.DependencyPaths.Add([pscustomobject]@{
                Project = $link.Project; Agent = $link.Agent; AgentVersion = $link.AgentVersion
                AgentVersionState = $link.AgentVersionState; ToolboxProject = $box.Project
                Toolbox = $box.Toolbox; ToolboxVersion = $box.Version; ToolboxVersionState = $box.VersionState
                ToolType = $ref.ToolType; ToolName = $ref.ToolName; ConnectionId = $ref.ConnectionId; Reference = $ref.Reference
                Backend = if ($connection.Count) { $connection[0].Target } else { '' }
                IndexName = $ref.IndexName; Resolution = $ref.Resolution
            })
            if ($ref.Resolution -eq 'Resolved') {
                $State.Evidence.Add([pscustomobject]@{
                    Project = $link.Project
                    Source = "agent/$($link.Agent)/version/$($link.AgentVersion) -> toolbox/$($box.Toolbox)/version/$($box.Version)"
                    Field = $ref.Field; Reference = $ref.Reference; ConnectionId = $ref.ConnectionId
                    Resolution = 'Resolved'; VersionState = $link.AgentVersionState
                    ToolType = $ref.ToolType; ToolName = $ref.ToolName; IndexName = $ref.IndexName
                })
            }
        }
    }
}

function Get-HygieneAssessment {
    param($State, [bool]$Blocked)
    foreach ($connection in $State.Connections) {
        $refs = @($State.Evidence | Where-Object { $_.ConnectionId -eq $connection.Id })
        $alternatives = @($State.Connections | Where-Object {
            $_.Id -ne $connection.Id -and $connection.Target -and $connection.Category -and
            $connection.AuthType -and $connection.TargetComparisonSafe -and $_.TargetComparisonSafe -and
            $_.Target -ceq $connection.Target -and $_.Category -eq $connection.Category -and
            $_.AuthType -eq $connection.AuthType -and
            (($_.Scope -eq 'project' -and $_.Project -eq $connection.Project) -or
             ($_.Scope -eq 'account' -and $_.IsShared -eq 'True'))
        })
        $blockers = [System.Collections.Generic.List[string]]::new()
        if ($Blocked) { $blockers.Add('Incomplete or ambiguous dependency coverage') }
        if ($connection.IsDefault -eq 'Unknown' -or $connection.IsShared -eq 'Unknown') { $blockers.Add('Default or sharing status unknown') }
        if (-not $connection.Target -or -not $connection.Category -or -not $connection.AuthType) { $blockers.Add('Target, category, or authentication metadata missing') }
        if (-not $connection.TargetComparisonSafe) { $blockers.Add('Target comparison is incomplete or contains omitted URI components') }
        if ($alternatives.Count) { $blockers.Add('Replacement identity, permissions, sharing, and consumer repointing require validation') }
        $blockers.Add('External applications and owner approval require manual review')
        $disposition = if ($connection.Protection -eq 'Protected') { 'Keep' }
            elseif ($Blocked -or $connection.IsDefault -eq 'Unknown' -or $connection.IsShared -eq 'Unknown' -or
                    -not $connection.Target -or -not $connection.Category -or -not $connection.AuthType -or -not $connection.TargetComparisonSafe) { 'Investigate' }
            elseif ($alternatives.Count) { 'ConsolidationCandidate' }
            elseif ($refs.Count) { 'Keep' }
            else { 'RetirementReview' }
        $action = switch ($disposition) {
            'Keep' { 'Retain; review protected status and known consumers.' }
            'Investigate' { 'Resolve coverage and metadata gaps before a disposition.' }
            'ConsolidationCandidate' { 'Compare candidate identities and access, then plan and test consumer repointing and rollback.' }
            'RetirementReview' { 'Confirm owner, external consumers, and recovery before any separate cleanup process.' }
        }
        [pscustomobject]@{
            ConnectionId = $connection.Id; Project = $connection.Project; Disposition = $disposition
            ReferenceStatus = $connection.ReferenceStatus
            Consumers = (@($refs | ForEach-Object { "$($_.Source) [$($_.VersionState)]" } | Sort-Object -Unique) -join '; ')
            PotentialReplacementIds = (@($alternatives.Id | Sort-Object -Unique) -join '; ')
            Blockers = ($blockers -join '; '); NextAction = $action
            EstimatedNetReduction = 'Not verified'
        }
    }
}

function Get-HygieneProjectEndpoint {
    param($Project, $Account, $Config)
    $name = ([string]$Project.name -split '/')[-1]
    $endpoint = [string]$Config.projectEndpoints.$name
    if (-not $endpoint) {
        $candidates = @($Project.properties.endpoints.PSObject.Properties.Value) +
            @($Account.properties.endpoints.PSObject.Properties.Value)
        $base = $candidates | Where-Object { $_ -is [string] -and $_ -match '^https://[^/]+\.services\.ai\.azure\.com(?:/|$)' } | Select-Object -First 1
        if ($base) { $endpoint = ([uri]$base).GetLeftPart([UriPartial]::Authority) + "/api/projects/$([uri]::EscapeDataString($name))" }
        elseif ($Account.properties.customSubDomainName) {
            $endpoint = "https://$($Account.properties.customSubDomainName).services.ai.azure.com/api/projects/$([uri]::EscapeDataString($name))"
        }
    }
    $uri = $null
    if (-not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.Host -notmatch '^[a-zA-Z0-9.-]+\.services\.ai\.azure\.com$' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath.TrimEnd('/') -cne "/api/projects/$([uri]::EscapeDataString($name))") {
        throw 'No supported project endpoint. Supply this project endpoint in projectEndpoints in the local config.'
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Get-HygieneConfig {
    param([string]$ConfigPath, [string[]]$SearchServiceResourceId)
    $config = @{ searchServiceResourceIds = @(); projectEndpoints = @{}; indexOwnership = @() }
    if ($ConfigPath) {
        $inputConfig = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
        if ($inputConfig -isnot [System.Collections.IDictionary]) { throw 'Configuration must be a JSON object.' }
        foreach ($key in $inputConfig.Keys) {
            if ($key -notin @('searchServiceResourceIds', 'projectEndpoints', 'indexOwnership')) { throw "Unknown config key: $key" }
            $config[$key] = $inputConfig[$key]
        }
    }
    if ($config.projectEndpoints -isnot [System.Collections.IDictionary]) { throw 'projectEndpoints must be an object.' }
    if ($config.searchServiceResourceIds -isnot [System.Collections.IList] -or
        $config.indexOwnership -isnot [System.Collections.IList]) { throw 'Search services and indexOwnership must be arrays.' }
    $config.searchServiceResourceIds = @(@($config.searchServiceResourceIds) + @($SearchServiceResourceId) | Sort-Object -Unique)
    foreach ($id in $config.searchServiceResourceIds) {
        if ($id -notmatch '^/subscriptions/[a-fA-F0-9-]{36}/resourceGroups/[^/?#]+/providers/Microsoft\.Search/searchServices/[a-zA-Z0-9-]+$') {
            throw 'Invalid Search service resource ID.'
        }
    }
    foreach ($mapping in $config.indexOwnership) {
        if ($mapping.searchServiceResourceId -notin $config.searchServiceResourceIds -or
            $mapping.indexName -notmatch '^[a-zA-Z0-9_-]+$' -or -not $mapping.projectName -or
            $mapping.ownerApproved -isnot [bool]) { throw 'Invalid indexOwnership entry. Check selected service, indexName, projectName, and boolean ownerApproved.' }
    }
    return $config
}

function Get-HygieneDuplicate {
    param([object[]]$Connections)
    $groups = $Connections | Where-Object { $_.Target -and $_.Category } |
        Group-Object -CaseSensitive -Property { "$($_.Category.ToLowerInvariant())|$($_.Target)" } |
        Where-Object Count -gt 1
    foreach ($group in $groups) {
        foreach ($connection in $group.Group) {
            [pscustomobject]@{
                Group = $group.Name; Count = $group.Count; Id = $connection.Id
                Project = $connection.Project; AuthType = $connection.AuthType
                Note = 'Potential duplicate only; compare scope, identity, authorization, and sharing support.'
            }
        }
    }
}

function Get-HygieneSearchInventory {
    param($State, $Config, [string]$Arm)
    foreach ($id in $Config.searchServiceResourceIds) {
        $root = "$Arm$id"
        try {
            $service = Invoke-HygieneGet -Uri "$root`?api-version=2025-05-01" -Root $root -Audience "$Arm/" -State $State
            if ($service.id -ne $id -or $service.type -ne 'Microsoft.Search/searchServices') { throw 'Unexpected Search service identity.' }
            $name = ($id -split '/')[-1]
            $endpoint = "https://$name.search.windows.net"
            $definitions = @{}
            foreach ($kind in @('indexes', 'knowledgesources', 'knowledgebases', 'indexers', 'aliases')) {
                $uri = "$endpoint/$kind`?api-version=$script:SearchVersion"
                if ($kind -eq 'indexes') { $uri += '&$select=name' }
                $definitions[$kind] = Get-HygieneList $uri $endpoint 'https://search.azure.com' $id $kind $State
            }
            $references = [System.Collections.Generic.List[object]]::new()
            foreach ($source in $definitions.knowledgesources.Items) {
                if ($source.kind -eq 'searchIndex' -and $source.searchIndexParameters.searchIndexName) {
                    $references.Add(@{ Index = $source.searchIndexParameters.searchIndexName; Source = "knowledgeSource/$($source.name)" })
                }
                elseif ($source.kind -ne 'searchIndex') {
                    Add-HygieneCoverage $State $id 'KnowledgeSourceIndexMapping' 'Unsupported' 'Non-searchIndex knowledge source: generated index ownership is not inferred.' $true
                }
            }
            foreach ($indexer in $definitions.indexers.Items) {
                if ($indexer.targetIndexName) { $references.Add(@{ Index = $indexer.targetIndexName; Source = "indexer/$($indexer.name)" }) }
            }
            foreach ($alias in $definitions.aliases.Items) {
                foreach ($index in $alias.indexes) { $references.Add(@{ Index = $index; Source = "alias/$($alias.name)" }) }
            }
            foreach ($reference in $State.IndexReferences) {
                if ($reference.Target -eq $endpoint) { $references.Add(@{ Index = $reference.Index; Source = $reference.Source }) }
            }
            foreach ($index in $definitions.indexes.Items) {
                if (-not $index.name) { throw 'Index response missing name.' }
                $observed = @($references | Where-Object { $_.Index -ceq $index.name })
                $mappings = @($Config.indexOwnership | Where-Object { $_.searchServiceResourceId -eq $id -and $_.indexName -ceq $index.name })
                $approved = $mappings.Count -eq 1 -and $mappings[0].ownerApproved -eq $true -and
                    $mappings[0].projectName -in $State.ProjectNames
                $blocked = @($State.Coverage | Where-Object BlocksAnalysis).Count -gt 0
                $status = if ($observed.Count) { 'Referenced' } elseif ($blocked) { 'Unknown' } elseif ($approved) { 'OwnerMappedReviewCandidate' } else { 'Unmapped' }
                $State.Indexes.Add([pscustomobject]@{
                    SearchServiceId = $id; IndexName = $index.name; Status = $status
                    OwnerProject = ($mappings.projectName -join ';')
                    OwnerApproved = $approved; ReferenceEvidence = ($observed.Source -join ';')
                    Note = 'No orphan verdict; external consumers and owner review are required.'
                })
            }
        }
        catch { Add-HygieneCoverage $State $id 'SearchInventory' 'Failed' $_.Exception.Message $true }
    }
}

function ConvertTo-HygieneCsvCell {
    param($Value)
    $text = [string]$Value
    if ($text -match '^[\s]*[=+@\-\t\r\n]') { return "'$text" }
    return $text
}

function Export-HygieneCsv {
    param([object[]]$Rows, [string[]]$Columns, [string]$Path)
    $safe = @(
        foreach ($row in $Rows) {
            $record = [ordered]@{}
            foreach ($column in $Columns) { $record[$column] = ConvertTo-HygieneCsvCell $row.$column }
            [pscustomobject]$record
        }
    )
    if ($safe.Count) { $safe | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8 }
    else { ('"' + ($Columns -join '","') + '"') | Set-Content -LiteralPath $Path -Encoding utf8 }
}

function Write-HygieneReport {
    param($State, [string]$OutputDirectory, [string]$AccountId)
    $folder = Join-Path $OutputDirectory ("run-{0}-{1}" -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $folder -ErrorAction Stop)
    $blocked = @($State.Coverage | Where-Object BlocksAnalysis).Count -gt 0
    foreach ($connection in $State.Connections) {
        $found = @($State.Evidence | Where-Object { $_.ConnectionId -eq $connection.Id }).Count -gt 0
        $connection.ReferenceStatus = if ($found) { 'Referenced' } elseif ($blocked) { 'Unknown' } else { 'NoReferenceFoundWithinCheckedSources' }
    }
    # A late collector failure invalidates earlier negative conclusions, not positive evidence.
    if ($blocked) {
        foreach ($index in $State.Indexes) {
            if ($index.Status -ne 'Referenced') { $index.Status = 'Unknown' }
        }
    }
    $duplicates = @(Get-HygieneDuplicate $State.Connections.ToArray())
    $assessment = @(Get-HygieneAssessment $State $blocked)
    Export-HygieneCsv $State.Connections.ToArray() @('Id','Scope','Project','Name','Category','Target','TargetComparisonSafe','AuthType','IsShared','IsDefault','Created','Protection','ReferenceStatus') (Join-Path $folder 'connections.csv')
    Export-HygieneCsv $State.Evidence.ToArray() @('Project','Source','VersionState','ToolType','ToolName','IndexName','Field','Reference','ConnectionId','Resolution') (Join-Path $folder 'connection-reference-evidence.csv')
    Export-HygieneCsv $duplicates @('Group','Count','Id','Project','AuthType','Note') (Join-Path $folder 'potential-duplicates.csv')
    Export-HygieneCsv $State.DependencyPaths.ToArray() @('Project','Agent','AgentVersion','AgentVersionState','ToolboxProject','Toolbox','ToolboxVersion','ToolboxVersionState','ToolType','ToolName','ConnectionId','Reference','Backend','IndexName','Resolution') (Join-Path $folder 'dependency-paths.csv')
    Export-HygieneCsv $assessment @('ConnectionId','Project','Disposition','ReferenceStatus','Consumers','PotentialReplacementIds','Blockers','NextAction','EstimatedNetReduction') (Join-Path $folder 'consolidation-assessment.csv')
    Export-HygieneCsv $State.Indexes.ToArray() @('SearchServiceId','IndexName','Status','OwnerProject','OwnerApproved','ReferenceEvidence','Note') (Join-Path $folder 'search-indexes.csv')
    ConvertTo-Json -InputObject $State.Coverage.ToArray() -Depth 8 | Set-Content -LiteralPath (Join-Path $folder 'coverage.json') -Encoding utf8
    $metadata = [ordered]@{
        ToolVersion = '0.2.0'; CollectedAtUtc = [datetime]::UtcNow.ToString('o')
        AccountId = $AccountId; TenantId = [string]$State.Context.Tenant.Id
        ApiVersions = @{ Arm = $script:ArmVersion; Agents = $script:AgentVersion; Search = $script:SearchVersion; SearchManagement = '2025-05-01' }
        CollectionStatus = if ($blocked) { 'Partial' } else { 'CompleteWithinSupportedSources' }
        ConnectionCount = $State.Connections.Count; IndexCount = $State.Indexes.Count
        SearchServices = @($State.Config.searchServiceResourceIds)
        VisibilityCount = $State.VisibilityCount
        Limitations = @('No last-used timestamp or verified connection quota.', 'External application code, evaluations, prompt flows, classic assistants, hosted code, and vector-store internals are not inspected.', 'No reference found is not proof of no usage. Naming alone never establishes index ownership.')
    }
    $metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $folder 'run.json') -Encoding utf8
    $summary = @(
        '# Foundry hygiene report'
        ''
        "Collection: **$($metadata.CollectionStatus)**"
        "Unique connections: $($State.Connections.Count); connection visibility rows before deduplication: $($State.VisibilityCount)."
        "Potential duplicate groups: $(@($duplicates.Group | Sort-Object -Unique).Count); selected-service indexes: $($State.Indexes.Count)."
        "Dependency paths: $($State.DependencyPaths.Count); assessment rows: $($assessment.Count)."
        ''
        'Read-only: no Azure resources were changed.'
        ''
        '## Interpret carefully'
        '- Referenced means positive evidence was found, not that usage occurred recently.'
        '- NoReferenceFoundWithinCheckedSources is not unused. External consumers and unsupported sources remain unchecked.'
        '- Unknown means evidence is incomplete or ambiguous. Never use it to authorize cleanup.'
        '- OwnerMappedReviewCandidate requires owner and external-consumer review; it is not a proven orphan.'
        '- Empty CSVs can accompany failures. Read coverage.json and run.json before interpreting counts.'
        '- Shared/default protection and potential duplicates are review hints, not consolidation instructions.'
        '- Latest is not proof of deployment or runtime use; non-default and historical versions can still have consumers.'
        '- Assessment dispositions are review guidance, not authorization to migrate or delete.'
        '- Target credentials, query strings, and non-URI targets are omitted. No fixed connection quota is assumed.'
        ''
        '## Files'
        'connections.csv, connection-reference-evidence.csv, dependency-paths.csv, consolidation-assessment.csv, potential-duplicates.csv, search-indexes.csv, coverage.json, run.json.'
        ''
        '## Coverage'
    )
    foreach ($coverage in $State.Coverage) {
        $line = "$($coverage.Status): $($coverage.Collector) / $($coverage.Scope) - $($coverage.Detail)"
        $summary += '- ' + [System.Net.WebUtility]::HtmlEncode(($line -replace '[\r\n`*_\[\]|]', ' '))
    }
    $summary | Set-Content -LiteralPath (Join-Path $folder 'summary.md') -Encoding utf8
    return [pscustomobject]@{
        ExitCode = if ($blocked) { 2 } else { 0 }; ReportPath = $folder
        ConnectionCount = $State.Connections.Count; IndexCount = $State.Indexes.Count
        CollectionStatus = $metadata.CollectionStatus
    }
}

function Invoke-FoundryHygiene {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AccountName,
        [guid]$TenantId = [guid]::Empty,
        [string[]]$SearchServiceResourceId = @(),
        [string]$ConfigPath,
        [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'reports')
    )
    $config = Get-HygieneConfig $ConfigPath $SearchServiceResourceId
    $context = Get-HygieneAzureContext $SubscriptionId $TenantId
    $state = @{
        Context = $context; Config = $config; ProjectNames = @(); VisibilityCount = 0
        DnsChecked = [System.Collections.Generic.HashSet[string]]::new()
        Coverage = [System.Collections.Generic.List[object]]::new()
        Connections = [System.Collections.Generic.List[object]]::new()
        Evidence = [System.Collections.Generic.List[object]]::new()
        SourceStates = @{}
        ToolboxVersions = [System.Collections.Generic.List[object]]::new()
        ToolboxLinks = [System.Collections.Generic.List[object]]::new()
        DependencyPaths = [System.Collections.Generic.List[object]]::new()
        IndexReferences = [System.Collections.Generic.List[object]]::new()
        Indexes = [System.Collections.Generic.List[object]]::new()
    }
    Add-HygieneCoverage $state 'All' 'ExternalConsumers' 'NotInspected' 'App code, evaluations, prompt flows, vector-store internals, and classic assistants are outside supported source coverage.'
    $arm = 'https://management.azure.com'
    $id = "/subscriptions/$SubscriptionId/resourceGroups/$([uri]::EscapeDataString($ResourceGroup))/providers/Microsoft.CognitiveServices/accounts/$AccountName"
    $root = "$arm$id"
    $projects = @{ Items = @(); Complete = $false }
    try {
        $account = Invoke-HygieneGet "$root`?api-version=$script:ArmVersion" $root "$arm/" $state
        if ($account.kind -ne 'AIServices' -or $account.id -ne [uri]::UnescapeDataString($id)) {
            throw 'Expected the selected resource-based Foundry AIServices account. Classic hubs and other account types are unsupported.'
        }
        Add-HygieneCoverage $state $id 'AccountPreflight' 'Complete' 'Account identity and supported kind verified.'
        $projects = Get-HygieneList "$root/projects?api-version=$script:ArmVersion" $root "$arm/" $id 'Projects' $state
        $state.ProjectNames = @($projects.Items | ForEach-Object { ([string]$_.name -split '/')[-1] })
        $scopes = @([pscustomobject]@{ Path = "$root/connections"; Scope = $id })
        foreach ($project in $projects.Items) {
            $name = ([string]$project.name -split '/')[-1]
            if (-not $name) { throw 'Project response missing name.' }
            $scopes += [pscustomobject]@{ Path = "$root/projects/$([uri]::EscapeDataString($name))/connections"; Scope = $name }
        }
        $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($scope in $scopes) {
            $list = Get-HygieneList "$($scope.Path)?api-version=$script:ArmVersion" $root "$arm/" $scope.Scope 'Connections' $state
            foreach ($connection in $list.Items) {
                $state.VisibilityCount++
                try {
                    $row = ConvertTo-HygieneConnection $connection
                    if (-not $row.Id.StartsWith([uri]::UnescapeDataString($id) + '/', [StringComparison]::OrdinalIgnoreCase)) { throw 'Connection returned outside selected account.' }
                    if ($ids.Add($row.Id)) { $state.Connections.Add($row) }
                }
                catch { Add-HygieneCoverage $state $scope.Scope 'ConnectionShape' 'Failed' $_.Exception.Message $true }
            }
        }
    }
    catch { Add-HygieneCoverage $state $id 'AccountInventory' 'Failed' $_.Exception.Message $true }
    foreach ($project in $projects.Items) {
        $name = ([string]$project.name -split '/')[-1]
        try {
            $endpoint = Get-HygieneProjectEndpoint $project $account $config
            $boxes = Get-HygieneList "$endpoint/toolboxes?api-version=$script:AgentVersion&limit=100" $endpoint 'https://ai.azure.com' $name 'Toolboxes' $state 'data'
            foreach ($box in $boxes.Items) {
                if (-not $box.name) { throw 'Toolbox response missing name.' }
                $boxName = [uri]::EscapeDataString([string]$box.name)
                $boxVersions = Get-HygieneList "$endpoint/toolboxes/$boxName/versions?api-version=$script:AgentVersion&limit=100" $endpoint 'https://ai.azure.com' $name "ToolboxVersions/$boxName" $state 'data'
                if ($boxVersions.Complete -and -not $boxVersions.Items.Count) { throw 'Toolbox has no visible versions.' }
                foreach ($boxVersion in $boxVersions.Items) {
                    if (-not $boxVersion.version -or $boxVersion.tools -isnot [System.Collections.IList]) { throw 'Unsupported toolbox version shape.' }
                    $source = "toolbox/$($box.name)/version/$($boxVersion.version)"
                    $versionState = Get-HygieneVersionState $boxVersion $box.default_version 'Toolbox'
                    $state.SourceStates["$name|$source"] = $versionState
                    $state.ToolboxVersions.Add([pscustomobject]@{ Project = $name; Toolbox = $box.name; Version = [string]$boxVersion.version; VersionState = $versionState; Source = $source })
                    if ($boxVersion.skills -and @($boxVersion.skills).Count) {
                        Add-HygieneCoverage $state $name 'ToolboxSkills' 'Unsupported' 'Toolbox skill dependencies are not inspected.' $true
                    }
                    foreach ($tool in $boxVersion.tools) {
                        if (-not $tool.type) { throw 'Toolbox tool missing type.' }
                        $before = $state.Evidence.Count
                        Find-HygieneReference $tool $name $source $state 0 ([string]$tool.type) ([string]$tool.name)
                        if ($tool.type -eq 'azure_ai_search' -and $state.Evidence.Count -eq $before) {
                            Add-HygieneCoverage $state $name 'SearchToolReference' 'Unsupported' 'Search tool lacks a recognized connection reference.' $true
                        }
                        if ($tool.type -notin @('mcp','web_search','code_interpreter','file_search','toolbox_search','toolbox_search_preview','azure_ai_search','work_iq_preview','fabric_iq_preview','openapi','a2a_preview')) {
                            Add-HygieneCoverage $state $name 'OpaqueTool' 'Unsupported' 'A toolbox tool may access dependencies outside its definition.' $true
                        }
                    }
                }
            }
        }
        catch { Add-HygieneCoverage $state $name 'Toolboxes' 'Failed' $_.Exception.Message $true }
    }
    foreach ($project in $projects.Items) {
        $name = ([string]$project.name -split '/')[-1]
        try {
            $endpoint = Get-HygieneProjectEndpoint $project $account $config
            $assets = Get-HygieneList "$endpoint/indexes?api-version=$script:AgentVersion" $endpoint 'https://ai.azure.com' $name 'IndexAssets' $state
            foreach ($asset in $assets.Items) {
                if (-not $asset.name) { throw 'Index asset response missing name.' }
                $assetName = [uri]::EscapeDataString([string]$asset.name)
                $assetVersions = Get-HygieneList "$endpoint/indexes/$assetName/versions?api-version=$script:AgentVersion" $endpoint 'https://ai.azure.com' $name "IndexAssetVersions/$assetName" $state
                foreach ($assetVersion in $assetVersions.Items) {
                    $before = $state.Evidence.Count
                    Find-HygieneReference $assetVersion $name "indexAsset/$($asset.name)/version/$($assetVersion.version)" $state
                    if ($state.Evidence.Count -eq $before) {
                        Add-HygieneCoverage $state $name 'IndexAssetMapping' 'Unsupported' 'Index asset does not expose a recognized connection reference; backing index mapping needs owner review.' $true
                    }
                }
                if ($assetVersions.Complete -and -not $assetVersions.Items.Count) {
                    Add-HygieneCoverage $state $name 'IndexAssetMapping' 'Unsupported' 'Index asset has no visible versions.' $true
                }
            }
        }
        catch { Add-HygieneCoverage $state $name 'IndexAssets' 'Failed' $_.Exception.Message $true }
        try {
            $endpoint = Get-HygieneProjectEndpoint $project $account $config
            $agents = Get-HygieneList "$endpoint/agents?api-version=$script:AgentVersion&limit=100" $endpoint 'https://ai.azure.com' $name 'Agents' $state 'data'
            foreach ($agent in $agents.Items) {
                if (-not $agent.name) { throw 'Unsupported agent shape: name missing. Classic assistant definitions are not supported.' }
                $agentName = [uri]::EscapeDataString([string]$agent.name)
                $versions = Get-HygieneList "$endpoint/agents/$agentName/versions?api-version=$script:AgentVersion&limit=100&include_drafts=true" $endpoint 'https://ai.azure.com' $name "Versions/$agentName" $state 'data'
                if ($versions.Complete -and -not $versions.Items.Count) { throw 'Agent has no visible definitions; reference coverage is incomplete.' }
                foreach ($version in $versions.Items) {
                    if (-not $version.definition) { throw 'Agent version missing definition.' }
                    if ($version.definition.kind -ne 'prompt') {
                        Add-HygieneCoverage $state $name 'AgentDefinition' 'Unsupported' 'Non-prompt agent: hosted code or workflow dependencies cannot be fully inspected.' $true
                    }
                    $source = "agent/$($agent.name)/version/$($version.version)"
                    $versionState = Get-HygieneVersionState $version $agent.versions.latest.version 'Agent'
                    $state.SourceStates["$name|$source"] = $versionState
                    foreach ($property in $version.definition.PSObject.Properties) {
                        if ($property.Name -notmatch '(?i)^(tools|instructions|prompt|description|metadata|credential|secret|password|token|headers|environment)$') {
                            Find-HygieneReference $property.Value $name $source $state
                        }
                    }
                    foreach ($tool in $version.definition.tools) {
                        $before = $state.Evidence.Count
                        Find-HygieneReference $tool $name $source $state 0 ([string]$tool.type) ([string]$tool.name)
                        if ($tool.type -eq 'azure_ai_search' -and $state.Evidence.Count -eq $before) {
                            Add-HygieneCoverage $state $name 'SearchToolReference' 'Unsupported' 'Search tool lacks a recognized connection reference.' $true
                        }
                        if ($tool.type -eq 'mcp') {
                            Add-HygieneToolboxLink $tool $endpoint $name $agent.name ([string]$version.version) $versionState $state
                        }
                        if ($tool.type -notin @('mcp','web_search','code_interpreter','file_search','azure_ai_search','memory_search_preview','openapi','a2a_preview','work_iq_preview','fabric_iq_preview')) {
                            Add-HygieneCoverage $state $name 'OpaqueTool' 'Unsupported' 'An agent tool may access dependencies outside its definition.' $true
                        }
                    }
                }
            }
            Add-HygieneToolboxEvidence $state
        }
        catch { Add-HygieneCoverage $state $name 'AgentReferences' 'Failed' $_.Exception.Message $true }
    }
    foreach ($mapping in $config.indexOwnership) {
        if ($mapping.projectName -notin $state.ProjectNames) {
            Add-HygieneCoverage $state $mapping.searchServiceResourceId 'OwnershipMapping' 'Unsupported' 'Mapped project was not found in the selected account.' $true
        }
    }
    foreach ($projectName in $config.projectEndpoints.Keys) {
        if ($projectName -notin $state.ProjectNames) {
            Add-HygieneCoverage $state $projectName 'EndpointMapping' 'Unsupported' 'Configured project was not found in the selected account.' $true
        }
    }
    Get-HygieneSearchInventory $state $config $arm
    return Write-HygieneReport $state $OutputDirectory ([uri]::UnescapeDataString($id))
}

Export-ModuleMember -Function Invoke-FoundryHygiene
