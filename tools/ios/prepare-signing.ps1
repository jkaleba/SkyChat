param(
    [ValidateSet('request', 'export')][string]$Step = 'request',
    [string]$CertificatePath,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repositoryRoot '.private/ios-signing' }
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outputPath.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Signing files must stay inside this project, preferably .private/ios-signing.'
}
$opensslCommand = Get-Command openssl -ErrorAction SilentlyContinue
if ($opensslCommand) { $opensslPath = $opensslCommand.Source }
elseif (Test-Path -LiteralPath 'C:\Program Files\Git\usr\bin\openssl.exe') {
    $opensslPath = 'C:\Program Files\Git\usr\bin\openssl.exe'
} else { throw 'OpenSSL was not found. Install Git for Windows, or add OpenSSL to PATH.' }
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$privateKeyPath = Join-Path $outputPath 'distribution.key'
$csrPath = Join-Path $outputPath 'SkyChat.certSigningRequest'
$p12Path = Join-Path $outputPath 'distribution.p12'
if ($Step -eq 'request') {
    if ((Test-Path -LiteralPath $privateKeyPath) -or (Test-Path -LiteralPath $csrPath)) {
        throw 'A signing request/key already exists. Reuse it; this script will not overwrite your key.'
    }
    & $opensslPath genrsa -out $privateKeyPath 2048
    if ($LASTEXITCODE -ne 0) { throw 'RSA key generation failed.' }
    & $opensslPath req -new -sha256 -key $privateKeyPath -out $csrPath -subj '/CN=SkyChat CI/'
    if ($LASTEXITCODE -ne 0) { throw 'CSR generation failed.' }
    Write-Output "Upload this CSR in the Apple Developer certificate page: $csrPath"
    Write-Output 'Keep distribution.key private. The .private directory is ignored by Git.'
} else {
    if (-not (Test-Path -LiteralPath $privateKeyPath)) { throw 'Run the request step first, on this same computer.' }
    if (-not $CertificatePath) { throw 'Provide -CertificatePath pointing to the Apple Distribution .cer download.' }
    if (Test-Path -LiteralPath $p12Path) { throw 'distribution.p12 already exists; it will not be overwritten.' }
    $certificate = (Resolve-Path -LiteralPath $CertificatePath).Path
    $pemPath = Join-Path $outputPath 'distribution.pem'
    & $opensslPath x509 -inform DER -in $certificate -out $pemPath
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the Apple .cer certificate.' }
    $securePassword = Read-Host 'Choose a password for P12_PASSWORD in GitHub' -AsSecureString
    $plainPassword = [Net.NetworkCredential]::new('', $securePassword).Password
    if ([string]::IsNullOrWhiteSpace($plainPassword)) { throw 'Use a nonempty P12 password.' }
    try {
        $env:SKYCHAT_P12_PASSWORD = $plainPassword
        & $opensslPath pkcs12 -export -inkey $privateKeyPath -in $pemPath -out $p12Path -passout env:SKYCHAT_P12_PASSWORD
        if ($LASTEXITCODE -ne 0) { throw 'P12 export failed. Check that the Apple certificate belongs to this CSR/key.' }
    } finally {
        Remove-Item -LiteralPath Env:\SKYCHAT_P12_PASSWORD -ErrorAction SilentlyContinue
        $plainPassword = $null
    }
    $base64Path = Join-Path $outputPath 'BUILD_CERTIFICATE_BASE64.txt'
    [IO.File]::WriteAllText($base64Path, [Convert]::ToBase64String([IO.File]::ReadAllBytes($p12Path)))
    Write-Output "P12 created. Copy the contents of this file into BUILD_CERTIFICATE_BASE64: $base64Path"
    Write-Output 'Use the password you chose as P12_PASSWORD. Do not commit these files.'
}
