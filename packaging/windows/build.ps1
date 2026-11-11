# Builds the Windows MSI from built binaries:
#
#   pwsh packaging/windows/build.ps1 -Arch x64|arm64 -BinDir DIR -Notices FILE -Version X.Y.Z
#        [-IddDir DIR] [-Out dist] [-RequireSigning]
#
# BinDir holds moonsec.exe and moonsec-svc.exe. Signs both (sign.ps1) before packing them,
# then the MSI. IddDir, when given, is the IddCx driver package (MoonsecIdd.inf/.dll/.cat)
# already signed for release (driver/attestation.ps1); the MSI adds it with pnputil.
# Needs the .NET SDK (the windows-2022 runner has it); WiX comes from `dotnet tool`.
param(
    [Parameter(Mandatory)][ValidateSet("x64", "arm64")][string]$Arch,
    [Parameter(Mandatory)][string]$BinDir,
    [Parameter(Mandatory)][string]$Notices,
    [Parameter(Mandatory)][string]$Version,
    [string]$IddDir,
    [string]$Out = "dist",
    [switch]$RequireSigning
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$wixVersion = "5.0.2"   # WiX v4 schema; v5 is the current free release of the .NET tool.

# MSI versions are three numbers (the fourth is ignored by upgrades): 0.1.0+abc -> 0.1.0.
$msiVersion = ($Version -replace '^(\d+\.\d+\.\d+).*', '$1')
if ($msiVersion -notmatch '^\d+\.\d+\.\d+$') { throw "version $Version has no X.Y.Z" }

$stage = Join-Path ([IO.Path]::GetTempPath()) "moonsec-msi-$Arch"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory $stage | Out-Null
foreach ($f in "moonsec.exe", "moonsec-svc.exe") {
    $src = Join-Path $BinDir $f
    if (-not (Test-Path $src)) { throw "missing $src" }
    Copy-Item $src $stage
}
& (Join-Path $here "sign.ps1") -Require:$RequireSigning (Join-Path $stage "moonsec.exe") (Join-Path $stage "moonsec-svc.exe")

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    dotnet tool install --global wix --version $wixVersion
    $env:PATH += ";$env:USERPROFILE\.dotnet\tools"
}
wix extension add -g "WixToolset.Util.wixext/$wixVersion"
if ($LASTEXITCODE -ne 0) { throw "wix extension add failed" }

New-Item -ItemType Directory -Force $Out | Out-Null
$msi = Join-Path (Resolve-Path $Out) "moonsec-$Version-windows-$Arch.msi"
$wixArgs = @("build", (Join-Path $here "moonsec.wxs"), "-arch", $Arch, "-ext", "WixToolset.Util.wixext",
    "-d", "Version=$msiVersion", "-d", "BinDir=$stage", "-d", "Notices=$((Resolve-Path $Notices).Path)", "-o", $msi)
if ($IddDir) { $wixArgs += @("-d", "IddDir=$((Resolve-Path $IddDir).Path)") }
wix @wixArgs
if ($LASTEXITCODE -ne 0) { throw "wix build failed ($LASTEXITCODE)" }

& (Join-Path $here "sign.ps1") -Require:$RequireSigning $msi
Write-Host "built $msi"
