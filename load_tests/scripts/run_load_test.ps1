[CmdletBinding()]
param(
    [ValidateSet(
        'apim-smoke-test',
        'appgw-smoke-test',
        'appgw-failover-test',
        'multi-sub-failover-test',
        'steady-state-test'
    )]
    [string] $TestId,

    [int] $TimeoutMinutes = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tests = @(
    [pscustomobject]@{
        Number = 1
        TestId = 'apim-smoke-test'
        RunPrefix = 'apim-smoke'
        Duration = '~2 min'
        TimeoutMinutes = 20
        PollSeconds = 20
        Recommended = $true
        Description = 'APIM smoke - direct internal VNet path (no App Gateway)'
        DisplayName = 'APIM smoke'
    }
    [pscustomobject]@{
        Number = 2
        TestId = 'appgw-smoke-test'
        RunPrefix = 'appgw-smoke'
        Duration = '~5 min'
        TimeoutMinutes = 20
        PollSeconds = 20
        Recommended = $false
        Description = 'App Gateway smoke - measures WAF inspection overhead'
        DisplayName = 'App Gateway smoke'
    }
    [pscustomobject]@{
        Number = 3
        TestId = 'appgw-failover-test'
        RunPrefix = 'appgw-failover'
        Duration = '~2 min'
        TimeoutMinutes = 20
        PollSeconds = 20
        Recommended = $false
        Description = 'Failover - validates circuit-state routing end to end'
        DisplayName = 'App Gateway failover'
    }
    [pscustomobject]@{
        Number = 4
        TestId = 'multi-sub-failover-test'
        RunPrefix = 'multi-sub-failover'
        Duration = '~2 min'
        TimeoutMinutes = 25
        PollSeconds = 20
        Recommended = $false
        Description = 'Multi-subscription failover and isolation under concurrent load'
        DisplayName = 'Multi-subscription failover'
    }
    [pscustomobject]@{
        Number = 5
        TestId = 'steady-state-test'
        RunPrefix = 'steady-state'
        Duration = '1 hour'
        TimeoutMinutes = 90
        PollSeconds = 30
        Recommended = $false
        Description = 'Steady-state baseline traffic for workbooks and alerting'
        DisplayName = 'Steady state'
    }
)

$selected = if ($TestId) {
    $tests | Where-Object TestId -eq $TestId
} else {
    Write-Host ''
    Write-Host ' Azure AI Platform - Load Test Launcher' -ForegroundColor Cyan
    Write-Host ''
    foreach ($test in $tests) {
        $recommended = if ($test.Recommended) { ' (recommended after azd provision)' } else { '' }
        Write-Host "  [$($test.Number)] $($test.Description)$recommended"
        Write-Host "      Test ID: $($test.TestId)  Duration: $($test.Duration)" -ForegroundColor DarkGray
    }
    Write-Host ''

    do {
        $input = Read-Host 'Select a test [1-5] (or Q to quit)'
        if ($input -match '^[Qq]$') { exit 0 }
        $choice = $input -as [int]
    } while ($choice -lt 1 -or $choice -gt $tests.Count)

    $tests | Where-Object Number -eq $choice
}

$effectiveTimeout = if ($TimeoutMinutes -gt 0) { $TimeoutMinutes } else { $selected.TimeoutMinutes }
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

& "$PSScriptRoot/invoke_load_test.ps1" `
    -TestId $selected.TestId `
    -RunPrefix $selected.RunPrefix `
    -DisplayName "$($selected.DisplayName) $timestamp" `
    -TimeoutMinutes $effectiveTimeout `
    -PollSeconds $selected.PollSeconds
exit $LASTEXITCODE