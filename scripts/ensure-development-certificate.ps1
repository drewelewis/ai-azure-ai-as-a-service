[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-AzdValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }
    return [string]$value
}

$certificateMode = Get-AzdValue -Name 'AZURE_SSL_CERT_KV_SECRET_ID'
if ($certificateMode -ne '__GENERATE__') {
    Write-Host '[OK] Using the configured Key Vault certificate secret ID.'
    exit 0
}

$location = Get-AzdValue -Name 'AZURE_LOCATION'
if ([string]::IsNullOrWhiteSpace($location)) {
    throw 'AZURE_LOCATION is required before generating the development certificate.'
}

$dnsName = "*.$location.cloudapp.azure.com"
$storedDnsName = Get-AzdValue -Name 'AZURE_SSL_CERT_DNS_NAME'
$storedPfx = Get-AzdValue -Name 'AZURE_SSL_CERT_PFX_BASE64'
if ($storedPfx -and $storedDnsName -eq $dnsName) {
    Write-Host "[OK] Reusing the generated development certificate for $dnsName."
    exit 0
}

$rsa = [System.Security.Cryptography.RSA]::Create(2048)
try {
    $distinguishedName = [System.Security.Cryptography.X509Certificates.X500DistinguishedName]::new("CN=$dnsName")
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $distinguishedName,
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true)
    )
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
            [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment,
            $true
        )
    )
    $enhancedKeyUsage = [System.Security.Cryptography.OidCollection]::new()
    [void]$enhancedKeyUsage.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($enhancedKeyUsage, $true)
    )
    $subjectAlternativeName = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    $subjectAlternativeName.AddDnsName($dnsName)
    $request.CertificateExtensions.Add($subjectAlternativeName.Build())

    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddYears(1))
    try {
        $pfxBytes = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx)
        $pfxBase64 = [Convert]::ToBase64String($pfxBytes)
    } finally {
        $certificate.Dispose()
    }
} finally {
    $rsa.Dispose()
}

azd env set AZURE_SSL_CERT_PFX_BASE64 $pfxBase64
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to persist AZURE_SSL_CERT_PFX_BASE64 in the selected azd environment.'
}
azd env set AZURE_SSL_CERT_DNS_NAME $dnsName
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to persist AZURE_SSL_CERT_DNS_NAME in the selected azd environment.'
}

Write-Host "[OK] Generated and stored a development certificate for $dnsName."