# Installs the ViGEmBus driver on a CI runner (Windows Server), for the vigem job in
# windows.yml. The release installer refuses Windows Server in its launch conditions, so
# this unpacks its MSI with an administrative install, adds the signed driver package
# with pnputil and creates the root-enumerated bus device (what `devcon install` does).
# It prints how the package is signed and whether the device started. On windows-2022
# the bus starts; xusb22.sys (the Xbox 360 driver) is absent on Server.
param([Parameter(Mandatory)][string]$Exe)
$ErrorActionPreference = 'Stop'

$work = Join-Path $env:RUNNER_TEMP 'vigem'
New-Item -ItemType Directory -Force "$work\x", "$work\a" | Out-Null
Start-Process -FilePath $Exe -ArgumentList '/extract', "`"$work\x`"" -Wait
Get-ChildItem "$work\x" -Recurse -File | Format-Table -AutoSize Length, FullName | Out-String -Width 300
# The bundle carries one MSI per architecture; unpack them all and pick the amd64 package.
foreach ($m in Get-ChildItem "$work\x" -Recurse -Filter *.msi) {
    $dest = Join-Path "$work\a" $m.BaseName
    $p = Start-Process msiexec -ArgumentList '/a', "`"$($m.FullName)`"", '/qn', "TARGETDIR=`"$dest`"" -Wait -PassThru
    "administrative install of $($m.Name): exit $($p.ExitCode)"
}
Get-ChildItem "$work\a" -Recurse -Include *.inf, *.sys, *.cat | Format-Table -AutoSize Length, FullName | Out-String -Width 300

$inf = Get-ChildItem "$work\a" -Recurse -Filter ViGEmBus.inf |
    Where-Object { ($_.DirectoryName -notmatch '32-bit|x86|ARM64') -and (Test-Path (Join-Path $_.DirectoryName 'ViGEmBus.sys')) } |
    Select-Object -First 1
if (-not $inf) { throw 'no amd64 ViGEmBus.inf in the installer' }
"driver package: $($inf.FullName)"

# Who signed it: attestation-signed packages carry the "Windows Hardware Driver Attested
# Verification" EKU (1.3.6.1.4.1.311.10.3.5.1); WHQL/HLK ones "Windows Hardware Driver
# Verification" (1.3.6.1.4.1.311.10.3.5).
foreach ($f in @((Join-Path $inf.DirectoryName 'ViGEmBus.cat'), (Join-Path $inf.DirectoryName 'ViGEmBus.sys'))) {
    $sig = Get-AuthenticodeSignature $f
    "$([IO.Path]::GetFileName($f)): $($sig.Status) by $($sig.SignerCertificate.Subject)"
    if ($sig.SignerCertificate) {
        $eku = $sig.SignerCertificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] }
        foreach ($u in $eku.EnhancedKeyUsages) { "  EKU $($u.Value) $($u.FriendlyName)" }
    }
}

pnputil /add-driver $inf.FullName /install

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class RootDevice {
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid cls, IntPtr hwnd);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiCreateDeviceInfoW(IntPtr set, string name, ref Guid cls, string desc, IntPtr hwnd, int flags, ref SP_DEVINFO_DATA d);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr set, ref SP_DEVINFO_DATA d, int prop, byte[] buf, int size);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiCallClassInstaller(int dif, IntPtr set, ref SP_DEVINFO_DATA d);
    [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwnd, string hwid, string inf, int flags, out bool reboot);
    public static void Create(string cls, string hwid, string inf) {
        Guid g = new Guid(cls);
        IntPtr set = SetupDiCreateDeviceInfoList(ref g, IntPtr.Zero);
        SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
        d.cbSize = Marshal.SizeOf(d);
        if (!SetupDiCreateDeviceInfoW(set, "System", ref g, null, IntPtr.Zero, 1 /* DICD_GENERATE_ID */, ref d)) throw new Win32Exception();
        byte[] ids = System.Text.Encoding.Unicode.GetBytes(hwid + "\0\0");
        if (!SetupDiSetDeviceRegistryPropertyW(set, ref d, 1 /* SPDRP_HARDWAREID */, ids, ids.Length)) throw new Win32Exception();
        if (!SetupDiCallClassInstaller(0x19 /* DIF_REGISTERDEVICE */, set, ref d)) throw new Win32Exception();
        bool reboot;
        if (!UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hwid, inf, 1 /* INSTALLFLAG_FORCE */, out reboot)) throw new Win32Exception();
    }
}
'@
try {
    [RootDevice]::Create('{4D36E97D-E325-11CE-BFC1-08002BE10318}', 'Nefarius\ViGEmBus\Gen1', $inf.FullName)
    'bus device created'
} catch {
    "bus device: $($_.Exception.Message)"
}

Get-PnpDevice -Class System | Where-Object { $_.HardwareID -contains 'Nefarius\ViGEmBus\Gen1' } | ForEach-Object {
    $code = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_ProblemCode).Data
    "$($_.InstanceId): $($_.Status) (problem code $code; 48 = blocked by policy, 52 = signature not accepted)"
}
Get-Service ViGEmBus -ErrorAction SilentlyContinue | Format-List Name, Status
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 10 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match 'ViGEm' } | Format-List TimeCreated, Id, Message
"xusb22.sys present: $(Test-Path "$env:WINDIR\System32\drivers\xusb22.sys")"
