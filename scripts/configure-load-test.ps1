# configure-load-test.ps1
#
# azd postprovision hook — creates ALL Azure Load Testing test definitions.
#
# Runs automatically for the complete-development profile. Can also be run
# manually: pwsh scripts/configure-load-test.ps1
#
# Creates / updates all 5 load test definitions:
#   apim-smoke-test         load_tests/definitions/apim-load-test.jmx     consumer-customer-service + consumer-account-opening (direct APIM)
#   appgw-failover-test     load_tests/definitions/failover-load-test.jmx consumer-account-opening (circuit-state routing)
#   appgw-smoke-test        load_tests/definitions/appgw-load-test.jmx    consumer-customer-service + consumer-account-opening (WAF overhead)
#   multi-sub-failover-test load_tests/definitions/multi-sub-failover-test.jmx all eight LOB use-case subscriptions
#   steady-state-test       load_tests/definitions/steady-state-test.jmx       all eight LOB use-case subscriptions
#
# Prerequisites:
#   azd provision   ← must run first (creates ALT resource, APIM, App Gateway)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testDisplayNames = [ordered]@{
    'apim-smoke-test' = 'APIM Smoke Test (direct VNet baseline)'
    'appgw-failover-test' = 'AppGW Failover Blast - primary to secondary retry'
    'appgw-smoke-test' = 'AppGW WAF v2 Smoke Test'
    'multi-sub-failover-test' = 'Multi-Subscription Failover: Bronze/Silver/Gold'
    'steady-state-test' = 'Steady State: All LOB Use Cases (1h)'
}

foreach ($testDisplayName in $testDisplayNames.GetEnumerator()) {
    if ($testDisplayName.Value.Length -lt 2 -or $testDisplayName.Value.Length -gt 50) {
        throw "Azure Load Testing display name for '$($testDisplayName.Key)' must contain 2-50 characters; received $($testDisplayName.Value.Length)."
    }
}

$loadTestEnabled = azd env get-value AZURE_DEPLOY_LOAD_TEST 2>$null
if ($loadTestEnabled -notmatch '^(?i:true|1|yes)$') {
    Write-Host 'Azure Load Testing is disabled for the selected deployment profile; skipping test definition configuration.'
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Resolve environment
# ---------------------------------------------------------------------------
. "$PSScriptRoot/_resolve-env.ps1"

if (-not $APIM_NAME) {
    Write-Error "No APIM instance found in '$RG'. Ensure 'azd provision' completed successfully."
}
if (-not $APPGW_FQDN) {
    Write-Error "APPGW_FQDN is empty. Azure Load Testing requires the declared Application Gateway endpoint."
}

# Internal APIM hostname — used only by apim-smoke-test (direct VNet baseline, no App Gateway).
# All other tests target $APPGW_FQDN (App Gateway → APIM → Foundry).
$apimHostname = "$APIM_NAME.azure-api.net"

# Locate the ALT resource in this resource group
$ALT_RESOURCE = az load list -g $RG --query '[0].name' -o tsv 2>$null
if (-not $ALT_RESOURCE) {
    Write-Error "No Azure Load Testing resource found in '$RG'. Re-run 'azd provision' to create it."
}

# VNet injection is configured per test definition, not on the Load Testing resource.
# main.bicep exports the dedicated subnet ID through the selected azd environment.
$subnetId = _Resolve-AzdEnv 'LOAD_TEST_SUBNET_ID'
if (-not $subnetId) {
    throw 'LOAD_TEST_SUBNET_ID is missing. Re-run azd provision so private load tests cannot be created without VNet injection.'
}

$testsDir = Join-Path $PSScriptRoot '..' 'load_tests'
$configDir = Join-Path $testsDir 'config'
$definitionsDir = Join-Path $testsDir 'definitions'
$tempDir  = $env:TEMP

Write-Host ""
Write-Host "ALT resource : $ALT_RESOURCE"
Write-Host "APIM         : $APIM_NAME  (internal: $apimHostname)"
Write-Host "AppGW FQDN   : $APPGW_FQDN"
Write-Host "Subnet ID    : $subnetId"
Write-Host ""

# ---------------------------------------------------------------------------
# 2. Install az load extension if not present
# ---------------------------------------------------------------------------
Write-Host "Checking az load extension..."
$ext = az extension list --query "[?name=='load'].name" -o tsv 2>$null
if ($ext -ne 'load') {
    Write-Host "  Installing az load extension..."
    az extension add --name load --yes
}

# ---------------------------------------------------------------------------
# 3. Fetch APIM LOB subscription keys
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Fetching APIM subscription keys ===" -ForegroundColor Cyan

function Get-ApimKey([string]$subId) {
    $key = az rest --method POST `
        --uri "https://management.azure.com/subscriptions/$SUB_ID/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/$subId/listSecrets?api-version=2022-08-01" `
        --query primaryKey -o tsv 2>$null
    if (-not $key) {
        Write-Warning "  Could not fetch key for subscription '$subId' — it will be empty in the test."
    }
    return $key
}

$consumerCustomerServiceKey = Get-ApimKey 'consumer-customer-service'
$consumerAccountOpeningKey = Get-ApimKey 'consumer-account-opening'
$commercialRelationshipManagerKey = Get-ApimKey 'commercial-relationship-manager'
$commercialCreditMemoKey = Get-ApimKey 'commercial-credit-memo'
$cibDealResearchKey = Get-ApimKey 'cib-deal-research'
$cibDueDiligenceKey = Get-ApimKey 'cib-due-diligence'
$wealthAdvisorCopilotKey = Get-ApimKey 'wealth-advisor-copilot'
$wealthPortfolioCommentaryKey = Get-ApimKey 'wealth-portfolio-commentary'

$subscriptionKeys = [ordered]@{
    CONSUMER_CUSTOMER_SERVICE_KEY = $consumerCustomerServiceKey
    CONSUMER_ACCOUNT_OPENING_KEY = $consumerAccountOpeningKey
    COMMERCIAL_RELATIONSHIP_MANAGER_KEY = $commercialRelationshipManagerKey
    COMMERCIAL_CREDIT_MEMO_KEY = $commercialCreditMemoKey
    CIB_DEAL_RESEARCH_KEY = $cibDealResearchKey
    CIB_DUE_DILIGENCE_KEY = $cibDueDiligenceKey
    WEALTH_ADVISOR_COPILOT_KEY = $wealthAdvisorCopilotKey
    WEALTH_PORTFOLIO_COMMENTARY_KEY = $wealthPortfolioCommentaryKey
}
foreach ($entry in $subscriptionKeys.GetEnumerator()) {
    if (-not $entry.Value) { throw "APIM subscription key '$($entry.Key)' is missing." }
    Write-Host "  $($entry.Key): resolved"
}

# Focused plans keep their tier-oriented JMeter variable names but use real catalog subscriptions.
$bronzeTestKey = $consumerCustomerServiceKey
$silverTestKey = $consumerAccountOpeningKey
$silverTestKey2 = $cibDealResearchKey
$goldTestKey = $commercialCreditMemoKey

# ---------------------------------------------------------------------------
# 4. Helper — create or update one ALT test definition
# ---------------------------------------------------------------------------
function Register-AltTest {
    param(
        [string]   $TestId,
        [ValidateLength(2, 50)]
        [string]   $DisplayName,
        [string]   $Description,
        [string]   $JmxPath,
        [string[]] $AdditionalFiles,  # paths uploaded as ADDITIONAL_ARTIFACTS (system.properties, truststore)
        [string[]] $UserPropsPairs,   # @("KEY=value", ...) — written to user.properties and uploaded
        [string]   $TempFileName      # unique filename for temp user.properties in $TEMP
    )

    Write-Host ""
    Write-Host "─── $TestId ─────────────────────────────────────────────────" -ForegroundColor Cyan

    if (-not (Test-Path $JmxPath)) {
        Write-Warning "  JMX not found: $JmxPath — skipping $TestId"
        return
    }

    # Create or update the test definition
    $ErrorActionPreference = 'Continue'
    $exists = az load test show `
        --load-test-resource $ALT_RESOURCE -g $RG `
        --test-id $TestId --query testId -o tsv 2>$null
    $ErrorActionPreference = 'Stop'

    if ($exists -eq $TestId) {
        Write-Host "  Test exists — updating JMX and private subnet..."
        az load test update `
            --load-test-resource $ALT_RESOURCE -g $RG `
            --test-id $TestId `
            --test-plan $JmxPath `
            --subnet-id $subnetId `
            --env "" `
            -o none
        if ($LASTEXITCODE -ne 0) { throw "az load test update failed for '$TestId' (exit $LASTEXITCODE)" }
        Write-Host "  Updated." -ForegroundColor Green
    } else {
        Write-Host "  Creating test '$TestId'..."
        $createArgs = @(
            "load", "test", "create",
            "--load-test-resource", $ALT_RESOURCE,
            "-g", $RG,
            "--test-id", $TestId,
            "--display-name", $DisplayName,
            "--description", $Description,
            "--test-plan", $JmxPath,
            "-o", "none"
        )
        $createArgs += @("--subnet-id", $subnetId)
        & az @createArgs
        if ($LASTEXITCODE -ne 0) { throw "az load test create failed for '$TestId' (exit $LASTEXITCODE)" }
        Write-Host "  Created '$TestId'." -ForegroundColor Green
    }

    $configuredSubnetId = az load test show `
        --load-test-resource $ALT_RESOURCE -g $RG `
        --test-id $TestId --query subnetId -o tsv 2>$null
    if (-not $configuredSubnetId -or -not $configuredSubnetId.Equals($subnetId, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Test '$TestId' is not VNet-injected into '$subnetId'; reported subnet is '$configuredSubnetId'."
    }
    Write-Host "  Private traffic subnet verified." -ForegroundColor Green

    # Upload static support files (system.properties, appgw-system.properties, truststore)
    foreach ($filePath in $AdditionalFiles) {
        if (Test-Path $filePath) {
            az load test file upload `
                --load-test-resource $ALT_RESOURCE -g $RG `
                --test-id $TestId `
                --path $filePath `
                --file-type ADDITIONAL_ARTIFACTS -o none
            Write-Host "  Uploaded $(Split-Path $filePath -Leaf)" -ForegroundColor Green
        } else {
            Write-Warning "  File not found (skipped): $(Split-Path $filePath -Leaf)"
        }
    }

    # Write user.properties to $TEMP, upload, then delete (contains live API keys)
    if ($UserPropsPairs -and $TempFileName) {
        $tmpPath = Join-Path $tempDir $TempFileName
        @(
            "# JMeter user properties for $TestId",
            "# Auto-generated by configure-load-test.ps1 — DO NOT COMMIT (contains live API keys)"
        ) + $UserPropsPairs | Set-Content -Path $tmpPath -Encoding utf8

        az load test file upload `
            --load-test-resource $ALT_RESOURCE -g $RG `
            --test-id $TestId `
            --path $tmpPath `
            --file-type USER_PROPERTIES -o none

        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        Write-Host "  Uploaded user.properties (keys injected; temp file deleted)" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 5. Register all 5 load test definitions
# ---------------------------------------------------------------------------

# ── Test 1: apim-smoke-test ──────────────────────────────────────────────────
# Direct APIM baseline — ALT agent is inside the VNet (snet-loadtest) so it
# can reach APIM's internal hostname without going through App Gateway.
# Provides the reference latency for App Gateway overhead calculations.
Register-AltTest `
    -TestId       'apim-smoke-test' `
    -DisplayName  $testDisplayNames['apim-smoke-test'] `
    -Description  'Bronze/Silver direct to APIM (no AppGW); latency baseline for WAF overhead calculations' `
    -JmxPath      (Join-Path $definitionsDir 'apim-load-test.jmx') `
    -AdditionalFiles @(
        (Join-Path $configDir 'system.properties')
    ) `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$apimHostname",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$bronzeTestKey",
        "SILVER_KEY=$silverTestKey"
    ) `
    -TempFileName 'apim-smoke-user.properties'

# ── Test 2: appgw-failover-test ─────────────────────────────────────────────
# Saturates primary Foundry gpt-4o-mini TPM cap (1K TPM permanently).
# Verifies APIM circuit-breaker retries on secondary Foundry endpoint.
# Client sees HTTP 200; X-Backend-Region-Used: secondary-failover in responses.
Register-AltTest `
    -TestId       'appgw-failover-test' `
    -DisplayName  $testDisplayNames['appgw-failover-test'] `
    -Description  'Saturates primary Foundry TPM cap; verifies APIM circuit-breaker failover to secondary' `
    -JmxPath      (Join-Path $definitionsDir 'failover-load-test.jmx') `
    -AdditionalFiles @(
        (Join-Path $configDir 'system.properties'),
        (Join-Path $configDir 'appgw-system.properties')
    ) `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "SILVER_KEY=$silverTestKey"
    ) `
    -TempFileName 'appgw-failover-user.properties'

# ── Test 3: appgw-smoke-test ─────────────────────────────────────────────────
# Measures WAF inspection latency overhead vs direct APIM baseline.
# appgw-truststore.p12 is generated by scripts/create-appgw-cert.ps1 and is
# uploaded when present. system.properties (trustStore=NONE) provides a fallback
# SSL bypass so the test still runs even without the truststore file.
$appgwTruststore = Join-Path $configDir 'appgw-truststore.p12'
$appgwExtraFiles = [System.Collections.Generic.List[string]]::new()
if (Test-Path $appgwTruststore) {
    $appgwExtraFiles.Add($appgwTruststore)
} else {
    Write-Warning "appgw-truststore.p12 not found — run scripts/create-appgw-cert.ps1 then re-run this script to upload it."
    Write-Warning "The appgw-smoke-test will use system.properties (trustStore=NONE) as a fallback."
}
$appgwExtraFiles.Add((Join-Path $configDir 'system.properties'))
$appgwExtraFiles.Add((Join-Path $configDir 'appgw-system.properties'))

Register-AltTest `
    -TestId       'appgw-smoke-test' `
    -DisplayName  $testDisplayNames['appgw-smoke-test'] `
    -Description  'Measures latency through App Gateway WAF v2 vs direct APIM baseline (~10-30ms overhead expected)' `
    -JmxPath      (Join-Path $definitionsDir 'appgw-load-test.jmx') `
    -AdditionalFiles $appgwExtraFiles.ToArray() `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "BRONZE_KEY=$bronzeTestKey",
        "SILVER_KEY=$silverTestKey"
    ) `
    -TempFileName 'appgw-smoke-user.properties'

# ── Test 4: multi-sub-failover-test ─────────────────────────────────────────
Register-AltTest `
    -TestId       'multi-sub-failover-test' `
    -DisplayName  $testDisplayNames['multi-sub-failover-test'] `
    -Description  'Runs independent tier subscriptions concurrently to validate isolation and circuit-state routing' `
    -JmxPath      (Join-Path $definitionsDir 'multi-sub-failover-test.jmx') `
    -AdditionalFiles @(
        (Join-Path $configDir 'system.properties'),
        (Join-Path $configDir 'appgw-system.properties')
    ) `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "CONSUMER_CUSTOMER_SERVICE_KEY=$consumerCustomerServiceKey",
        "COMMERCIAL_RELATIONSHIP_MANAGER_KEY=$commercialRelationshipManagerKey",
        "CONSUMER_ACCOUNT_OPENING_KEY=$consumerAccountOpeningKey",
        "CIB_DEAL_RESEARCH_KEY=$cibDealResearchKey",
        "WEALTH_PORTFOLIO_COMMENTARY_KEY=$wealthPortfolioCommentaryKey",
        "COMMERCIAL_CREDIT_MEMO_KEY=$commercialCreditMemoKey",
        "CIB_DUE_DILIGENCE_KEY=$cibDueDiligenceKey",
        "WEALTH_ADVISOR_COPILOT_KEY=$wealthAdvisorCopilotKey"
    ) `
    -TempFileName 'multi-sub-failover-user.properties'

# ── Test 5: steady-state-test ────────────────────────────────────────────────
Register-AltTest `
    -TestId       'steady-state-test' `
    -DisplayName  $testDisplayNames['steady-state-test'] `
    -Description  'Runs all eight LOB use-case subscriptions below quota to populate per-subscription telemetry' `
    -JmxPath      (Join-Path $definitionsDir 'steady-state-test.jmx') `
    -AdditionalFiles @(
        (Join-Path $configDir 'system.properties'),
        (Join-Path $configDir 'appgw-system.properties')
    ) `
    -UserPropsPairs @(
        "APIM_HOSTNAME=$APPGW_FQDN",
        "API_VERSION=2024-10-21",
        "CONSUMER_CUSTOMER_SERVICE_KEY=$consumerCustomerServiceKey",
        "CONSUMER_ACCOUNT_OPENING_KEY=$consumerAccountOpeningKey",
        "COMMERCIAL_RELATIONSHIP_MANAGER_KEY=$commercialRelationshipManagerKey",
        "COMMERCIAL_CREDIT_MEMO_KEY=$commercialCreditMemoKey",
        "CIB_DEAL_RESEARCH_KEY=$cibDealResearchKey",
        "CIB_DUE_DILIGENCE_KEY=$cibDueDiligenceKey",
        "WEALTH_PORTFOLIO_COMMENTARY_KEY=$wealthPortfolioCommentaryKey",
        "WEALTH_ADVISOR_COPILOT_KEY=$wealthAdvisorCopilotKey"
    ) `
    -TempFileName 'steady-state-user.properties'

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "All 5 load test definitions configured in '$ALT_RESOURCE'." -ForegroundColor Green
Write-Host ""
Write-Host "Run a test:"
Write-Host "  pwsh load_tests/scripts/run_load_test.ps1 # interactive launcher"
Write-Host "  pwsh load_tests/scripts/run_load_test.ps1 -TestId apim-smoke-test"
Write-Host "  pwsh load_tests/scripts/run_load_test.ps1 -TestId appgw-failover-test"
Write-Host "  pwsh load_tests/scripts/run_load_test.ps1 -TestId appgw-smoke-test"
Write-Host "  pwsh load_tests/scripts/run_load_test.ps1 -TestId multi-sub-failover-test"
Write-Host "  pwsh load_tests/scripts/run_load_test.ps1 -TestId steady-state-test"
Write-Host ""
Write-Host "Note: scripts/create-appgw-cert.ps1 generates load_tests/config/appgw-truststore.p12."
Write-Host "      Run it once after provision, then re-run this script to upload the truststore to appgw-smoke-test."
