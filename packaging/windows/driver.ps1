# Adds or removes the moonsec IddCx driver package in the driver store. The MSI runs it
# (as LocalSystem) from Program Files\moonsec\driver. Release packages carry the
# attestation-signed driver, so nothing here touches certificate stores; the test-signed
# development package from PR #39 keeps using its own install.ps1.
param([switch]$Add, [switch]$Remove)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Add) {
    pnputil /add-driver (Join-Path $here "MoonsecIdd.inf") /install
    # 0: added; 259: already up to date; 3010: added, reboot to finish.
    if ($LASTEXITCODE -notin 0, 259, 3010) { throw "pnputil /add-driver failed ($LASTEXITCODE)" }
}
if ($Remove) {
    $drivers = pnputil /enum-drivers | Out-String
    $names = [regex]::Matches($drivers, "Published Name:\s+(oem\d+\.inf)\s+Original Name:\s+moonsecidd\.inf", "IgnoreCase") |
        ForEach-Object { $_.Groups[1].Value }
    foreach ($n in $names) { pnputil /delete-driver $n /uninstall /force | Out-Null }
}
