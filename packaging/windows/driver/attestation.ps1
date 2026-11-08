# Release signing for the IddCx virtual display driver (PR #39), through Microsoft's
# attestation signing. Two steps, each runnable on its own:
#
#   pwsh attestation.ps1 -Cab     -Package DIR [-Package DIR ...] -Out moonsec-idd.cab
#       Puts each driver package (MoonsecIdd.inf, .dll, .cat as made by
#       platform/windows/idd/build.ps1, one folder per architecture) in a CAB and signs the
#       CAB with the EV certificate. Partner Center only accepts EV-signed submissions.
#       EV keys live on a hardware token or a cloud HSM, so this usually runs on the
#       machine that has the token: -Thumbprint picks the certificate from the store;
#       without it, sign.ps1's secrets are used (an HSM-backed Trusted Signing profile
#       does not qualify as EV for Partner Center as of this writing).
#
#   pwsh attestation.ps1 -Submit  -CabFile moonsec-idd.cab -Out signed\
#       Creates a hardware product and submission with the Partner Center hardware API,
#       uploads the CAB, waits for Microsoft to sign it and downloads the signed package.
#       Needs an Azure AD app registered in Partner Center with the Manager role:
#       PARTNER_CENTER_TENANT_ID, PARTNER_CENTER_CLIENT_ID, PARTNER_CENTER_CLIENT_SECRET.
#
# Not yet run against a live account (none exists); the API calls follow Microsoft's
# "Create and submit a hardware product" docs. The signed package's .cat is
# Microsoft-signed; the MSI ships it unmodified (packaging/windows/build.ps1 -IddDir).
param(
    [switch]$Cab,
    [string[]]$Package,
    [switch]$Submit,
    [string]$CabFile,
    [string]$Thumbprint,
    [string]$Out,
    [string]$ProductName = "moonsec virtual display",
    # Windows 10 1803+ (IddCx 1.2 is the floor in the .inf) and Windows 11, x64 and ARM64.
    [string[]]$Signatures = @("WINDOWS_v100_RS4_X64_FULL", "WINDOWS_v100_RS4_ARM64_FULL", "WINDOWS_v100_X64_CO_FULL", "WINDOWS_v100_ARM64_CO_FULL")
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Cab) {
    if (-not $Package -or -not $Out) { throw "-Cab needs -Package DIR... and -Out FILE.cab" }
    $ddf = Join-Path ([IO.Path]::GetTempPath()) "moonsec-idd.ddf"
    $outFile = [IO.Path]::GetFullPath($Out)
    $lines = @(
        ".OPTION EXPLICIT",
        ".Set CabinetFileCountThreshold=0", ".Set FolderFileCountThreshold=0", ".Set FolderSizeThreshold=0",
        ".Set MaxCabinetSize=0", ".Set MaxDiskFileCount=0", ".Set MaxDiskSize=0",
        ".Set Cabinet=on", ".Set Compress=on", ".Set CompressionType=MSZIP",
        ".Set DiskDirectoryTemplate=$([IO.Path]::GetDirectoryName($outFile))",
        ".Set CabinetNameTemplate=$([IO.Path]::GetFileName($outFile))"
    )
    foreach ($p in $Package) {
        $dir = (Resolve-Path $p).Path
        $name = Split-Path -Leaf $dir   # e.g. package-x64: one folder per architecture
        $lines += ".Set DestinationDir=$name"
        foreach ($f in "MoonsecIdd.inf", "MoonsecIdd.dll", "MoonsecIdd.cat") {
            $src = Join-Path $dir $f
            if (-not (Test-Path $src)) { throw "missing $src" }
            $lines += "`"$src`""
        }
    }
    $lines | Set-Content -Encoding ascii $ddf
    makecab /f $ddf | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "makecab failed ($LASTEXITCODE)" }
    if ($Thumbprint) {
        $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe |
            Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
        & $signtool.FullName sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /sha1 $Thumbprint $outFile
        if ($LASTEXITCODE -ne 0) { throw "signtool failed ($LASTEXITCODE)" }
    } else {
        & (Join-Path $here "..\sign.ps1") -Require $outFile
    }
    Write-Host "attestation CAB: $outFile"
    return
}

if ($Submit) {
    if (-not $CabFile -or -not $Out) { throw "-Submit needs -CabFile FILE.cab and -Out DIR" }
    foreach ($v in "PARTNER_CENTER_TENANT_ID", "PARTNER_CENTER_CLIENT_ID", "PARTNER_CENTER_CLIENT_SECRET") {
        if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v is not set (needs a Partner Center account)" }
    }
    $api = "https://manage.devcenter.microsoft.com/v2.0/my/hardware"
    $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$env:PARTNER_CENTER_TENANT_ID/oauth2/token" -Body @{
        grant_type = "client_credentials"; client_id = $env:PARTNER_CENTER_CLIENT_ID
        client_secret = $env:PARTNER_CENTER_CLIENT_SECRET; resource = "https://manage.devcenter.microsoft.com"
    }
    $h = @{ Authorization = "Bearer $($tok.access_token)" }
    $json = { param($o) $o | ConvertTo-Json -Depth 8 }

    $product = Invoke-RestMethod -Method Post -Uri "$api/products" -Headers $h -ContentType "application/json" -Body (& $json @{
        productName = $ProductName; testHarness = "Attestation"; announcementDate = (Get-Date).ToUniversalTime().ToString("s")
        deviceMetadataIds = @(); firmwareVersion = "0"; deviceType = "internal"; isTestSign = $false; isFlightSign = $false
        marketingNames = @(); selectedProductTypes = @{}; requestedSignatures = $Signatures; additionalAttributes = @{}
    })
    Write-Host "product $($product.id)"
    $sub = Invoke-RestMethod -Method Post -Uri "$api/products/$($product.id)/submissions" -Headers $h -ContentType "application/json" -Body (& $json @{
        name = "$ProductName $(Get-Date -Format yyyyMMdd-HHmm)"; type = "initial"
    })
    Write-Host "submission $($sub.id)"
    $upload = ($sub.downloads.items | Where-Object { $_.type -eq "initialPackage" }).url
    if (-not $upload) { throw "no upload URL in the submission" }
    Invoke-RestMethod -Method Put -Uri $upload -InFile $CabFile -Headers @{ "x-ms-blob-type" = "BlockBlob" } | Out-Null
    Invoke-RestMethod -Method Post -Uri "$api/products/$($product.id)/submissions/$($sub.id)/commit" -Headers $h | Out-Null

    # Signing usually takes 10 to 30 minutes.
    $deadline = (Get-Date).AddHours(2)
    do {
        Start-Sleep -Seconds 60
        $s = Invoke-RestMethod -Uri "$api/products/$($product.id)/submissions/$($sub.id)" -Headers $h
        $wf = $s.workflowStatus
        Write-Host "$(Get-Date -Format HH:mm) $($wf.currentStep): $($wf.state)"
        if ($wf.state -eq "failed") { throw "submission failed: $($wf.errorReport | ConvertTo-Json -Depth 6)" }
    } until (($wf.currentStep -eq "finalizeIngestion" -and $wf.state -eq "completed") -or (Get-Date) -gt $deadline)
    $signed = ($s.downloads.items | Where-Object { $_.type -eq "signedPackage" }).url
    if (-not $signed) { throw "no signed package after waiting (step $($wf.currentStep), state $($wf.state))" }
    New-Item -ItemType Directory -Force $Out | Out-Null
    $zip = Join-Path $Out "signed.zip"
    Invoke-WebRequest -Uri $signed -OutFile $zip
    Expand-Archive -Force $zip $Out
    Get-ChildItem -Recurse $Out | Format-Table Length, FullName
    return
}
throw "pass -Cab or -Submit"
