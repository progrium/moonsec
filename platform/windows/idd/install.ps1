# Installs the test-signed moonsec virtual display driver from a package folder made by
# build.ps1 (or CI's "moonsec-idd-x64" artifact). Run from an elevated PowerShell in the
# package folder:
#
#   bcdedit /set testsigning on      # once, then reboot (see ../README.md)
#   .\install.ps1                    # trusts the test certificate, adds the driver
#   .\install.ps1 -Uninstall         # removes the driver and its devices
#
# The moonsec host creates the device itself while it streams (a software device that
# goes away with the host process). -RootDevice also makes a permanent root device, for
# hosts that run without the rights to create one.
param(
    [switch]$Uninstall,
    [switch]$RootDevice
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$inf = Join-Path $here "MoonsecIdd.inf"

if ($Uninstall) {
    $drivers = pnputil /enum-drivers | Out-String
    $names = [regex]::Matches($drivers, "Published Name:\s+(oem\d+\.inf)\s+Original Name:\s+moonsecidd\.inf", "IgnoreCase") |
        ForEach-Object { $_.Groups[1].Value }
    foreach ($n in $names) { pnputil /delete-driver $n /uninstall /force }
    Write-Host "removed: $($names -join ', ')"
    return
}

$cer = Join-Path $here "moonsec-idd-test.cer"
foreach ($store in @("Cert:\LocalMachine\Root", "Cert:\LocalMachine\TrustedPublisher")) {
    Import-Certificate -FilePath $cer -CertStoreLocation $store | Out-Null
}
pnputil /add-driver $inf /install
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 259) { throw "pnputil failed ($LASTEXITCODE)" }

if ($RootDevice) {
    # devcon ships with the WDK (Tools\<arch>\devcon.exe); pnputil can't create root devices before Windows 11.
    $devcon = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Tools" -Recurse -Filter devcon.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } | Select-Object -First 1
    if (-not $devcon) { throw "devcon.exe not found (install the WDK, or run without -RootDevice)" }
    & $devcon.FullName install $inf "Root\MoonsecIdd"
}
Write-Host "installed"
