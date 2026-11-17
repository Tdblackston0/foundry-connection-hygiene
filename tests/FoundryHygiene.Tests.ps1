#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.7.1' }
Import-Module (Join-Path $PSScriptRoot '..\src\FoundryHygiene.psm1') -Force

InModuleScope FoundryHygiene {
    Describe 'Read-only HTTP contract' {
        BeforeEach {
            $script:state = @{
                Context = @{ Tenant = @{ Id = 'test' } }
                DnsChecked = [System.Collections.Generic.HashSet[string]]::new()
                Coverage = [System.Collections.Generic.List[object]]::new()
            }
            Mock Test-HygieneEndpointResolution {}
            Mock Get-HygieneToken { [securestring]::new() }
            Mock Start-Sleep {}
        }
        It 'uses only GET with SecureString bearer authentication and disables redirects' {
            Mock Invoke-RestMethod { [pscustomobject]@{ value = @() } }
            $root = 'https://demo.services.ai.azure.com/api/projects/p1'
            Invoke-HygieneGet "$root/agents?api-version=v1" $root 'https://ai.azure.com' $state
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Get' -and $Authentication -eq 'Bearer' -and
                $Token -is [securestring] -and $MaximumRedirection -eq 0
            }
        }
        It 'rejects external continuations and document or secret paths before requesting a token' {
            $root = 'https://demo.search.windows.net'
            { Invoke-HygieneGet 'https://other.search.windows.net/indexes' $root 'https://search.azure.com' $state } | Should -Throw
            { Invoke-HygieneGet "$root/indexes/i/docs" $root 'https://search.azure.com' $state } | Should -Throw
            { Invoke-HygieneGet 'https://management.azure.com/a/listKeys' 'https://management.azure.com/a' 'https://management.azure.com/' $state } | Should -Throw
            Should -Invoke Get-HygieneToken -Times 0
        }
        It 'reports DNS failure without exposing low-level details or acquiring a token' {
            Mock Test-HygieneEndpointResolution { throw 'private detail' }
            { Invoke-HygieneGet 'https://demo.search.windows.net/indexes' 'https://demo.search.windows.net' 'https://search.azure.com' $state } | Should -Throw '*DNS failed*'
            Should -Invoke Get-HygieneToken -Times 0
        }
        It 'bounds retries and suppresses raw error response content' {
            Mock Invoke-RestMethod {
                $errorObject = [Exception]::new('sensitive raw response')
                $errorObject | Add-Member Response ([pscustomobject]@{ StatusCode = 429; Headers = @{ RetryAfter = $null } })
                throw $errorObject
            }
            { Invoke-HygieneGet 'https://demo.search.windows.net/indexes' 'https://demo.search.windows.net' 'https://search.azure.com' $state } | Should -Throw '*429*'
            Should -Invoke Invoke-RestMethod -Times 4 -Exactly
            Should -Invoke Start-Sleep -Times 3 -Exactly
        }
    }

    Describe 'Pagination and completeness' {
        BeforeEach {
            $script:state = @{ Coverage = [System.Collections.Generic.List[object]]::new() }
        }
        It 'follows ARM nextLink and retains definitions from all pages' {
            Mock Invoke-HygieneGet {
                if ($Uri.Query -match 'page=2') { return [pscustomobject]@{ value = @(@{ name = 'second' }) } }
                return [pscustomobject]@{ value = @(@{ name = 'first' }); nextLink = '?page=2' }
            }
            $result = Get-HygieneList 'https://management.azure.com/a?api-version=x' 'https://management.azure.com/a' 'https://management.azure.com/' 'a' 'Connections' $state
            $result.Complete | Should -BeTrue
            $result.Items.Count | Should -Be 2
        }
        It 'handles cursor pagination with URL-encoded after values' {
            Mock Invoke-HygieneGet {
                if ($Uri.Query -match 'after=') { return [pscustomobject]@{ data = @(); has_more = $false } }
                return [pscustomobject]@{ data = @(@{ name = 'a' }); has_more = $true; last_id = 'x/y' }
            }
            $result = Get-HygieneList 'https://demo.services.ai.azure.com/api/projects/p/agents?api-version=v1' 'https://demo.services.ai.azure.com/api/projects/p' 'https://ai.azure.com' 'p' 'Agents' $state 'data'
            $result.Complete | Should -BeTrue
            Should -Invoke Invoke-HygieneGet -Times 1 -ParameterFilter { $Uri.Query -match 'after=x%2Fy' }
        }
        It 'preserves partial rows when the next page fails' {
            Mock Invoke-HygieneGet {
                if ($Uri.Query -match 'page=2') { throw 'HTTP 403.' }
                return [pscustomobject]@{ value = @(@{ name = 'first' }); nextLink = '?page=2' }
            }
            $result = Get-HygieneList 'https://management.azure.com/a?api-version=x' 'https://management.azure.com/a' 'https://management.azure.com/' 'a' 'Projects' $state
            $result.Complete | Should -BeFalse
            $result.Items.Count | Should -Be 1
            $state.Coverage[0].BlocksAnalysis | Should -BeTrue
        }
        It 'does not treat malformed or looping responses as empty success' {
            Mock Invoke-HygieneGet { [pscustomobject]@{ data = @(); has_more = $true } }
            $result = Get-HygieneList 'https://demo.services.ai.azure.com/api/projects/p/agents?api-version=v1' 'https://demo.services.ai.azure.com/api/projects/p' 'https://ai.azure.com' 'p' 'Agents' $state 'data'
            $result.Complete | Should -BeFalse
            Mock Invoke-HygieneGet { [pscustomobject]@{ value = @(); nextLink = '?api-version=x' } }
            $result = Get-HygieneList 'https://management.azure.com/a?api-version=x' 'https://management.azure.com/a' 'https://management.azure.com/' 'a' 'Projects' $state
            $result.Complete | Should -BeFalse
        }
    }

    Describe 'References, duplication, and configuration' {
        BeforeEach {
            $script:accountId = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/demo'
            $script:connections = @(
                ConvertTo-HygieneConnection @{ id = "$accountId/projects/p1/connections/search"; properties = @{ category = 'CognitiveSearch'; target = 'https://search.search.windows.net/?sig=secret'; authType = 'AAD' } }
                ConvertTo-HygieneConnection @{ id = "$accountId/projects/p2/connections/search"; properties = @{ category = 'CognitiveSearch'; target = 'https://search.search.windows.net'; authType = 'ApiKey' } }
                ConvertTo-HygieneConnection @{ id = "$accountId/connections/shared"; properties = @{ category = 'CognitiveSearch'; target = 'https://search.search.windows.net'; isSharedToAll = $true } }
            )
            $script:state = @{
                Connections = [System.Collections.Generic.List[object]]::new()
                Evidence = [System.Collections.Generic.List[object]]::new()
                IndexReferences = [System.Collections.Generic.List[object]]::new()
                Coverage = [System.Collections.Generic.List[object]]::new()
            }
            foreach ($connection in $connections) { $state.Connections.Add($connection) }
        }
        It 'resolves short references by project and shared references by account' {
            Find-HygieneReference @{
                tools = @(@{ azure_ai_search = @{ indexes = @(@{ project_connection_id = 'search'; index_name = 'docs' }) } },
                    @{ project_connection_id = 'shared' })
                instructions = 'Connection /connections/not-a-reference'
                credentials = @{ connection_name = 'do-not-read' }
            } p1 'agent/a/version/1' $state
            $state.Evidence.Count | Should -Be 2
            $state.Evidence[0].ConnectionId | Should -Be "$accountId/projects/p1/connections/search"
            $state.Evidence[1].ConnectionId | Should -Be "$accountId/connections/shared"
            $state.IndexReferences[0].Index | Should -Be 'docs'
        }
        It 'keeps ambiguous shared/project collisions unresolved' {
            $state.Connections.Add((ConvertTo-HygieneConnection @{ id = "$accountId/projects/p1/connections/shared"; properties = @{} }))
            Find-HygieneReference @{ project_connection_id = 'shared' } p1 'agent/a/version/1' $state
            $state.Evidence[0].Resolution | Should -Be 'Ambiguous'
            $state.Coverage[0].BlocksAnalysis | Should -BeTrue
        }
        It 'resolves full IDs and does not conflate full IDs in different projects' {
            Find-HygieneReference @{ connection_id = "$accountId/projects/p2/connections/search" } p1 'agent/a/version/1' $state
            $state.Evidence[0].ConnectionId | Should -Be "$accountId/projects/p2/connections/search"
        }
        It 'removes query credentials and tolerates missing target and dates' {
            $connections[0].Target | Should -Be 'https://search.search.windows.net'
            $connections[0].Created | Should -BeNullOrEmpty
            $connections[0].IsDefault | Should -Be 'Unknown'
            (Get-HygieneTarget 'not-a-uri secret') | Should -BeNullOrEmpty
            (Get-HygieneTarget 'https://user:password@example.com/path?secret=1') | Should -Be 'https://example.com/path'
            @(Get-HygieneDuplicate $connections).Count | Should -Be 3
            @(Get-HygieneDuplicate @(
                [pscustomobject]@{ Category = 'X'; Target = 'https://example.com/A' },
                [pscustomobject]@{ Category = 'X'; Target = 'https://example.com/a' }
            )).Count | Should -Be 0
        }
        It 'rejects invalid mappings and unknown config keys' {
            $path = Join-Path $TestDrive 'bad.local.json'
            '{"delete":true}' | Set-Content $path
            { Get-HygieneConfig $path @() } | Should -Throw '*Unknown config*'
            '{"indexOwnership":[{"searchServiceResourceId":"/unselected","indexName":"i","projectName":"p","ownerApproved":true}]}' | Set-Content $path
            { Get-HygieneConfig $path @() } | Should -Throw '*Invalid indexOwnership*'
            'null' | Set-Content $path
            { Get-HygieneConfig $path @() } | Should -Throw '*JSON object*'
        }
        It 'neutralizes CSV formulas' {
            (ConvertTo-HygieneCsvCell '=1+2') | Should -Be "'=1+2"
            (ConvertTo-HygieneCsvCell ' @formula') | Should -Be "' @formula"
        }
        It 'only suggests replacements with matching scope, authentication and complete target' {
            $a = ConvertTo-HygieneConnection @{ id = "$accountId/projects/p1/connections/a"; properties = @{ category = 'CognitiveSearch'; target = 'https://search.search.windows.net'; authType = 'AAD'; isDefault = $false; isSharedToAll = $false } }
            $b = ConvertTo-HygieneConnection @{ id = "$accountId/projects/p1/connections/b"; properties = @{ category = 'CognitiveSearch'; target = 'https://search.search.windows.net'; authType = 'AAD'; isDefault = $false; isSharedToAll = $false } }
            $c = ConvertTo-HygieneConnection @{ id = "$accountId/projects/p2/connections/c"; properties = @{ category = 'CognitiveSearch'; target = 'https://search.search.windows.net'; authType = 'AAD'; isDefault = $false; isSharedToAll = $false } }
            $d = ConvertTo-HygieneConnection @{ id = "$accountId/projects/p1/connections/d"; properties = @{ category = 'CognitiveSearch'; target = 'https://search.search.windows.net?tenant=other'; authType = 'AAD'; isDefault = $false; isSharedToAll = $false } }
            $state.Connections.Clear()
            foreach ($item in @($a,$b,$c,$d)) { $state.Connections.Add($item) }
            $rows = @(Get-HygieneAssessment $state $false)
            $candidate = $rows | Where-Object ConnectionId -eq $a.Id
            $candidate.Disposition | Should -Be 'ConsolidationCandidate'
            $candidate.PotentialReplacementIds | Should -Be $b.Id
            $candidate.EstimatedNetReduction | Should -Be 'Not verified'
            ($rows | Where-Object ConnectionId -eq $c.Id).Disposition | Should -Be 'RetirementReview'
            ($rows | Where-Object ConnectionId -eq $d.Id).Disposition | Should -Be 'Investigate'
            @((Get-HygieneAssessment $state $true) | Where-Object Disposition -ne 'Investigate').Count | Should -Be 0
        }
        It 'marks an unresolved toolbox link as incomplete rather than unused' {
            $state.ToolboxLinks = [System.Collections.Generic.List[object]]::new()
            $state.ToolboxVersions = [System.Collections.Generic.List[object]]::new()
            $state.DependencyPaths = [System.Collections.Generic.List[object]]::new()
            $state.ToolboxLinks.Add([pscustomobject]@{
                Project = 'p1'; Agent = 'a'; AgentVersion = '1'; AgentVersionState = 'Latest'
                ToolboxProject = 'p1'; Toolbox = 'missing'; RequestedVersion = ''
            })
            Add-HygieneToolboxEvidence $state
            $state.Coverage[0].BlocksAnalysis | Should -BeTrue
            $state.DependencyPaths[0].Resolution | Should -Be 'UnresolvedToolbox'
        }
        It 'recognizes default toolbox URLs and rejects external MCP dependencies' {
            $state.ToolboxLinks = [System.Collections.Generic.List[object]]::new()
            $endpoint = 'https://demo.services.ai.azure.com/api/projects/p1'
            Add-HygieneToolboxLink @{ server_url = "$endpoint/toolboxes/approved/mcp?api-version=v1" } $endpoint 'p1' 'a' '1' 'Latest' $state
            $state.ToolboxLinks[0].Toolbox | Should -Be 'approved'
            $state.ToolboxLinks[0].RequestedVersion | Should -BeNullOrEmpty
            Add-HygieneToolboxLink @{ server_url = 'https://external.example/mcp' } $endpoint 'p1' 'a' '1' 'Latest' $state
            $state.Coverage[0].BlocksAnalysis | Should -BeTrue
        }
        It 'retains a toolbox link when its selected version has no connection references' {
            $state.ToolboxLinks = [System.Collections.Generic.List[object]]::new()
            $state.ToolboxVersions = [System.Collections.Generic.List[object]]::new()
            $state.DependencyPaths = [System.Collections.Generic.List[object]]::new()
            $state.ToolboxLinks.Add([pscustomobject]@{
                Project = 'p1'; Agent = 'a'; AgentVersion = '1'; AgentVersionState = 'Latest'
                ToolboxProject = 'p1'; Toolbox = 'box'; RequestedVersion = ''
            })
            $state.ToolboxVersions.Add([pscustomobject]@{
                Project = 'p1'; Toolbox = 'box'; Version = '2'; VersionState = 'Default'; Source = 'toolbox/box/version/2'
            })
            Add-HygieneToolboxEvidence $state
            $state.DependencyPaths[0].Resolution | Should -Be 'NoConnectionReferenceFound'
        }
    }

    Describe 'Complete entry-point workflow with mocked Azure' {
        BeforeEach {
            $script:subscription = '00000000-0000-0000-0000-000000000001'
            $script:accountId = "/subscriptions/$subscription/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/demo"
            $script:searchId = "/subscriptions/$subscription/resourceGroups/rg/providers/Microsoft.Search/searchServices/search"
            $script:failAgents = $false
            $script:lateFailure = $false
            $script:opaqueAgent = $false
            $script:badVersion = $false
            $script:classicAccount = $false
            $script:includeToolbox = $false
            $script:failToolboxes = $false
            Mock Get-HygieneAzureContext { @{ Tenant = @{ Id = 'test-tenant' } } }
            Mock Invoke-HygieneGet {
                $path = ([uri]$Uri).AbsolutePath
                $response = switch -Regex ($path) {
                    '/searchServices/search$' { @{ id = $searchId; type = 'Microsoft.Search/searchServices' }; break }
                    '/searchServices/broken$' { throw 'HTTP 403.' }
                    '^/indexes$' { @{ value = @(@{ name = 'used' }, @{ name = 'review' }, @{ name = 'unmapped' }) }; break }
                    '^/knowledgesources$' { @{ value = @(@{ name = 'ks'; kind = 'searchIndex'; searchIndexParameters = @{ searchIndexName = 'used' } }) }; break }
                    '^/knowledgebases$' { @{ value = @(@{ name = 'kb'; knowledgeSources = @(@{ name = 'ks' }) }) }; break }
                    '^/(indexers|aliases)$' { @{ value = @() }; break }
                    '/api/projects/p1/indexes$' { @{ value = @() }; break }
                    '/api/projects/p1/toolboxes$' {
                        if ($failToolboxes) { throw 'HTTP 403.' }
                        if ($includeToolbox) { @{ data = @(@{ name = 'approved'; default_version = '2' }); has_more = $false } }
                        else { @{ data = @(); has_more = $false } }
                        break
                    }
                    '/api/projects/p1/toolboxes/approved/versions$' {
                        @{ data = @(
                            @{ version = '2'; tools = @(@{ type = 'mcp'; project_connection_id = 'shared' }) },
                            @{ version = '1'; tools = @(@{ type = 'mcp'; project_connection_id = 'search' }) }
                        ); has_more = $false }; break
                    }
                    '/api/projects/p1/agents$' {
                        if ($failAgents) { throw 'HTTP 403.' }
                        @{ data = @(@{ name = 'agent-a'; versions = @{ latest = @{ version = '1' } } }); has_more = $false }; break
                    }
                    '/api/projects/p1/agents/agent-a/versions$' {
                        if ($badVersion) { @{ data = @(@{ version = '1' }); has_more = $false }; break }
                        $kind = if ($opaqueAgent) { 'hosted' } else { 'prompt' }
                        @{ data = @(@{
                            version = '1'; definition = @{
                                kind = $kind
                                instructions = 'SECRET_PROMPT'
                                tools = @(@{ type = 'azure_ai_search'; azure_ai_search = @{ indexes = @(@{ project_connection_id = 'search'; index_name = 'used' }) } }) + $(if ($includeToolbox) { @(@{ type = 'mcp'; server_url = 'https://demo.services.ai.azure.com/api/projects/p1/toolboxes/approved/versions/2/mcp?api-version=v1' }) } else { @() })
                            }
                        }); has_more = $false }; break
                    }
                    '/accounts/demo$' {
                        @{ id = $accountId; kind = $(if ($classicAccount) { 'OpenAI' } else { 'AIServices' }); properties = @{ customSubDomainName = 'demo' } }; break
                    }
                    '/accounts/demo/projects$' { @{ value = @(@{ name = 'p1'; properties = @{} }) }; break }
                    '/accounts/demo/connections$' {
                        @{ value = @(@{ id = "$accountId/connections/shared"; properties = @{ isSharedToAll = $true; target = 'https://search.search.windows.net'; category = 'CognitiveSearch' } }) }; break
                    }
                    '/projects/p1/connections$' {
                        @{ value = @(
                            @{ id = "$accountId/connections/shared"; properties = @{ isSharedToAll = $true; target = 'https://search.search.windows.net'; category = 'CognitiveSearch' } },
                            @{ id = "$accountId/projects/p1/connections/search"; properties = @{ category = 'CognitiveSearch'; target = 'https://search.search.windows.net?sig=SECRET_QUERY'; credentials = @{ key = 'SECRET_KEY' } } },
                            @{ id = "$accountId/projects/p1/connections/other"; properties = @{ target = $null } }
                        ) }; break
                    }
                    default { throw "Unexpected mock route: $path" }
                }
                return $response | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            }
            $script:configPath = Join-Path $TestDrive 'customer.local.json'
            @{
                searchServiceResourceIds = @($searchId)
                indexOwnership = @(@{ searchServiceResourceId = $searchId; indexName = 'review'; projectName = 'p1'; ownerApproved = $true })
            } | ConvertTo-Json -Depth 10 | Set-Content $configPath
            $script:runArgs = @{
                SubscriptionId = $subscription; ResourceGroup = 'rg'; AccountName = 'demo'
                ConfigPath = $configPath; OutputDirectory = (Join-Path $TestDrive 'reports with spaces')
            }
        }
        It 'writes complete scoped reports, deduplicates shared visibility, and omits secrets' {
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 0
            $result.ConnectionCount | Should -Be 3
            $metadata = Get-Content (Join-Path $result.ReportPath 'run.json') -Raw | ConvertFrom-Json
            $metadata.VisibilityCount | Should -Be 4
            $rows = Import-Csv (Join-Path $result.ReportPath 'connections.csv')
            ($rows | Where-Object Name -eq 'search').ReferenceStatus | Should -Be 'Referenced'
            ($rows | Where-Object Name -eq 'other').ReferenceStatus | Should -Be 'NoReferenceFoundWithinCheckedSources'
            $direct = Import-Csv (Join-Path $result.ReportPath 'dependency-paths.csv')
            @($direct).Count | Should -Be 1
            $direct.IndexName | Should -Be 'used'
            $direct.ToolType | Should -Be 'azure_ai_search'
            $indexes = Import-Csv (Join-Path $result.ReportPath 'search-indexes.csv')
            ($indexes | Where-Object IndexName -eq 'used').Status | Should -Be 'Referenced'
            ($indexes | Where-Object IndexName -eq 'review').Status | Should -Be 'OwnerMappedReviewCandidate'
            ($indexes | Where-Object IndexName -eq 'unmapped').Status | Should -Be 'Unmapped'
            $contents = (Get-ChildItem $result.ReportPath -File | Get-Content -Raw) -join "`n"
            $contents | Should -Not -Match 'SECRET_KEY|SECRET_PROMPT|SECRET_QUERY'
            Should -Invoke Invoke-HygieneGet -Times 1 -ParameterFilter { ([uri]$Uri).Query -match 'include_drafts=true' }
        }
        It 'does not overwrite a previous run' {
            $first = Invoke-FoundryHygiene @runArgs
            $second = Invoke-FoundryHygiene @runArgs
            $first.ReportPath | Should -Not -Be $second.ReportPath
            Test-Path (Join-Path $first.ReportPath 'summary.md') | Should -BeTrue
        }
        It 'turns missing agent access into Unknown rather than unused or orphan' {
            $script:failAgents = $true
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 2
            @(Import-Csv (Join-Path $result.ReportPath 'connections.csv') | Where-Object ReferenceStatus -ne 'Unknown').Count | Should -Be 0
            $indexes = Import-Csv (Join-Path $result.ReportPath 'search-indexes.csv')
            ($indexes | Where-Object IndexName -eq 'review').Status | Should -Be 'Unknown'
            ($indexes | Where-Object IndexName -eq 'used').Status | Should -Be 'Referenced'
        }
        It 'invalidates earlier review candidates after a later service failure' {
            $runArgs.SearchServiceResourceId = @("/subscriptions/$subscription/resourceGroups/rg/providers/Microsoft.Search/searchServices/broken")
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 2
            (Import-Csv (Join-Path $result.ReportPath 'search-indexes.csv') | Where-Object IndexName -eq 'review').Status | Should -Be 'Unknown'
        }
        It 'retains positive evidence but marks opaque agent coverage incomplete' {
            $script:opaqueAgent = $true
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 2
            $rows = Import-Csv (Join-Path $result.ReportPath 'connections.csv')
            ($rows | Where-Object Name -eq 'search').ReferenceStatus | Should -Be 'Referenced'
            ($rows | Where-Object Name -eq 'other').ReferenceStatus | Should -Be 'Unknown'
        }
        It 'rejects unsupported version shapes and classic account types honestly' {
            $script:badVersion = $true
            (Invoke-FoundryHygiene @runArgs).ExitCode | Should -Be 2
            $script:classicAccount = $true
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 2
            $result.ConnectionCount | Should -Be 0
        }
        It 'produces valid header-only Search CSV when Search is not selected' {
            $runArgs.Remove('ConfigPath')
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 0
            $result.IndexCount | Should -Be 0
            (Get-Content (Join-Path $result.ReportPath 'search-indexes.csv')).Count | Should -Be 1
        }
        It 'does not promote unapproved or conflicting ownership mappings' {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
            $config.indexOwnership[0].ownerApproved = $false
            $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
            $result = Invoke-FoundryHygiene @runArgs
            (Import-Csv (Join-Path $result.ReportPath 'search-indexes.csv') | Where-Object IndexName -eq 'review').Status | Should -Be 'Unmapped'
            $config.indexOwnership[0].ownerApproved = $true
            $config.indexOwnership += $config.indexOwnership[0].Clone()
            $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
            $result = Invoke-FoundryHygiene @runArgs
            (Import-Csv (Join-Path $result.ReportPath 'search-indexes.csv') | Where-Object IndexName -eq 'review').Status | Should -Be 'Unmapped'
        }
        It 'flags an endpoint override referring to an unknown project' {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
            $config.projectEndpoints = @{ typo = 'https://demo.services.ai.azure.com/api/projects/typo' }
            $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 2
        }
        It 'maps agent through an exact toolbox version to its connection' {
            $script:includeToolbox = $true
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 0
            $paths = Import-Csv (Join-Path $result.ReportPath 'dependency-paths.csv')
            $path = $paths | Where-Object Toolbox -eq 'approved'
            $path.Agent | Should -Be 'agent-a'
            $path.AgentVersionState | Should -Be 'Latest'
            $path.ToolboxVersion | Should -Be '2'
            $path.ToolboxVersionState | Should -Be 'Default'
            $path.ConnectionId | Should -Be "$accountId/connections/shared"
            $path.Resolution | Should -Be 'Resolved'
            $rows = Import-Csv (Join-Path $result.ReportPath 'connections.csv')
            ($rows | Where-Object Name -eq 'shared').ReferenceStatus | Should -Be 'Referenced'
            $assessment = Import-Csv (Join-Path $result.ReportPath 'consolidation-assessment.csv')
            ($assessment | Where-Object ConnectionId -eq "$accountId/connections/shared").Disposition | Should -Be 'Keep'
            ($assessment | Where-Object ConnectionId -eq "$accountId/projects/p1/connections/search").Disposition | Should -Be 'Investigate'
        }
        It 'blocks negative conclusions if toolbox collection fails' {
            $script:failToolboxes = $true
            $result = Invoke-FoundryHygiene @runArgs
            $result.ExitCode | Should -Be 2
            $assessment = Import-Csv (Join-Path $result.ReportPath 'consolidation-assessment.csv')
            ($assessment | Where-Object ConnectionId -eq "$accountId/projects/p1/connections/other").Disposition | Should -Be 'Investigate'
        }
        It 'resolves a default toolbox endpoint and never infers deployment from latest' {
            $script:includeToolbox = $true
            Mock Add-HygieneToolboxLink {
                $State.ToolboxLinks.Add([pscustomobject]@{
                    Project = 'p1'; Agent = 'agent-a'; AgentVersion = '1'; AgentVersionState = 'Latest'
                    ToolboxProject = 'p1'; Toolbox = 'approved'; RequestedVersion = ''
                })
            }
            $result = Invoke-FoundryHygiene @runArgs
            $path = Import-Csv (Join-Path $result.ReportPath 'dependency-paths.csv') | Where-Object Toolbox -eq 'approved'
            $path.ToolboxVersion | Should -Be '2'
            $path.ToolboxVersionState | Should -Be 'Default'
            $path.AgentVersionState | Should -Be 'Latest'
        }
    }
}
