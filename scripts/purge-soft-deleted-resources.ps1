[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $Description
    )

    $output = & az @Arguments --output json --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed: $($output -join [Environment]::NewLine)"
    }

    return @($output | ConvertFrom-Json -Depth 100)
}

function Invoke-AzPurge {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $Description
    )

    Write-Host "Purging $Description ..."
    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to purge $Description`: $($output -join [Environment]::NewLine)"
    }
}

$environmentOutput = & azd env get-values --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "azd environment lookup failed: $($environmentOutput -join [Environment]::NewLine)"
}
$environmentValues = $environmentOutput | ConvertFrom-Json -Depth 100

$environmentName = [string]$environmentValues.AZURE_ENV_NAME
$companyPrefix = [string]$environmentValues.AZURE_COMPANY_PREFIX
$subscriptionId = [string]$environmentValues.AZURE_SUBSCRIPTION_ID

if ([string]::IsNullOrWhiteSpace($environmentName) -or
    [string]::IsNullOrWhiteSpace($companyPrefix) -or
    [string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'AZURE_ENV_NAME, AZURE_COMPANY_PREFIX, and AZURE_SUBSCRIPTION_ID are required.'
}

$resourceGroup = "rg-$companyPrefix-ai-platform-$environmentName"
$resourceGroupMarker = "/resourcegroups/$($resourceGroup.ToLowerInvariant())/"
function Test-EnvironmentResourceId {
    param([string] $ResourceId)

    return -not [string]::IsNullOrWhiteSpace($ResourceId) -and
        $ResourceId.ToLowerInvariant().Contains($resourceGroupMarker)
}

Write-Host "=== Purging soft-deleted resources for azd environment '$environmentName' ==="
Write-Host "Resource group ownership scope: $resourceGroup"
$purgeFailures = [System.Collections.Generic.List[string]]::new()

$deletedApimServices = Invoke-AzJson -Arguments @(
    'apim', 'deletedservice', 'list', '--subscription', $subscriptionId
) -Description 'APIM deleted-service inventory'
$ownedApimServices = @($deletedApimServices | Where-Object {
    Test-EnvironmentResourceId -ResourceId ([string]$_.serviceId)
})
foreach ($service in $ownedApimServices) {
    try {
        Invoke-AzPurge -Arguments @(
            'apim', 'deletedservice', 'purge',
            '--service-name', [string]$service.name,
            '--location', [string]$service.location,
            '--subscription', $subscriptionId
        ) -Description "APIM service '$($service.name)'"
    } catch {
        $purgeFailures.Add($_.Exception.Message)
    }
}

$deletedCognitiveAccounts = Invoke-AzJson -Arguments @(
    'cognitiveservices', 'account', 'list-deleted', '--subscription', $subscriptionId
) -Description 'Cognitive Services deleted-account inventory'
$ownedCognitiveAccounts = @($deletedCognitiveAccounts | Where-Object {
    Test-EnvironmentResourceId -ResourceId ([string]$_.id)
})
foreach ($account in $ownedCognitiveAccounts) {
    try {
        Invoke-AzPurge -Arguments @(
            'cognitiveservices', 'account', 'purge',
            '--name', [string]$account.name,
            '--location', [string]$account.location,
            '--resource-group', $resourceGroup,
            '--subscription', $subscriptionId
        ) -Description "Cognitive Services account '$($account.name)'"
    } catch {
        $purgeFailures.Add($_.Exception.Message)
    }
}

$deletedKeyVaults = Invoke-AzJson -Arguments @(
    'keyvault', 'list-deleted', '--subscription', $subscriptionId
) -Description 'Key Vault deleted-vault inventory'
$ownedKeyVaults = @($deletedKeyVaults | Where-Object {
    Test-EnvironmentResourceId -ResourceId ([string]$_.properties.vaultId)
})
foreach ($vault in $ownedKeyVaults) {
    try {
        Invoke-AzPurge -Arguments @(
            'keyvault', 'purge',
            '--name', [string]$vault.name,
            '--location', [string]$vault.properties.location,
            '--subscription', $subscriptionId
        ) -Description "Key Vault '$($vault.name)'"
    } catch {
        $purgeFailures.Add($_.Exception.Message)
    }
}

$remaining = @()
$remaining += @(Invoke-AzJson -Arguments @(
    'apim', 'deletedservice', 'list', '--subscription', $subscriptionId
) -Description 'APIM purge verification' | Where-Object {
    Test-EnvironmentResourceId -ResourceId ([string]$_.serviceId)
})
$remaining += @(Invoke-AzJson -Arguments @(
    'cognitiveservices', 'account', 'list-deleted', '--subscription', $subscriptionId
) -Description 'Cognitive Services purge verification' | Where-Object {
    Test-EnvironmentResourceId -ResourceId ([string]$_.id)
})
$remaining += @(Invoke-AzJson -Arguments @(
    'keyvault', 'list-deleted', '--subscription', $subscriptionId
) -Description 'Key Vault purge verification' | Where-Object {
    Test-EnvironmentResourceId -ResourceId ([string]$_.properties.vaultId)
})

if ($remaining.Count -gt 0) {
    $failureDetails = if ($purgeFailures.Count -gt 0) {
        " Azure errors: $($purgeFailures -join ' | ')"
    } else {
        ''
    }
    throw "Soft-deleted resources remain for environment '$environmentName': $(@($remaining.name) -join ', ').$failureDetails"
}

Write-Host "[OK] No soft-deleted APIM, Cognitive Services, or Key Vault resources remain for '$environmentName'."