# Builds the moonsec virtual display driver and test-signs it.
#
#   pwsh platform/windows/idd/build.ps1 [-Platform x64|ARM64] [-Configuration Release|Debug]
#
# Needs Visual Studio 2022 with the WDK (the windows-2022 runner has both). Output, ready
# for install.ps1:
#   platform/windows/idd/out/package-<Platform>/  MoonsecIdd.inf, .dll, .cat, moonsec-idd-test.cer
#
# Signing uses a self-signed code-signing certificate made here (CN=moonsec IDD test).
# That is a test signature: Windows installs it only where the certificate is trusted
# (install.ps1 does that) and, on most machines, with test signing on. Release signing
# (attestation through the Partner Center) is Phase 7.
param(
    [string]$Platform = "x64",
    [string]$Configuration = "Release"
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $here "out"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
if (-not $msbuild) { throw "MSBuild not found (install Visual Studio 2022 with the WDK)" }
Write-Host "MSBuild: $msbuild"

& $msbuild (Join-Path $here "driver\MoonsecIdd.vcxproj") -nologo -m "-p:Configuration=$Configuration" "-p:Platform=$Platform" -v:minimal
if ($LASTEXITCODE -ne 0) { throw "msbuild failed ($LASTEXITCODE)" }

$bin = Join-Path $out "$Platform\$Configuration"
$dll = Get-ChildItem -Path $bin -Recurse -Filter MoonsecIdd.dll | Select-Object -First 1
# The stamped INF (DriverVer filled in by stampinf), not the source one.
$inf = Get-ChildItem -Path $bin -Recurse -Filter MoonsecIdd.inf | Select-Object -First 1
if (-not $dll -or -not $inf) { throw "build output missing under $bin" }

$pkg = Join-Path $out "package-$Platform"
Remove-Item -Recurse -Force $pkg -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $pkg | Out-Null
Copy-Item $dll.FullName, $inf.FullName $pkg

$kits = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
function Find-KitTool($name) {
    $t = Get-ChildItem -Path $kits -Recurse -Filter $name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\(x64|x86)\\' } | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $t) { throw "$name not found under $kits" }
    return $t.FullName
}
$inf2cat = Find-KitTool "Inf2Cat.exe"
$signtool = Find-KitTool "signtool.exe"

$os = if ($Platform -eq "ARM64") { "10_RS4_ARM64" } else { "10_RS4_X64" }
& $inf2cat "/driver:$pkg" "/os:$os" /uselocaltime
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed ($LASTEXITCODE)" }

# One test certificate per machine, reused across builds.
$subject = "CN=moonsec IDD test"
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date) } | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation Cert:\CurrentUser\My `
        -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2)
}
Export-Certificate -Cert $cert -FilePath (Join-Path $pkg "moonsec-idd-test.cer") | Out-Null

foreach ($f in @("MoonsecIdd.dll", "MoonsecIdd.cat")) {
    & $signtool sign /fd sha256 /sha1 $cert.Thumbprint /s My (Join-Path $pkg $f)
    if ($LASTEXITCODE -ne 0) { throw "signtool failed on $f ($LASTEXITCODE)" }
}
Copy-Item (Join-Path $here "install.ps1") $pkg
Write-Host "driver package: $pkg"
Get-ChildItem $pkg | Format-Table Name, Length
