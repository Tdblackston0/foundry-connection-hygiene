#Requires -Version 7.0

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Get-FoundryConnectionInventory.ps1'
    $script:SubId      = '00000000-0000-0000-0000-000000000001'
    $script:RgName     = 'rg-foundry-sample'
    $script:AcctName   = 'foundry-sample-account'
    $script:ProjName   = 'manufacturing-operations-agent'
    $script:AccountId  = "/subscriptions/$script:SubId/resourceGroups/$script:RgName/providers/Microsoft.CognitiveServices/accounts/$script:AcctName"

    # Load pure functions by dot-sourcing in DryRun mode
    . $script:ScriptPath -SubscriptionId $script:SubId -ResourceGroup $script:RgName -AccountName $script:AcctName -DryRun > $null

    if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
        function global:Get-AzAccessToken {
            param($ResourceUrl, [switch]$AsSecureString)
            return [pscustomobject]@{ Token = (ConvertTo-SecureString 'mock-token' -AsPlainText -Force) }
        }
    }

    function script:New-FixtureApiResponder {
        $defs = @(
            @{ Name = 'manufacturingoperatiof3hgu6'; Category = 'AppInsights'; Target = ''; AuthType = 'ApiKey'; IsDefault = $true; Created = '2026-10-26T19:31:31Z' }
            @{ Name = 'FoundryMCPServerpreview'; Category = 'RemoteTool'; Target = 'https://mcp.ai.azure.com'; AuthType = 'UserEntraToken'; IsDefault = $true; Created = '2026-11-11T15:54:24Z' }
            @{ Name = 'WorkIQ'; Category = 'RemoteA2A'; Target = 'https://workiq.svc.cloud.microsoft/a2a'; AuthType = 'OAuth2'; IsDefault = $true; Created = '2026-11-12T17:34:00Z' }
            @{ Name = 'MicrosoftLearn'; Category = 'RemoteTool'; Target = 'https://learn.microsoft.com/api/mcp'; AuthType = 'None'; IsDefault = $false; Created = '2026-11-12T18:17:58Z' }
            @{ Name = 'FoundryMCPServerpreview2'; Category = 'RemoteTool'; Target = 'https://mcp.ai.azure.com'; AuthType = 'UserEntraToken'; IsDefault = $false; Created = '2026-11-12T18:22:07Z' }
        )

        $newConn = {
            param($d, [string]$id)
            [pscustomobject]@{
                id         = $id
                name       = $d.Name
                properties = [pscustomobject]@{
                    category    = $d.Category
                    target      = $d.Target
                    authType    = $d.AuthType
                    isDefault   = $d.IsDefault
                    createdDate = $d.Created
                }
                systemData = [pscustomobject]@{ createdAt = $d.Created }
            }
        }

        $acctConns = @($defs | ForEach-Object { & $newConn $_ "$($script:AccountId)/connections/$($_.Name)" })
        $projConns = @($defs | ForEach-Object { & $newConn $_ "$($script:AccountId)/projects/$($script:ProjName)/connections/$($_.Name)" })
        $workIqProjId = "$($script:AccountId)/projects/$($script:ProjName)/connections/WorkIQ"

        $tbVersions = @(
            [pscustomobject]@{
                version = '5'; skills = @()
                tools   = @(
                    [pscustomobject]@{ type = 'mcp'; name = 'MicrosoftLearn'; project_connection_id = 'MicrosoftLearn' },
                    [pscustomobject]@{ type = 'mcp'; name = 'FoundryMCPServerpreview2'; project_connection_id = 'FoundryMCPServerpreview2' }
                )
            },
            [pscustomobject]@{
                version = '4'; skills = @()
                tools   = @([pscustomobject]@{ type = 'mcp'; name = 'MicrosoftLearn'; project_connection_id = 'MicrosoftLearn' })
            },
            [pscustomobject]@{ version = '3'; skills = @('finance-skill'); tools = @() },
            [pscustomobject]@{
                version = '2'; skills = @()
                tools   = @([pscustomobject]@{ type = 'work_iq_preview'; name = 'WorkIQ'; project_connection_id = $workIqProjId })
            },
            [pscustomobject]@{
                version = '1'; skills = @()
                tools   = @(
                    [pscustomobject]@{ type = 'mcp'; name = 'FoundryMCPServerpreview'; project_connection_id = 'FoundryMCPServerpreview' },
                    [pscustomobject]@{ type = 'work_iq_preview'; name = 'WorkIQ'; project_connection_id = $workIqProjId }
                )
            }
        )

        $agentTbMap = @{ '11' = '5'; '10' = '4'; '9' = '3'; '8' = '2'; '7' = '1' }
        $agentVersions = foreach ($av in 11..1) {
            $avStr = [string]$av
            $tools = if ($agentTbMap.ContainsKey($avStr)) {
                $tbVer = $agentTbMap[$avStr]
                @([pscustomobject]@{
                    type       = 'mcp'
                    name       = 'finance-approvals'
                    server_url = "https://$($script:AcctName).services.ai.azure.com/api/projects/$($script:ProjName)/toolboxes/finance-approvals/versions/$tbVer/mcp?api-version=v1"
                })
            } else { @() }
            [pscustomobject]@{
                version    = $avStr
                draft      = $false
                definition = [pscustomobject]@{
                    kind  = 'prompt'
                    tools = $tools
                }
            }
        }

        return @{
            AccountId     = $script:AccountId
            AcctName      = $script:AcctName
            ProjName      = $script:ProjName
            AccountConns  = $acctConns
            ProjectConns  = $projConns
            TbVersions    = $tbVersions
            AgentVersions = $agentVersions
        }
    }

    $global:TestFixtureData = New-FixtureApiResponder
}

AfterAll {
    Remove-Variable -Name TestFixtureData -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Acceptance test: Foundry connection inventory fixture' {
    BeforeEach {
        Mock Get-AzAccessToken {
            [pscustomobject]@{ Token = (ConvertTo-SecureString 'mock-token' -AsPlainText -Force) }
        }
        Mock Invoke-RestMethod {
            $fx = $global:TestFixtureData
            switch -Regex ($Uri) {
                '/accounts/foundry-sample-account\?api-version=2025-06-01$' {
                    return [pscustomobject]@{
                        id         = $fx.AccountId
                        name       = $fx.AcctName
                        kind       = 'AIServices'
                        properties = [pscustomobject]@{ customSubDomainName = $fx.AcctName }
                    }
                }
                '/accounts/foundry-sample-account/projects\?api-version=2025-06-01$' {
                    return [pscustomobject]@{
                        value = @([pscustomobject]@{ name = "$($fx.AcctName)/$($fx.ProjName)" })
                    }
                }
                '/accounts/foundry-sample-account/connections\?api-version=2025-06-01$' {
                    return [pscustomobject]@{ value = $fx.AccountConns }
                }
                '/projects/manufacturing-operations-agent/connections\?api-version=2025-06-01$' {
                    return [pscustomobject]@{ value = $fx.ProjectConns }
                }
                '/toolboxes\?api-version=v1' {
                    return [pscustomobject]@{
                        data     = @([pscustomobject]@{ name = 'finance-approvals'; default_version = '1' })
                        has_more = $false
                    }
                }
                '/toolboxes/finance-approvals/versions\?api-version=v1' {
                    return [pscustomobject]@{ data = $fx.TbVersions; has_more = $false }
                }
                '/agents\?api-version=v1' {
                    return [pscustomobject]@{
                        data     = @([pscustomobject]@{
                            name     = 'manufacturing-operations'
                            versions = [pscustomobject]@{ latest = [pscustomobject]@{ version = '11' } }
                        })
                        has_more = $false
                    }
                }
                '/agents/manufacturing-operations/versions\?api-version=v1' {
                    return [pscustomobject]@{ data = $fx.AgentVersions; has_more = $false }
                }
                default { throw "Unexpected URI in test: $Uri" }
            }
        }
    }

    It 'produces the expected inventory.json, connections.csv, and summary.md on default run' {
        $outDir = Join-Path $TestDrive 'reports-default'
        & $script:ScriptPath `
            -SubscriptionId $script:SubId `
            -ResourceGroup  $script:RgName `
            -AccountName    $script:AcctName `
            -OutputPath     $outDir

        $runDirs = @(Get-ChildItem -Directory -Path $outDir -Filter 'run-*')
        $runDirs.Count | Should -Be 1
        $runFolder = $runDirs[0].FullName

        $invPath = Join-Path $runFolder 'inventory.json'
        $csvPath = Join-Path $runFolder 'connections.csv'
        $sumPath = Join-Path $runFolder 'summary.md'
        $invPath | Should -Exist
        $csvPath | Should -Exist
        $sumPath | Should -Exist

        $inv = Get-Content -LiteralPath $invPath -Raw | ConvertFrom-Json

        # 1. connections.length == 5; every connection has both account and project scope
        $inv.connections.Count | Should -Be 5
        foreach ($c in $inv.connections) {
            $c.scopes | Should -Contain 'account'
            $c.scopes | Should -Contain 'project:manufacturing-operations-agent'
        }

        # 2. Exactly one duplicateGroup: remotetool|https://mcp.ai.azure.com with members FoundryMCPServerpreview, FoundryMCPServerpreview2
        @($inv.duplicateGroups).Count | Should -Be 1
        $inv.duplicateGroups[0].group | Should -Be 'remotetool|https://mcp.ai.azure.com'
        $inv.duplicateGroups[0].members.Count | Should -Be 2
        $inv.duplicateGroups[0].members | Should -Contain 'FoundryMCPServerpreview'
        $inv.duplicateGroups[0].members | Should -Contain 'FoundryMCPServerpreview2'

        $byName = @{}
        foreach ($c in $inv.connections) { $byName[$c.name] = $c }

        # 3. FoundryMCPServerpreview2 -> Keep (active via agent v11 -> toolbox v5)
        $byName['FoundryMCPServerpreview2'].health | Should -Be 'Connected'
        $byName['FoundryMCPServerpreview2'].disposition | Should -Be 'Keep'
        $byName['FoundryMCPServerpreview2'].references.activeCount | Should -Be 1
        $byName['FoundryMCPServerpreview2'].references.active[0].path | Should -Be 'agent/manufacturing-operations@11 -> toolbox/finance-approvals@5'
        $byName['FoundryMCPServerpreview2'].survivorCandidate | Should -BeNullOrEmpty

        # 4. MicrosoftLearn -> Keep (active via agent v11 -> toolbox v5)
        $byName['MicrosoftLearn'].health | Should -Be 'Connected'
        $byName['MicrosoftLearn'].disposition | Should -Be 'Keep'
        $byName['MicrosoftLearn'].references.activeCount | Should -Be 1
        $byName['MicrosoftLearn'].references.active[0].path | Should -Be 'agent/manufacturing-operations@11 -> toolbox/finance-approvals@5'

        # 5. FoundryMCPServerpreview -> Consolidate, survivorCandidate = FoundryMCPServerpreview2, active = 0, stale[0] = toolbox/finance-approvals@1
        $byName['FoundryMCPServerpreview'].disposition | Should -Be 'Consolidate'
        $byName['FoundryMCPServerpreview'].survivorCandidate | Should -Be 'FoundryMCPServerpreview2'
        @($byName['FoundryMCPServerpreview'].references.active).Count | Should -Be 0
        $byName['FoundryMCPServerpreview'].references.activeCount | Should -Be 0
        $byName['FoundryMCPServerpreview'].references.stale[0].path | Should -BeLike 'toolbox/finance-approvals@1*'

        # 6. WorkIQ -> NotConnected, Retire, active = 0, reason names referencing tool
        $byName['WorkIQ'].health | Should -Be 'NotConnected'
        $byName['WorkIQ'].disposition | Should -Be 'Retire'
        @($byName['WorkIQ'].references.active).Count | Should -Be 0
        $byName['WorkIQ'].references.activeCount | Should -Be 0
        $byName['WorkIQ'].reason | Should -Be 'Not established (OAuth2 consent incomplete); referenced by toolbox/finance-approvals@1 tool work_iq_preview.'

        # 7. manufacturingoperatiof3hgu6 (AppInsights) -> Keep via platform-default rule
        $byName['manufacturingoperatiof3hgu6'].disposition | Should -Be 'Keep'
        $byName['manufacturingoperatiof3hgu6'].references.activeCount | Should -Be 0

        # 8. toolboxes metadata and default != latest warning
        @($inv.toolboxes).Count | Should -Be 1
        $inv.toolboxes[0].defaultVersion | Should -Be '1'
        $inv.toolboxes[0].latestVersion | Should -Be '5'
        @($inv.warnings | Where-Object { $_ -match 'default is v1' -and $_ -match 'latest is v5' }).Count | Should -Be 1

        # 9. headroom.current == 5, afterRetire == 4, afterRetireAndConsolidate == 3, currentRaw == 10
        $inv.headroom.current | Should -Be 5
        $inv.headroom.currentRaw | Should -Be 10
        $inv.headroom.afterRetire | Should -Be 4
        $inv.headroom.afterRetireAndConsolidate | Should -Be 3

        # 10. warnings.Count <= 3 and zero BlocksAnalysis fields
        @($inv.warnings).Count | Should -BeLessOrEqual 3
        ($inv | ConvertTo-Json -Depth 10) | Should -Not -Match 'BlocksAnalysis'

        # 11. summary.md <= 25 lines, first line matches headroom projection, ends with required sentence
        $sumLines = @(Get-Content -LiteralPath $sumPath)
        $sumLines.Count | Should -BeLessOrEqual 25
        $sumLines[0] | Should -Match '^Headroom: 5/120 .* -> 4 after Retire, 3 after Retire\+Consolidate\.$'
        $sumLines[-1] | Should -Be 'Read-only run; no resources were modified.'

        # 11. connections.csv has 5 rows and expected columns; removed v0.2 files are not written
        $csvRows = @(Import-Csv -LiteralPath $csvPath)
        $csvRows.Count | Should -Be 5
        $csvRows[0].PSObject.Properties.Name | Should -Be @(
            'Name', 'Category', 'Target', 'AuthType', 'IsDefault', 'Scopes',
            'ActiveRefs', 'StaleRefs', 'DuplicateGroup', 'Disposition', 'SurvivorCandidate', 'Reason'
        )
        foreach ($legacy in @('coverage.json', 'run.json', 'dependency-paths.csv', 'connection-reference-evidence.csv', 'potential-duplicates.csv', 'search-indexes.csv', 'consolidation-assessment.csv')) {
            (Join-Path $runFolder $legacy) | Should -Not -Exist
        }
    }

    It 'populates historical agent/toolbox stale references when -IncludeHistoricalVersions is set' {
        $outDir = Join-Path $TestDrive 'reports-hist'
        & $script:ScriptPath `
            -SubscriptionId $script:SubId `
            -ResourceGroup  $script:RgName `
            -AccountName    $script:AcctName `
            -OutputPath     $outDir `
            -IncludeHistoricalVersions

        $invPath = Get-ChildItem -Path $outDir -Filter 'inventory.json' -Recurse | Select-Object -First 1 -ExpandProperty FullName
        $inv = Get-Content -LiteralPath $invPath -Raw | ConvertFrom-Json
        $byName = @{}
        foreach ($c in $inv.connections) { $byName[$c.name] = $c }

        $byName['WorkIQ'].references.stale.path | Should -Contain 'toolbox/finance-approvals@1'
        $byName['WorkIQ'].references.stale.path | Should -Contain 'agent/manufacturing-operations@7 -> toolbox/finance-approvals@1'
        $byName['WorkIQ'].references.stale.path | Should -Contain 'agent/manufacturing-operations@8 -> toolbox/finance-approvals@2'
        $byName['FoundryMCPServerpreview'].references.stale.path | Should -Contain 'toolbox/finance-approvals@1'
        $byName['FoundryMCPServerpreview'].references.stale.path | Should -Contain 'agent/manufacturing-operations@7 -> toolbox/finance-approvals@1'
        $byName['MicrosoftLearn'].references.staleCount | Should -Be 1
        $byName['MicrosoftLearn'].references.stale[0].path | Should -Be 'agent/manufacturing-operations@10 -> toolbox/finance-approvals@4'
    }

    It 'prints GET endpoints and makes no REST calls when -DryRun is specified' {
        $output = & $script:ScriptPath `
            -SubscriptionId $script:SubId `
            -ResourceGroup  $script:RgName `
            -AccountName    $script:AcctName `
            -DryRun
        $output.Count | Should -BeGreaterOrEqual 8
        $output[0] | Should -Match '^GET https://management\.azure\.com/'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'skips non-prompt agents and records one warning per skipped agent' {
        $conn = @(Merge-LogicalConnections -RawConnections @(
            [pscustomobject]@{
                Id = "$($script:AccountId)/connections/c1"; Scope = 'account'; Project = ''
                Name = 'c1'; Category = 'RemoteTool'; Target = 'https://mcp.example.com'; AuthType = 'None'
                IsDefault = $false; Created = '2026-11-11T00:00:00Z'
            }
        ))
        $projData = @([pscustomobject]@{
            Project   = 'p1'
            Toolboxes = @()
            Agents    = @(
                [pscustomobject]@{
                    name        = 'hosted-workflow-agent'
                    versionList = @(
                        [pscustomobject]@{
                            version    = '1'
                            draft      = $false
                            definition = [pscustomobject]@{ kind = 'hosted'; tools = @([pscustomobject]@{ type = 'mcp'; name = 'c1'; project_connection_id = 'c1' }) }
                        }
                    )
                }
            )
        })
        $res = Resolve-ConnectionReferences -Connections $conn -ProjectsData $projData
        $res.Connections[0].references.activeCount | Should -Be 0
        @($res.Warnings).Count | Should -Be 2
        @($res.Warnings | Where-Object { $_ -match 'hosted-workflow-agent' }).Count | Should -Be 1
    }

    It 'contains no write HTTP verbs anywhere in Get-FoundryConnectionInventory.ps1 and stays <= 250 lines' {
        $rawScript = Get-Content -LiteralPath $script:ScriptPath -Raw
        $lines = @(Get-Content -LiteralPath $script:ScriptPath)
        $lines.Count | Should -BeLessOrEqual 250
        $rawScript | Should -Not -Match '\b(PUT|PATCH|DELETE)\b'
    }

    It 'isolates project failures to Review only for affected project connections' {
        $conn1 = [pscustomobject]@{
            Id = "$($script:AccountId)/projects/p1/connections/c1"; Scope = 'project:p1'; Project = 'p1'
            Name = 'c1'; Category = 'CustomKeys'; Target = 'https://a.example.com'; AuthType = 'ApiKey'
            IsDefault = $false; Created = '2026-11-11T00:00:00Z'
        }
        $conn2 = [pscustomobject]@{
            Id = "$($script:AccountId)/projects/p2/connections/c2"; Scope = 'project:p2'; Project = 'p2'
            Name = 'c2'; Category = 'CustomKeys'; Target = 'https://b.example.com'; AuthType = 'ApiKey'
            IsDefault = $false; Created = '2026-11-11T00:00:00Z'
        }
        $logical = Merge-LogicalConnections -RawConnections @($conn1, $conn2)
        $disp = Set-ConnectionDispositions -Connections $logical -FailedProjects @('p1') -ConnectionLimit 120 -RawCount 2
        ($disp.Connections | Where-Object name -eq 'c1').disposition | Should -Be 'Review'
        ($disp.Connections | Where-Object name -eq 'c2').disposition | Should -Be 'Retire'
        $disp.Headroom.afterRetire | Should -Be 1
    }
}
