#!/usr/bin/env pwsh

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return "$value".Trim()
}

function Test-Enabled {
    param([string]$Value)
    return $Value -match '^(?i:true|1|yes)$'
}

$failures = [System.Collections.Generic.List[string]]::new()
$passes = [System.Collections.Generic.List[string]]::new()

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FailureMessage
    )

    if ($Passed) {
        $script:passes.Add($Name)
        Write-Host "[PASS] $Name" -ForegroundColor Green
    } else {
        if ([string]::IsNullOrWhiteSpace($FailureMessage)) {
            $FailureMessage = 'Validation failed without additional details.'
        }
        $script:failures.Add("$Name`: $FailureMessage")
        Write-Host "[FAIL] $Name - $FailureMessage" -ForegroundColor Red
    }
}

$subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
$deploymentProfile = Get-AzdValue 'AZURE_DEPLOYMENT_PROFILE'
$rbacEnabled = Test-Enabled (Get-AzdValue 'AZURE_DEPLOY_RBAC')
$jumpboxEnabled = Test-Enabled (Get-AzdValue 'AZURE_DEPLOY_JUMPBOX')
$loadTestEnabled = Test-Enabled (Get-AzdValue 'AZURE_DEPLOY_LOAD_TEST')

Add-Check 'azd subscription configured' (-not [string]::IsNullOrWhiteSpace($subscriptionId)) 'AZURE_SUBSCRIPTION_ID is missing.'
Add-Check 'azd resource group configured' (-not [string]::IsNullOrWhiteSpace($resourceGroup)) 'AZURE_RESOURCE_GROUP is missing.'
Add-Check 'Deployment profile' ($deploymentProfile -in @('production', 'complete-development')) "Unknown AZURE_DEPLOYMENT_PROFILE '$deploymentProfile'."

if ($deploymentProfile -in @('production', 'complete-development')) {
    Add-Check 'Profile requires RBAC' $rbacEnabled "Profile '$deploymentProfile' requires AZURE_DEPLOY_RBAC=true."
    $developmentToolsExpected = $deploymentProfile -eq 'complete-development'
    Add-Check 'Profile jumpbox selection' ($jumpboxEnabled -eq $developmentToolsExpected) "Profile '$deploymentProfile' requires AZURE_DEPLOY_JUMPBOX=$($developmentToolsExpected.ToString().ToLowerInvariant())."
    Add-Check 'Profile load-test selection' ($loadTestEnabled -eq $developmentToolsExpected) "Profile '$deploymentProfile' requires AZURE_DEPLOY_LOAD_TEST=$($developmentToolsExpected.ToString().ToLowerInvariant())."
}

if ($failures.Count -gt 0) {
    throw "Deployment validation cannot continue because required azd values are missing."
}

$groupState = az group show --name $resourceGroup --query properties.provisioningState -o tsv 2>$null
Add-Check 'Resource group' ($groupState -eq 'Succeeded') "Resource group '$resourceGroup' is missing or unhealthy."

$apim = az apim list --resource-group $resourceGroup --query '[0].{name:name,state:provisioningState,principalId:identity.principalId}' -o json 2>$null | ConvertFrom-Json
Add-Check 'APIM gateway' ($null -ne $apim -and $apim.state -eq 'Succeeded' -and -not [string]::IsNullOrWhiteSpace($apim.principalId)) 'Expected one healthy APIM service with a managed identity.'

$subscriptionCatalogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'infrastructure/subscriptions/catalog.json'
$subscriptionCatalog = @(Get-Content $subscriptionCatalogPath -Raw | ConvertFrom-Json -Depth 20)
$catalogIds = @($subscriptionCatalog.id)
$catalogValid = $subscriptionCatalog.Count -gt 0 -and
    @($catalogIds | Sort-Object -Unique).Count -eq $catalogIds.Count -and
    @($subscriptionCatalog | Where-Object { $_.productId -notin @('bronze', 'silver', 'gold') }).Count -eq 0 -and
    @($subscriptionCatalog | Where-Object { [string]::IsNullOrWhiteSpace($_.id) -or [string]::IsNullOrWhiteSpace($_.displayName) }).Count -eq 0
Add-Check 'APIM subscription catalog' $catalogValid 'Catalog IDs must be unique and every entry must have a display name and a bronze, silver, or gold product ID.'

if ($apim) {
    $deployedSubscriptions = @((az rest --method GET `
        --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$($apim.name)/subscriptions?api-version=2023-05-01-preview" `
        --query 'value[].{id:name,scope:properties.scope,state:properties.state}' -o json 2>$null | ConvertFrom-Json))
    $expectedSubscriptions = @($subscriptionCatalog | Where-Object enabled)
    $subscriptionMismatches = [System.Collections.Generic.List[string]]::new()

    foreach ($expected in $expectedSubscriptions) {
        $actual = $deployedSubscriptions | Where-Object id -eq $expected.id | Select-Object -First 1
        $expectedScopeSuffix = "/products/$($expected.productId)"
        if (-not $actual) {
            $subscriptionMismatches.Add("$($expected.id) is missing")
        } elseif ($actual.state -ne 'active') {
            $subscriptionMismatches.Add("$($expected.id) is '$($actual.state)'")
        } elseif (-not $actual.scope.EndsWith($expectedScopeSuffix, [StringComparison]::OrdinalIgnoreCase)) {
            $subscriptionMismatches.Add("$($expected.id) is not scoped to $($expected.productId)")
        }
    }

    foreach ($retiredId in @('test-bronze', 'test-silver', 'test-silver-2', 'test-gold')) {
        if ($deployedSubscriptions | Where-Object id -eq $retiredId) {
            $subscriptionMismatches.Add("retired subscription $retiredId still exists")
        }
    }

    Add-Check 'APIM catalog subscriptions' ($subscriptionMismatches.Count -eq 0) ($subscriptionMismatches -join '; ')
}

$foundryAccounts = @(az cognitiveservices account list --resource-group $resourceGroup --query "[?kind=='AIServices'].{name:name,state:properties.provisioningState}" -o json 2>$null | ConvertFrom-Json)
Add-Check 'Foundry accounts' ($foundryAccounts.Count -eq 2 -and @($foundryAccounts | Where-Object state -ne 'Succeeded').Count -eq 0) "Expected two healthy AIServices accounts; found $($foundryAccounts.Count)."

$portfolioPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'infrastructure/model-portfolio.json'
$modelPortfolio = @(Get-Content $portfolioPath -Raw | ConvertFrom-Json -Depth 20)
$requiredDeployments = @($modelPortfolio.deploymentName)
$portfolioValid = $modelPortfolio.Count -ge 5 -and
    @($requiredDeployments | Sort-Object -Unique).Count -eq $requiredDeployments.Count -and
    @($modelPortfolio | Where-Object capability -eq 'chat').Count -ge 3 -and
    @($modelPortfolio | Where-Object capability -eq 'embedding').Count -ge 1
Add-Check 'Model portfolio breadth' $portfolioValid 'Expected at least five unique deployments with three chat and one embedding model.'
foreach ($account in $foundryAccounts) {
    $deployments = @(az cognitiveservices account deployment list --resource-group $resourceGroup --name $account.name --query '[].name' -o json 2>$null | ConvertFrom-Json)
    $missingDeployments = @($requiredDeployments | Where-Object { $_ -notin $deployments })
    Add-Check "Foundry deployments on $($account.name)" ($missingDeployments.Count -eq 0) "Missing deployments: $($missingDeployments -join ', ')."
}

$privateEndpoints = @(az network private-endpoint list --resource-group $resourceGroup --query "[?provisioningState=='Succeeded'].name" -o json 2>$null | ConvertFrom-Json)
Add-Check 'Foundry private endpoints' ($privateEndpoints.Count -ge 2) "Expected at least two healthy private endpoints; found $($privateEndpoints.Count)."

$keyVaultName = Get-AzdValue 'KEY_VAULT_NAME'
$keyVaultId = az keyvault show --resource-group $resourceGroup --name $keyVaultName --query id -o tsv 2>$null
$certificateContentType = if ($keyVaultId) {
    az resource show --ids "$keyVaultId/secrets/appgw-ssl-cert" --api-version 2023-07-01 --query properties.contentType -o tsv 2>$null
} else { '' }
Add-Check 'Application Gateway TLS certificate' ($certificateContentType -eq 'application/x-pkcs12') "PKCS#12 secret 'appgw-ssl-cert' is unavailable in Key Vault '$keyVaultName'."

$appGateway = @(az network application-gateway list --resource-group $resourceGroup -o json --only-show-errors | ConvertFrom-Json -Depth 100) | Select-Object -First 1
$appGatewayFailure = if ($null -eq $appGateway) {
    "No Application Gateway was found in resource group '$resourceGroup'."
} else {
    "Application Gateway '$($appGateway.name)' has provisioningState='$($appGateway.provisioningState)' and operationalState='$($appGateway.operationalState)'."
}
Add-Check 'Application Gateway' ($null -ne $appGateway -and $appGateway.provisioningState -eq 'Succeeded' -and $appGateway.operationalState -eq 'Running') $appGatewayFailure

$appGatewayFqdn = az network public-ip list --resource-group $resourceGroup --query "[?contains(name,'agw')].dnsSettings.fqdn | [0]" -o tsv 2>$null
Add-Check 'Application Gateway public endpoint' (-not [string]::IsNullOrWhiteSpace($appGatewayFqdn)) 'Application Gateway public FQDN is missing.'

$appGatewayIdentityId = if ($appGateway) { @($appGateway.identity.userAssignedIdentities.PSObject.Properties.Name) | Select-Object -First 1 } else { '' }
$appGatewayIdentityName = if ($appGatewayIdentityId) { ($appGatewayIdentityId -split '/')[-1] } else { '' }
$appGatewayPrincipalId = if ($appGatewayIdentityName) { az identity show --resource-group $resourceGroup --name $appGatewayIdentityName --query principalId -o tsv 2>$null } else { '' }
Add-Check 'Application Gateway managed identity' (-not [string]::IsNullOrWhiteSpace($appGatewayPrincipalId)) 'Application Gateway user-assigned identity is missing.'

$certificateRole = if ($appGatewayPrincipalId -and $keyVaultId) {
    az role assignment list --scope $keyVaultId --assignee $appGatewayPrincipalId --role 'Key Vault Certificate User' --query '[0].id' -o tsv 2>$null
} else { '' }
Add-Check 'Application Gateway certificate RBAC' (-not [string]::IsNullOrWhiteSpace($certificateRole)) 'Key Vault Certificate User is not assigned to the gateway identity.'

$cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
$foundryRoleCount = if ($apim -and $apim.principalId) {
    @(
        az role assignment list --assignee-object-id $apim.principalId --all -o json --only-show-errors |
            ConvertFrom-Json -Depth 100 |
            Where-Object { $_.roleDefinitionId.EndsWith("/$cognitiveServicesUserRoleId", [StringComparison]::OrdinalIgnoreCase) }
    ).Count
} else { '0' }
Add-Check 'APIM to Foundry RBAC' ([int]($foundryRoleCount ?? 0) -ge 2) "Expected Cognitive Services User on both Foundry accounts; found $foundryRoleCount assignments."

if ($jumpboxEnabled) {
    $jumpboxCount = @(az container list --resource-group $resourceGroup -o json --only-show-errors | ConvertFrom-Json -Depth 100).Count
    Add-Check 'ACI jumpbox' ([int]($jumpboxCount ?? 0) -ge 1) 'No ACI jumpbox was found.'
}

if ($loadTestEnabled) {
    $loadTestName = az load list --resource-group $resourceGroup --query '[0].name' -o tsv 2>$null
    Add-Check 'Azure Load Testing resource' (-not [string]::IsNullOrWhiteSpace($loadTestName)) 'Azure Load Testing resource is missing.'

    $expectedTestIds = @(
        'apim-smoke-test'
        'appgw-failover-test'
        'appgw-smoke-test'
        'multi-sub-failover-test'
        'steady-state-test'
    )
    $configuredTestIds = if ($loadTestName) {
        @(az load test list --load-test-resource $loadTestName --resource-group $resourceGroup --query '[].testId' -o json 2>$null | ConvertFrom-Json)
    } else { @() }
    $missingTestIds = @($expectedTestIds | Where-Object { $_ -notin $configuredTestIds })
    Add-Check 'Azure Load Testing definitions' ($missingTestIds.Count -eq 0) "Missing test definitions: $($missingTestIds -join ', ')."

    $expectedLoadTestSubnetId = Get-AzdValue 'LOAD_TEST_SUBNET_ID'
    $subnetMismatches = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($expectedLoadTestSubnetId)) {
        $subnetMismatches.Add('LOAD_TEST_SUBNET_ID is missing')
    } elseif ($loadTestName) {
        foreach ($testId in $expectedTestIds) {
            if ($testId -notin $configuredTestIds) { continue }
            $actualSubnetId = az load test show `
                --load-test-resource $loadTestName `
                --resource-group $resourceGroup `
                --test-id $testId `
                --query subnetId -o tsv 2>$null
            if (-not $actualSubnetId -or -not $actualSubnetId.Equals($expectedLoadTestSubnetId, [StringComparison]::OrdinalIgnoreCase)) {
                $subnetMismatches.Add("$testId reports '$actualSubnetId'")
            }
        }
    }
    Add-Check 'Azure Load Testing private subnet' ($subnetMismatches.Count -eq 0) "Expected every test in '$expectedLoadTestSubnetId'; mismatches: $($subnetMismatches -join '; ')."
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "Deployment validation failed with $($failures.Count) issue(s):" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Deployment profile '$deploymentProfile' validation passed ($($passes.Count) checks)." -ForegroundColor Green