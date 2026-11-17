#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,63}$')][string]$AccountName,
    [guid]$TenantId = [guid]::Empty,
    [string[]]$SearchServiceResourceId = @(),
    [string]$ConfigPath,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'reports')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\FoundryHygiene.psm1') -Force
try {
    $result = Invoke-FoundryHygiene @PSBoundParameters
    Write-Output "Connections: $($result.ConnectionCount); Search indexes: $($result.IndexCount)"
    Write-Output "Collection: $($result.CollectionStatus). Reports: $($result.ReportPath)"
    Write-Output 'Read-only. No reference found does not mean unused. See summary.md and coverage.json.'
    exit $result.ExitCode
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
