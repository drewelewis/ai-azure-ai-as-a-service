[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $TestId,

    [Parameter(Mandatory)]
    [string] $RunPrefix,

    [Parameter(Mandatory)]
    [string] $DisplayName,

    [int] $TimeoutMinutes = 20,

    [int] $PollSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/../../scripts/_resolve-env.ps1"

function Invoke-LoadTestDataPlane {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Patch')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Path,

        [object] $Body
    )

    $accessToken = az account get-access-token `
        --subscription $SUB_ID `
        --scope 'https://cnt-prod.loadtesting.azure.com/.default' `
        --query accessToken `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Failed to acquire an Azure Load Testing token for subscription '$SUB_ID'."
    }

    $request = @{
        Method = $Method
        Uri = "https://${loadTestEndpoint}${Path}?api-version=2025-03-01-preview"
        Headers = @{ Authorization = "Bearer $accessToken" }
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.ContentType = 'application/merge-patch+json'
        $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }

    Invoke-RestMethod @request
}

$environmentName = azd env get-value AZURE_ENV_NAME 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($environmentName)) {
    Write-Error 'Cannot determine the selected azd environment.'
}

$APPGW_NAME = az network application-gateway list `
    --subscription $SUB_ID `
    --resource-group $RG `
    --query '[0].name' `
    --output tsv `
    --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($APPGW_NAME)) {
    Write-Error "No Application Gateway found in '$RG'. Run 'azd provision'."
}

$gateway = az network application-gateway show `
    --subscription $SUB_ID `
    --resource-group $RG `
    --name $APPGW_NAME `
    --query '{provisioningState:provisioningState,operationalState:operationalState}' `
    --output json `
    --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $gateway) {
    Write-Error "Failed to read Application Gateway '$APPGW_NAME'."
}

if ($gateway.provisioningState -ne 'Succeeded' -or $gateway.operationalState -ne 'Running') {
    Write-Host "Application Gateway '$APPGW_NAME' is '$($gateway.operationalState)'. Running the azd postprovision lifecycle..." -ForegroundColor Yellow
    azd hooks run postprovision --environment $environmentName
    if ($LASTEXITCODE -ne 0) {
        Write-Error "The azd postprovision lifecycle failed while starting Application Gateway '$APPGW_NAME'."
    }

    $gateway = az network application-gateway show `
        --subscription $SUB_ID `
        --resource-group $RG `
        --name $APPGW_NAME `
        --query '{provisioningState:provisioningState,operationalState:operationalState}' `
        --output json `
        --only-show-errors | ConvertFrom-Json
}

if ($LASTEXITCODE -ne 0 -or $null -eq $gateway -or $gateway.provisioningState -ne 'Succeeded' -or $gateway.operationalState -ne 'Running') {
    $observedState = if ($null -eq $gateway) { 'unavailable' } else { "provisioningState='$($gateway.provisioningState)', operationalState='$($gateway.operationalState)'" }
    Write-Error "Application Gateway '$APPGW_NAME' is not ready: $observedState."
}
Write-Host "Application Gateway '$APPGW_NAME' is Running." -ForegroundColor Green

$loadTestResourceJson = az load list `
    --subscription $SUB_ID `
    --resource-group $RG `
    --query '[0].{name:name,endpoint:dataPlaneURI}' `
    --output json `
    --only-show-errors
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($loadTestResourceJson)) {
    Write-Error "No Azure Load Testing resource found in '$RG'. Run 'azd provision'."
}
$loadTestResource = $loadTestResourceJson | ConvertFrom-Json
if ($null -eq $loadTestResource -or [string]::IsNullOrWhiteSpace($loadTestResource.name) -or [string]::IsNullOrWhiteSpace($loadTestResource.endpoint)) {
    Write-Error "Azure Load Testing resource discovery returned no name or data-plane endpoint for '$RG'."
}
$loadTestEndpoint = $loadTestResource.endpoint

try {
    $existingTest = Invoke-LoadTestDataPlane -Method Get -Path "/tests/$([uri]::EscapeDataString($TestId))"
} catch {
    Write-Error "Failed to read test definition '$TestId' from '$($loadTestResource.name)': $($_.Exception.Message)"
}
if ($existingTest.testId -ne $TestId) {
    Write-Error "Test definition '$TestId' was not found. Run 'azd provision' to reconcile load-test definitions."
}

$runId = "$RunPrefix-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Starting '$TestId' as run '$runId'..." -ForegroundColor Cyan

try {
    $runPath = "/test-runs/$([uri]::EscapeDataString($runId))"
    $result = Invoke-LoadTestDataPlane `
        -Method Patch `
        -Path $runPath `
        -Body @{ testId = $TestId; displayName = $DisplayName }
} catch {
    Write-Error "Failed to start load-test run '$runId': $($_.Exception.Message)"
}

$terminalStates = @('DONE', 'FAILED', 'CANCELLED', 'VALIDATION_FAILURE', 'SERVER_METRIC_NOT_APPLICABLE')
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$status = ''
$consecutivePollFailures = 0

do {
    Start-Sleep -Seconds $PollSeconds
    try {
        $result = Invoke-LoadTestDataPlane -Method Get -Path $runPath
        $status = [string] $result.status
    } catch {
        $consecutivePollFailures++
        Write-Warning "Failed to read load-test run '$runId' (attempt $consecutivePollFailures of 3): $($_.Exception.Message)"
        if ($consecutivePollFailures -ge 3) {
            Write-Error "Polling load-test run '$runId' failed 3 consecutive times. Last error: $($_.Exception.Message)"
        }
        continue
    }

    if ([string]::IsNullOrWhiteSpace($status)) {
        $consecutivePollFailures++
        Write-Warning "Azure returned no status for load-test run '$runId' (attempt $consecutivePollFailures of 3)."
        if ($consecutivePollFailures -ge 3) {
            Write-Error "Polling load-test run '$runId' returned no status 3 consecutive times."
        }
        continue
    }

    $consecutivePollFailures = 0
    Write-Host "  $([datetime]::UtcNow.ToString('HH:mm:ss'))Z  status: $status"
} while ($status -notin $terminalStates -and (Get-Date) -lt $deadline)

if ($status -notin $terminalStates) {
    Write-Error "Load-test run '$runId' did not finish within $TimeoutMinutes minutes. Last status: '$status'."
}

Write-Host "Run status: $($result.status)" -ForegroundColor $(if ($result.status -eq 'DONE') { 'Green' } else { 'Red' })
if ($result.PSObject.Properties['testResult']) {
    Write-Host "Test result: $($result.testResult)"
}

if ($result.status -ne 'DONE' -or ($result.PSObject.Properties['testResult'] -and $result.testResult -eq 'FAILED')) {
    exit 1
}