#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Export the Bicep-provisioned App Gateway certificate and create Azure Load Testing
    trust artifacts.

.DESCRIPTION
    Infrastructure, certificate storage, identities, and RBAC are owned by
    Bicep. This helper reads the generated PFX from the local azd environment,
    or a configured external Key Vault secret, and writes local certificate
    files used by JMeter and Azure Load Testing.

.NOTES
    Run after 'azd provision'. The deploying principal needs the Key Vault
    Certificate User role assigned by supporting-infra.bicep.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Environment ────────────────────────────────────────────────────────────────
. "$PSScriptRoot/_resolve-env.ps1"
# KV, APPGW_NAME, APPGW_FQDN all resolved from the live resource group above.
# Fall back to sensible defaults if resources not yet deployed.
$KV        = if ($KV_NAME)   { $KV_NAME }   else { throw "No Key Vault found in '$RG'. Run: azd provision" }
$CERT_NAME = 'appgw-ssl-cert'
# APPGW_NAME resolved by _resolve-env.ps1; derive FQDN from public IP if available.
# If App Gateway not yet deployed APPGW_NAME / APPGW_FQDN will be empty — that is fine,
# the cert creation step does not require App Gateway to exist yet.
# Derive the expected App Gateway name from the Bicep naming convention:
#   agw-${companyPrefix}-ai-primary  (matches main.bicep appGwName param)
# This works whether App Gateway is already deployed or not.
$expectedAppGwName = "agw-$companyPrefix-ai-primary"
if (-not $APPGW_NAME) { $APPGW_NAME = $expectedAppGwName }

# FQDN: use live public IP DNS label if already deployed; otherwise derive from name.
# DNS label in Bicep = toLower('${companyPrefix}-ai-gw-${apimNameSuffix}') — globally unique.
# Extract the suffix from the APIM name: 'apim-contoso-lcjrut5z' -> 'lcjrut5z'
if (-not $APPGW_FQDN) {
    if ($APIM_NAME) {
        $apimSuffix = ($APIM_NAME -replace "^apim-$companyPrefix-", '')
        $dnsLabel   = "$($companyPrefix.ToLower())-ai-gw-$apimSuffix"
        $APPGW_FQDN = "$dnsLabel.$PRIMARY_LOCATION.cloudapp.azure.com"
    } else {
        # APIM not yet deployed (unlikely in postprovision hook) — use placeholder
        $APPGW_FQDN = "$($APPGW_NAME.ToLower()).$PRIMARY_LOCATION.cloudapp.azure.com"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$testsDir  = Join-Path $repoRoot 'load_tests'

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  App Gateway WAF v2 — Prerequisites Setup"                         -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Resource Group : $RG"
Write-Host "  Key Vault      : $KV"
Write-Host "  Certificate    : $CERT_NAME  (CN=$APPGW_FQDN)"
Write-Host "  App Gateway    : $APPGW_NAME"
Write-Host ""

Write-Host "=== Step 1: Read Bicep-provisioned certificate material ===" -ForegroundColor Cyan

$certificateMode = azd env get-value AZURE_SSL_CERT_KV_SECRET_ID 2>$null
if ($certificateMode -eq '__GENERATE__') {
    $secretValue = azd env get-value AZURE_SSL_CERT_PFX_BASE64 2>$null
    if (-not $secretValue) {
        throw 'Generated certificate material is missing. Run azd provision to reconcile the declared infrastructure.'
    }
    Write-Host '  Source: local azd development certificate'
} else {
    $secretValue = az keyvault secret show --id $certificateMode --query value -o tsv 2>$null
    if (-not $secretValue) {
        throw "Certificate secret '$certificateMode' could not be read."
    }
    Write-Host "  Secret ID: $certificateMode"
}

# ── Step 2 : Export cert + build PKCS12 truststore for JMeter ─────────────────
# App Gateway's cert subject must match the FQDN used in load tests.
# JMeter rejects self-signed certs unless the test engine trusts them.
# We export the public cert and build a PKCS12 truststore that the load test
# uploads to Azure Load Testing as an ADDITIONAL_ARTIFACTS file.
Write-Host ""
Write-Host "=== Step 2: Export certificate and build JMeter truststore ===" -ForegroundColor Cyan

$pfxBytes    = [Convert]::FromBase64String($secretValue)

# Load PFX with .NET, no password (KV self-signed certs have no PFX password by default)
$pfx = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $pfxBytes, [string]::Empty,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
)

# Export public cert (DER) — uploaded alongside JMX so JMeter can load it at test time
$certDerPath = Join-Path $testsDir 'config' 'appgw-cert.cer'
[IO.File]::WriteAllBytes($certDerPath, $pfx.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
))
Write-Host "  Public cert (DER) → $certDerPath" -ForegroundColor Green

# Build a PKCS12 bundle (acts as JMeter truststore)
# JMeter / Java accepts PKCS12 as a truststore via javax.net.ssl.trustStoreType=PKCS12
$truststore    = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certDerPath)
$tsPassword    = 'changeit'
$tsBytes       = $truststore.Export(
    [System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12,
    $tsPassword
)
$truststorePath = Join-Path $testsDir 'config' 'appgw-truststore.p12'
[IO.File]::WriteAllBytes($truststorePath, $tsBytes)
Write-Host "  PKCS12 truststore  → $truststorePath  (password: $tsPassword)" -ForegroundColor Green

# Write jmeter system.properties that tells JMeter/Java to use this truststore
# File is uploaded alongside the JMX; JMeter looks in its current directory first
$syspropsPath = Join-Path $testsDir 'config' 'appgw-system.properties'
@"
# JMeter system properties for AppGW load test — references the truststore uploaded
# alongside the JMX as an ADDITIONAL_ARTIFACTS file in Azure Load Testing.
# The filename (no path) works because ALT places all test files in the same directory.
javax.net.ssl.trustStore=appgw-truststore.p12
javax.net.ssl.trustStorePassword=$tsPassword
javax.net.ssl.trustStoreType=PKCS12
"@ | Set-Content $syspropsPath
Write-Host "  system.properties  → $syspropsPath" -ForegroundColor Green

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Green
Write-Host "  Local certificate artifacts created!"                              -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  AppGW FQDN (available after provision):"
Write-Host "    https://$APPGW_FQDN"
Write-Host ""
Write-Host "  Files written to load_tests/config/:"
Write-Host "    appgw-cert.cer         — public cert (DER)"
Write-Host "    appgw-truststore.p12   — PKCS12 truststore for JMeter"
Write-Host "    appgw-system.properties — JMeter system props for ALT"
Write-Host ""
