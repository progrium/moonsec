# Authenticode-signs files for the Windows packages, with whichever signing identity the
# environment provides, in this order:
#
#   Azure Trusted Signing   AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET,
#                           TRUSTED_SIGNING_ENDPOINT (e.g. https://eus.codesigning.azure.net),
#                           TRUSTED_SIGNING_ACCOUNT, TRUSTED_SIGNING_PROFILE
#   A certificate (.pfx)    WINDOWS_CERT_PFX (base64 of the .pfx), WINDOWS_CERT_PASSWORD
#
# With neither, it prints that the build is unsigned and succeeds, so the same workflow
# makes test builds without secrets. With -Require it fails instead (release runs).
#
#   pwsh packaging/windows/sign.ps1 [-Require] FILE...
param(
    [switch]$Require,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files
)
$ErrorActionPreference = "Stop"
$timestamp = "http://timestamp.acs.microsoft.com"

function Find-SignTool {
    $kits = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $t = Get-ChildItem -Path $kits -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $t) { throw "signtool.exe not found under $kits (install the Windows SDK)" }
    return $t.FullName
}

$mode = $null
if ($env:TRUSTED_SIGNING_ACCOUNT -and $env:AZURE_CLIENT_SECRET) { $mode = "trusted-signing" }
elseif ($env:WINDOWS_CERT_PFX) { $mode = "pfx" }
if (-not $mode) {
    if ($Require) { throw "signing required, but no Trusted Signing or certificate secrets are set" }
    Write-Host "::warning::no Windows signing secrets: leaving $($Files.Count) file(s) unsigned"
    return
}
$signtool = Find-SignTool
Write-Host "signing $($Files.Count) file(s) with $mode"

if ($mode -eq "trusted-signing") {
    # The Trusted Signing dlib reads the account from a metadata file and the Azure
    # credentials from the AZURE_* variables (EnvironmentCredential).
    $work = Join-Path ([IO.Path]::GetTempPath()) "moonsec-ts"
    New-Item -ItemType Directory -Force $work | Out-Null
    nuget install Microsoft.Trusted.Signing.Client -OutputDirectory $work -NonInteractive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "nuget install Microsoft.Trusted.Signing.Client failed" }
    $dlib = Get-ChildItem $work -Recurse -Filter Azure.CodeSigning.Dlib.dll | Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
    if (-not $dlib) { throw "Azure.CodeSigning.Dlib.dll missing from the Trusted Signing client package" }
    $meta = Join-Path $work "metadata.json"
    @{ Endpoint = $env:TRUSTED_SIGNING_ENDPOINT; CodeSigningAccountName = $env:TRUSTED_SIGNING_ACCOUNT; CertificateProfileName = $env:TRUSTED_SIGNING_PROFILE } |
        ConvertTo-Json | Set-Content -Encoding utf8 $meta
    & $signtool sign /v /fd SHA256 /tr $timestamp /td SHA256 /dlib $dlib.FullName /dmdf $meta @Files
} else {
    $pfx = Join-Path ([IO.Path]::GetTempPath()) "moonsec-sign.pfx"
    [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_CERT_PFX))
    try {
        & $signtool sign /v /fd SHA256 /tr $timestamp /td SHA256 /f $pfx /p $env:WINDOWS_CERT_PASSWORD @Files
    } finally { Remove-Item -Force $pfx }
}
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed ($LASTEXITCODE)" }
& $signtool verify /pa /v @Files | Select-String "Issued to|Successfully verified" | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "signtool verify failed ($LASTEXITCODE)" }
