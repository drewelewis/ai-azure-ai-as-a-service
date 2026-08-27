[CmdletBinding()]
param(
    [hashtable]$EnvironmentOverrides = @{}
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$requiredProviders = @(
    'Microsoft.ApiManagement'
    'Microsoft.Authorization'
    'Microsoft.Batch'
    'Microsoft.CognitiveServices'
    'Microsoft.ContainerInstance'
    'Microsoft.Insights'
    'Microsoft.KeyVault'
    'Microsoft.LoadTestService'
    'Microsoft.ManagedIdentity'
    'Microsoft.Network'
    'Microsoft.OperationalInsights'
    'Microsoft.Resources'
    'Microsoft.Storage'
)

function Invoke-JsonCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $output = & $Executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed: $($output -join [Environment]::NewLine)"
    }

    try {
        return $output | ConvertFrom-Json -Depth 100
    } catch {
        throw "$Description returned invalid JSON."
    }
}

function Test-Enabled {
    param([Parameter(Mandatory)][object]$Value)
    return [System.Convert]::ToBoolean($Value)
}

function Test-RegionSupport {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string]$Region
    )

    $metadata = Invoke-JsonCommand -Executable 'az' -Arguments @(
        'provider', 'show', '--namespace', $Provider,
        '--query', 'resourceTypes',
        '--output', 'json', '--only-show-errors'
    ) -Description "$Provider/$ResourceType regional availability lookup"

    $metadata = @($metadata) | Where-Object {
        $_.resourceType -eq $ResourceType
    } | Select-Object -First 1

    if (-not $metadata) {
        throw "$Provider/$ResourceType is not available from the active subscription."
    }

    $normalizedRegion = $Region.Replace(' ', '').ToLowerInvariant()
    $supported = @($metadata.locations) | Where-Object {
        $_.Replace(' ', '').ToLowerInvariant() -eq $normalizedRegion
    }
    if (-not $supported) {
        throw "$Provider/$ResourceType is not advertised in region '$Region'."
    }
}

function Test-ModelCatalog {
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][object[]]$Portfolio,
        [Parameter(Mandatory)][ValidateSet('primaryCapacity', 'secondaryCapacity')][string]$CapacityProperty,
        [object[]]$ExistingDeployments = @()
    )

    $models = @(Invoke-JsonCommand -Executable 'az' -Arguments @(
        'cognitiveservices', 'model', 'list', '--location', $Region,
        '--output', 'json', '--only-show-errors'
    ) -Description "Foundry model catalog lookup for $Region")

    $usage = @(Invoke-JsonCommand -Executable 'az' -Arguments @(
        'cognitiveservices', 'usage', 'list', '--location', $Region,
        '--output', 'json', '--only-show-errors'
    ) -Description "Cognitive Services quota lookup for $Region")

    foreach ($requirement in $Portfolio) {
        $match = $models | Where-Object {
            $_.model.name -eq $requirement.modelName -and
            $_.model.version -eq $requirement.version -and
            $_.model.lifecycleStatus -notin @('Deprecating', 'Deprecated') -and
            @($_.model.skus.name) -contains $requirement.skuName
        } | Select-Object -First 1
        if (-not $match) {
            throw "Portfolio model '$($requirement.modelName)' version '$($requirement.version)' with SKU '$($requirement.skuName)' is unavailable or closed to new deployments in '$Region'."
        }

        $sku = $match.model.skus | Where-Object { $_.name -eq $requirement.skuName } | Select-Object -First 1
        $quota = $usage | Where-Object { $_.name.value -eq $sku.usageName } | Select-Object -First 1
        if (-not $quota) {
            throw "Quota '$($sku.usageName)' for portfolio model '$($requirement.modelName)' was not reported in '$Region'."
        }

        $existing = @($ExistingDeployments) | Where-Object {
            $_ -and $_.PSObject.Properties['name'] -and
            $_.PSObject.Properties['properties'] -and $_.properties.PSObject.Properties['model'] -and
            $_.PSObject.Properties['sku'] -and
            $_.name -eq $requirement.deploymentName -and
            $_.properties.model.name -eq $requirement.modelName -and
            $_.properties.model.version -eq $requirement.version -and
            $_.sku.name -eq $requirement.skuName
        } | Select-Object -First 1
        $existingCapacity = if ($existing) { [decimal]$existing.sku.capacity } else { 0 }
        $requiredCapacity = [decimal]$requirement.$CapacityProperty
        $incrementalCapacity = [Math]::Max(0, $requiredCapacity - $existingCapacity)
        $headroom = [decimal]$quota.limit - [decimal]$quota.currentValue
        if ($headroom -lt $incrementalCapacity) {
            throw "Portfolio model '$($requirement.modelName)' SKU '$($requirement.skuName)' in '$Region' requires $incrementalCapacity additional capacity but only $headroom remains ($($quota.currentValue)/$($quota.limit) used)."
        }
    }
}

function Get-ExistingDeployments {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Region
    )

    $groupExists = & az group exists --name $ResourceGroup --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or $groupExists -ne 'true') {
        return @()
    }

    $accounts = @(Invoke-JsonCommand -Executable 'az' -Arguments @(
        'cognitiveservices', 'account', 'list', '--resource-group', $ResourceGroup,
        '--output', 'json', '--only-show-errors'
    ) -Description "Foundry account lookup in $ResourceGroup")
    $account = $accounts | Where-Object {
        $_.kind -eq 'AIServices' -and $_.location.Replace(' ', '').ToLowerInvariant() -eq $Region.Replace(' ', '').ToLowerInvariant()
    } | Select-Object -First 1
    if (-not $account) {
        return @()
    }

    return @(Invoke-JsonCommand -Executable 'az' -Arguments @(
        'cognitiveservices', 'account', 'deployment', 'list',
        '--name', $account.name, '--resource-group', $ResourceGroup,
        '--output', 'json', '--only-show-errors'
    ) -Description "existing Foundry deployment lookup for $Region")
}

Write-Host '=== Azure AI as a Service deployment preflight ==='

foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' is not installed or is not on PATH."
    }
}

$environmentValues = Invoke-JsonCommand -Executable 'azd' -Arguments @(
    'env', 'get-values', '--output', 'json'
) -Description 'azd environment lookup'
foreach ($entry in $EnvironmentOverrides.GetEnumerator()) {
    $environmentValues | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    $property = $environmentValues.PSObject.Properties[$Name]
    if (-not $property) {
        return $Default
    }
    return [string]$property.Value
}

$requiredValues = @(
    'AZURE_SUBSCRIPTION_ID'
    'AZURE_TENANT_ID'
    'AZURE_ENV_NAME'
    'AZURE_LOCATION'
    'AZURE_SECONDARY_LOCATION'
    'AZURE_COMPANY_PREFIX'
    'AZURE_DEPLOYMENT_PROFILE'
    'AZURE_DEPLOY_RBAC'
    'AZURE_DEPLOY_JUMPBOX'
    'AZURE_DEPLOY_LOAD_TEST'
    'AZURE_DEPLOYING_USER_OBJECT_ID'
)

$missingValues = $requiredValues | Where-Object {
    -not $environmentValues.PSObject.Properties[$_] -or
    [string]::IsNullOrWhiteSpace([string]$environmentValues.$_)
}
if ($missingValues) {
    throw "Required azd environment values are missing: $($missingValues -join ', ')."
}

$deploymentProfile = [string]$environmentValues.AZURE_DEPLOYMENT_PROFILE
if ($deploymentProfile -notin @('production', 'complete-development')) {
    throw "AZURE_DEPLOYMENT_PROFILE must be 'production' or 'complete-development'; received '$deploymentProfile'."
}

foreach ($flag in @(
    'AZURE_DEPLOY_RBAC',
    'AZURE_DEPLOY_JUMPBOX',
    'AZURE_DEPLOY_LOAD_TEST'
)) {
    $parsedFlag = $false
    if (-not [bool]::TryParse([string]$environmentValues.$flag, [ref]$parsedFlag)) {
        throw "azd environment value '$flag' must be 'true' or 'false'."
    }
}

$profileRequirements = @{
    AZURE_DEPLOY_RBAC = $true
    AZURE_DEPLOY_JUMPBOX = $deploymentProfile -eq 'complete-development'
    AZURE_DEPLOY_LOAD_TEST = $deploymentProfile -eq 'complete-development'
}
foreach ($requirement in $profileRequirements.GetEnumerator()) {
    $actual = Test-Enabled $environmentValues.($requirement.Key)
    if ($actual -ne $requirement.Value) {
        throw "Profile '$deploymentProfile' requires $($requirement.Key)=$($requirement.Value.ToString().ToLowerInvariant()); received $($actual.ToString().ToLowerInvariant())."
    }
}
Write-Host "[OK] Deployment profile '$deploymentProfile' is internally consistent."

$account = Invoke-JsonCommand -Executable 'az' -Arguments @(
    'account', 'show', '--output', 'json', '--only-show-errors'
) -Description 'Azure CLI account lookup'
if (-not $account.state -or $account.state -ne 'Enabled') {
    throw 'The active Azure CLI subscription is not enabled.'
}
if ($account.id -ne $environmentValues.AZURE_SUBSCRIPTION_ID) {
    throw "Azure CLI subscription '$($account.id)' does not match azd subscription '$($environmentValues.AZURE_SUBSCRIPTION_ID)'."
}
if ($account.tenantId -ne $environmentValues.AZURE_TENANT_ID) {
    throw "Azure CLI tenant '$($account.tenantId)' does not match azd tenant '$($environmentValues.AZURE_TENANT_ID)'."
}
Write-Host "[OK] Azure account: $($account.name) ($($account.id))"

$providerStates = Invoke-JsonCommand -Executable 'az' -Arguments @(
    'provider', 'list', '--query', '[].{namespace:namespace,state:registrationState}',
    '--output', 'json', '--only-show-errors'
) -Description 'resource provider registration lookup'
$unregisteredProviders = $requiredProviders | Where-Object {
    $provider = $_
    -not ($providerStates | Where-Object { $_.namespace -eq $provider -and $_.state -eq 'Registered' })
}
if ($unregisteredProviders) {
    throw "Required resource providers are not registered: $($unregisteredProviders -join ', ')."
}
Write-Host "[OK] $($requiredProviders.Count) required resource providers are registered."

$primaryRegion = [string]$environmentValues.AZURE_LOCATION
$secondaryRegion = [string]$environmentValues.AZURE_SECONDARY_LOCATION
$regionalResources = @(
    @{ Provider = 'Microsoft.ApiManagement'; Type = 'service'; Region = $primaryRegion }
    @{ Provider = 'Microsoft.CognitiveServices'; Type = 'accounts'; Region = $primaryRegion }
    @{ Provider = 'Microsoft.CognitiveServices'; Type = 'accounts'; Region = $secondaryRegion }
    @{ Provider = 'Microsoft.Network'; Type = 'applicationGateways'; Region = $primaryRegion }
)
if (Test-Enabled $environmentValues.AZURE_DEPLOY_JUMPBOX) {
    $regionalResources += @{ Provider = 'Microsoft.ContainerInstance'; Type = 'containerGroups'; Region = $primaryRegion }
}
if (Test-Enabled $environmentValues.AZURE_DEPLOY_LOAD_TEST) {
    $regionalResources += @{ Provider = 'Microsoft.LoadTestService'; Type = 'loadTests'; Region = $primaryRegion }
}

foreach ($resource in $regionalResources) {
    Test-RegionSupport -Provider $resource.Provider -ResourceType $resource.Type -Region $resource.Region
}
Write-Host '[OK] Selected regions advertise all enabled resource types.'

$subscriptionCatalogPath = Join-Path $repoRoot 'infrastructure/subscriptions/catalog.json'
$subscriptionCatalog = @(Get-Content $subscriptionCatalogPath -Raw | ConvertFrom-Json -Depth 20)
$subscriptionIds = @($subscriptionCatalog.id)
if (@($subscriptionIds | Sort-Object -Unique).Count -ne $subscriptionIds.Count) {
    throw 'The APIM subscription catalog contains duplicate IDs.'
}
$subscriptionsByLineOfBusiness = @($subscriptionCatalog | Where-Object enabled | Group-Object lineOfBusiness)
if ($subscriptionsByLineOfBusiness.Count -ne 4 -or @($subscriptionsByLineOfBusiness | Where-Object Count -ne 2).Count -gt 0) {
    throw 'The APIM subscription catalog must contain exactly four LOBs with two enabled subscriptions each.'
}
foreach ($subscription in $subscriptionCatalog) {
    $requiredFields = @('id', 'displayName', 'productId', 'lineOfBusiness', 'useCase', 'enabled')
    $missingFields = @($requiredFields | Where-Object { -not $subscription.PSObject.Properties[$_] })
    if ($missingFields.Count -gt 0) {
        throw "APIM subscription '$($subscription.id)' is missing fields: $($missingFields -join ', ')."
    }
    if ($subscription.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "APIM subscription ID '$($subscription.id)' must use lowercase kebab-case."
    }
    if ([string]::IsNullOrWhiteSpace($subscription.displayName) -or
        [string]::IsNullOrWhiteSpace($subscription.lineOfBusiness) -or
        [string]::IsNullOrWhiteSpace($subscription.useCase)) {
        throw "APIM subscription '$($subscription.id)' has empty onboarding metadata."
    }
    if ($subscription.productId -notin @('bronze', 'silver', 'gold')) {
        throw "APIM subscription '$($subscription.id)' has unsupported product '$($subscription.productId)'."
    }
}
$requiredLobSubscriptionIds = @(
    'consumer-customer-service',
    'consumer-account-opening',
    'commercial-relationship-manager',
    'commercial-credit-memo',
    'cib-deal-research',
    'cib-due-diligence',
    'wealth-advisor-copilot',
    'wealth-portfolio-commentary'
)
$missingLobSubscriptionIds = @($requiredLobSubscriptionIds | Where-Object {
    $requiredId = $_
    -not ($subscriptionCatalog | Where-Object { $_.id -eq $requiredId -and $_.enabled })
})
if ($subscriptionCatalog.Count -ne 8 -or $missingLobSubscriptionIds.Count -gt 0) {
    throw "The APIM subscription catalog must contain exactly the eight required enabled LOB subscriptions. Missing: $($missingLobSubscriptionIds -join ', ')."
}
$tierCounts = @{
    bronze = @($subscriptionCatalog | Where-Object productId -eq 'bronze').Count
    silver = @($subscriptionCatalog | Where-Object productId -eq 'silver').Count
    gold = @($subscriptionCatalog | Where-Object productId -eq 'gold').Count
}
if ($tierCounts.bronze -eq 0 -or $tierCounts.silver -eq 0 -or $tierCounts.gold -eq 0) {
    throw 'The APIM subscription catalog must exercise bronze, silver, and gold products.'
}
Write-Host "[OK] APIM subscription catalog contains 8 LOB entries across Bronze ($($tierCounts.bronze)), Silver ($($tierCounts.silver)), and Gold ($($tierCounts.gold))."

$portfolioPath = Join-Path $repoRoot 'infrastructure/model-portfolio.json'
$modelPortfolio = @(Get-Content $portfolioPath -Raw | ConvertFrom-Json -Depth 20)
$deploymentNames = @($modelPortfolio.deploymentName)
if ($modelPortfolio.Count -lt 5) {
    throw "The model portfolio must contain at least five deployments; found $($modelPortfolio.Count)."
}
if (@($deploymentNames | Sort-Object -Unique).Count -ne $deploymentNames.Count) {
    throw 'The model portfolio contains duplicate deployment names.'
}
foreach ($model in $modelPortfolio) {
    $requiredFields = @('deploymentName', 'format', 'modelName', 'version', 'skuName', 'primaryCapacity', 'secondaryCapacity', 'capability', 'tiers')
    $missingFields = @($requiredFields | Where-Object { -not $model.PSObject.Properties[$_] })
    if ($missingFields.Count -gt 0) {
        throw "Portfolio deployment '$($model.deploymentName)' is missing fields: $($missingFields -join ', ')."
    }
    if ($model.capability -notin @('chat', 'embedding')) {
        throw "Portfolio deployment '$($model.deploymentName)' has unsupported capability '$($model.capability)'."
    }
    if ([decimal]$model.primaryCapacity -le 0 -or [decimal]$model.secondaryCapacity -le 0) {
        throw "Portfolio deployment '$($model.deploymentName)' must have positive regional capacities."
    }
    $invalidTiers = @($model.tiers | Where-Object { $_ -notin @('bronze', 'silver', 'gold') })
    if ($model.tiers.Count -eq 0 -or $invalidTiers.Count -gt 0 -or 'gold' -notin $model.tiers) {
        throw "Portfolio deployment '$($model.deploymentName)' must include Gold and use only bronze, silver, and gold tiers."
    }
}
if (@($modelPortfolio | Where-Object capability -eq 'chat').Count -lt 3) {
    throw 'The model portfolio must contain at least three chat deployments.'
}
if (@($modelPortfolio | Where-Object capability -eq 'embedding').Count -lt 1) {
    throw 'The model portfolio must contain at least one embedding deployment.'
}
if ('gpt-4o-mini' -notin $deploymentNames) {
    throw "The model portfolio must preserve the stable 'gpt-4o-mini' routing alias used by smoke and failover tests."
}
Write-Host "[OK] Model portfolio contains $($modelPortfolio.Count) deployments with chat and embedding coverage."

$resourceGroup = "rg-$($environmentValues.AZURE_COMPANY_PREFIX)-ai-platform-$($environmentValues.AZURE_ENV_NAME)"
$primaryDeployments = Get-ExistingDeployments -ResourceGroup $resourceGroup -Region $primaryRegion
$secondaryDeployments = Get-ExistingDeployments -ResourceGroup $resourceGroup -Region $secondaryRegion
Test-ModelCatalog -Region $primaryRegion -Portfolio $modelPortfolio -CapacityProperty primaryCapacity -ExistingDeployments $primaryDeployments
Test-ModelCatalog -Region $secondaryRegion -Portfolio $modelPortfolio -CapacityProperty secondaryCapacity -ExistingDeployments $secondaryDeployments
Write-Host '[OK] Selected model portfolio and quota headroom are available in both regions.'

$policyAssignments = @(Invoke-JsonCommand -Executable 'az' -Arguments @(
    'policy', 'assignment', 'list', '--disable-scope-strict-match',
    '--output', 'json', '--only-show-errors'
) -Description 'Azure Policy assignment lookup')
Write-Host "[INFO] ARM validation will evaluate $($policyAssignments.Count) visible policy assignments."

$parameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        location = @{ value = $primaryRegion }
        secondaryLocation = @{ value = $secondaryRegion }
        environment = @{ value = [string]$environmentValues.AZURE_ENV_NAME }
        companyPrefix = @{ value = [string]$environmentValues.AZURE_COMPANY_PREFIX }
        deployRbac = @{ value = Test-Enabled $environmentValues.AZURE_DEPLOY_RBAC }
        deployJumpbox = @{ value = Test-Enabled $environmentValues.AZURE_DEPLOY_JUMPBOX }
        deployLoadTest = @{ value = Test-Enabled $environmentValues.AZURE_DEPLOY_LOAD_TEST }
        deployingUserObjectId = @{ value = [string]$environmentValues.AZURE_DEPLOYING_USER_OBJECT_ID }
        sslCertKeyVaultSecretId = @{ value = Get-EnvironmentValue -Name 'AZURE_SSL_CERT_KV_SECRET_ID' }
        generatedSslCertificatePfx = @{ value = Get-EnvironmentValue -Name 'AZURE_SSL_CERT_PFX_BASE64' }
    }
}

$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "ai-aas-preflight-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempDirectory | Out-Null
try {
    $templatePath = Join-Path $tempDirectory 'main.json'
    $parameterPath = Join-Path $tempDirectory 'main.parameters.json'
    $parameters | ConvertTo-Json -Depth 20 | Set-Content -Path $parameterPath -Encoding utf8NoBOM

    & az bicep build --file (Join-Path $repoRoot 'infrastructure/bicep/main.bicep') --outfile $templatePath
    if ($LASTEXITCODE -ne 0) {
        throw 'Bicep compilation failed during preflight.'
    }

    $validationOutput = & az deployment sub validate `
        --name "preflight-$($environmentValues.AZURE_ENV_NAME)" `
        --location $primaryRegion `
        --template-file $templatePath `
        --parameters "@$parameterPath" `
        --validation-level Provider `
        --no-prompt true `
        --only-show-errors `
        --output none 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ARM provider validation failed. This includes effective permissions, resource constraints, and deny policies: $($validationOutput -join [Environment]::NewLine)"
    }
} finally {
    Remove-Item -Path $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '[OK] ARM provider validation passed for permissions, resource constraints, and Azure Policy.'
Write-Host '=== Preflight passed ==='