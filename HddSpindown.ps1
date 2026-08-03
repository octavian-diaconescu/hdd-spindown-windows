#Requires -Version 5.1
<#
.SYNOPSIS
  Spin down selected HDDs and hard-lock them offline so Windows cannot wake them.

.DESCRIPTION
  Lock: takes the disk offline (Set-Disk -IsOffline), then sends ATA STANDBY IMMEDIATE.
  Offline runs first because the offline transition itself wakes the drive; spindown
  must happen after that. Unlock brings the disk online and restores saved drive letters.

  Drive letters disappear while locked. That is intentional — offline is the
  only reliable way to stop Search, Defender, and other services from spinning
  the drive back up.

  Always run elevated. Never targets system/boot/pagefile/hibernation disks.

  Lock by default also tries to disable the disk in PnP (Device Manager) after
  offline + standby. If Windows refuses (open handles / pending reboot), Lock
  still succeeds as offline-only. Use -Soft to skip the PnP attempt.
  Close Task Manager disk views and SMART tools before Lock for best PnP success;
  a reboot may be required if a prior disable left the device "pending reboot".

.EXAMPLE
  .\HddSpindown.ps1 List
  .\HddSpindown.ps1 Lock -DiskNumber 2
  .\HddSpindown.ps1 Lock -DriveLetter E -Force
  .\HddSpindown.ps1 Lock -DiskNumber 0,1,3
  .\HddSpindown.ps1 Lock -DriveLetter F,D -Soft
  .\HddSpindown.ps1 Unlock -DiskNumber 0,1
  .\HddSpindown.ps1 Unlock -DriveLetter F,D
  .\HddSpindown.ps1 Respin
  .\HddSpindown.ps1 Status
  .\HddSpindown.ps1 Install
  hddspindown Lock -DiskNumber 0,1 -Force

.NOTES
  State:  %LOCALAPPDATA%\HddSpindown\state.json
  Config: optional allowlist beside this script or in the same AppData folder
          (see config.example.json).

  Install adds a `hddspindown` launcher to your user PATH (%LOCALAPPDATA%\HddSpindown).
  Lock/Unlock/Respin auto-prompt for UAC elevation when not already admin.

  Lock/Unlock of one disk can wake other HDDs on the same SATA controller
  (Windows re-enumerates the host). After Lock/Unlock the script re-sends
  standby to every disk recorded as locked that still has a PhysicalDrive
  handle (PnP-disabled siblings are skipped there to avoid extra enable cycles).

  Respin: on-demand re-standby of locked disks. For hard (PnP) locks it briefly
  enables each device, sends STANDBY IMMEDIATE, then disables again — required
  because a disabled DiskDrive has no \\.\PhysicalDrive handle after reboot.

  Re-locking an already-locked disk uses state only (no Get-Disk/Get-Partition)
  so it will not wake siblings just to look the disk up.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('List', 'Lock', 'Unlock', 'Status', 'Respin', 'Install')]
    [string] $Action,

    # Single or bulk: -DiskNumber 2   or  -DiskNumber 0,1,3   or  -DiskNumber "0,1,3"
    $DiskNumber = $null,

    # Single or bulk: -DriveLetter F  or  -DriveLetter F,D,E  or  -DriveLetter "F,D,E"
    $DriveLetter = $null,

    [switch] $Force,

    # Lock: offline + standby only (do not Disable-PnpDevice)
    [switch] $Soft
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Paths / state
# ---------------------------------------------------------------------------

$script:AppDataDir = Join-Path $env:LOCALAPPDATA 'HddSpindown'
$script:StatePath  = Join-Path $script:AppDataDir 'state.json'
$script:ConfigPaths = @(
    (Join-Path $PSScriptRoot 'config.json'),
    (Join-Path $script:AppDataDir 'config.json')
)

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) {
        throw 'Administrator privileges required. Re-run elevated, or let the UAC prompt complete.'
    }
}

function ConvertTo-CliArgValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Array]) {
        return (($Value | ForEach-Object { [string]$_ }) -join ',')
    }
    return [string]$Value
}

function Request-ElevationAndExit {
    <#
      Relaunch this script elevated (UAC). Replaces the current process.
    #>
    $hostExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) {
        $hostExe = 'powershell.exe'
    }

    # ShellExecute (Verb RunAs) joins ArgumentList with spaces — quote any token that
    # contains whitespace so -File survives paths like "...\Diaconescu Octavian\...".
    function ConvertTo-ElevatedArgToken([string] $Value) {
        if ($null -eq $Value) { return '""' }
        if ($Value -match '[\s"]') {
            return ('"{0}"' -f ($Value -replace '"', '\"'))
        }
        return $Value
    }

    $argTokens = New-Object System.Collections.Generic.List[string]
    [void]$argTokens.Add('-NoProfile')
    [void]$argTokens.Add('-ExecutionPolicy')
    [void]$argTokens.Add('Bypass')
    [void]$argTokens.Add('-File')
    [void]$argTokens.Add((ConvertTo-ElevatedArgToken $PSCommandPath))
    [void]$argTokens.Add((ConvertTo-ElevatedArgToken $Action))

    if ($null -ne $DiskNumber -and (ConvertTo-CliArgValue $DiskNumber) -ne '') {
        [void]$argTokens.Add('-DiskNumber')
        [void]$argTokens.Add((ConvertTo-ElevatedArgToken (ConvertTo-CliArgValue $DiskNumber)))
    }
    if ($null -ne $DriveLetter -and (ConvertTo-CliArgValue $DriveLetter) -ne '') {
        [void]$argTokens.Add('-DriveLetter')
        [void]$argTokens.Add((ConvertTo-ElevatedArgToken (ConvertTo-CliArgValue $DriveLetter)))
    }
    if ($Force) { [void]$argTokens.Add('-Force') }
    if ($Soft) { [void]$argTokens.Add('-Soft') }

    # Single string is the reliable form for Verb RunAs + paths with spaces.
    $argumentList = ($argTokens -join ' ')
    $workDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($workDir) -or -not (Test-Path -LiteralPath $workDir)) {
        $workDir = $env:SystemRoot
    }

    Write-Host 'Requesting Administrator privileges (UAC)...'
    try {
        $p = Start-Process -FilePath $hostExe `
            -Verb RunAs `
            -ArgumentList $argumentList `
            -WorkingDirectory $workDir `
            -Wait `
            -PassThru
        if ($null -ne $p -and $null -ne $p.ExitCode) {
            exit $p.ExitCode
        }
        exit 0
    } catch {
        throw ("UAC elevation was cancelled or failed: {0}" -f $_.Exception.Message)
    }
}

function Ensure-AppDataDir {
    if (-not (Test-Path -LiteralPath $script:AppDataDir)) {
        New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null
    }
}

function Read-State {
    Ensure-AppDataDir
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return [pscustomobject]@{ Version = 1; LockedDisks = @() }
    }
    $raw = Get-Content -LiteralPath $script:StatePath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ Version = 1; LockedDisks = @() }
    }
    try {
        $obj = $raw | ConvertFrom-Json
    } catch {
        throw ("State file {0} is corrupt JSON: {1}`nFix or delete it. Locked disks stay offline either way; you may need to restore their letters manually in Disk Management." -f $script:StatePath, $_.Exception.Message)
    }
    # StrictMode-safe: the property may be missing if the file was hand-edited.
    $prop = $obj.PSObject.Properties['LockedDisks']
    if ($null -eq $prop -or $null -eq $prop.Value) {
        $obj | Add-Member -NotePropertyName LockedDisks -NotePropertyValue @() -Force
    } elseif ($prop.Value -isnot [System.Array]) {
        $obj.LockedDisks = @($prop.Value)
    }
    return $obj
}

function Write-State {
    param([Parameter(Mandatory)] $State)
    Ensure-AppDataDir

    # Windows PowerShell 5.1's ConvertTo-Json collapses single-element arrays.
    # Build LockedDisks as an explicit JSON array to keep round-trips stable.
    $diskJsonParts = @()
    foreach ($disk in @($State.LockedDisks)) {
        $diskJsonParts += ($disk | ConvertTo-Json -Depth 8 -Compress)
    }
    $joined = $diskJsonParts -join ",`r`n    "
    $json = @"
{
  "Version": 1,
  "LockedDisks": [
    $joined
  ]
}
"@
    # Atomic replace so a crash mid-write cannot leave a truncated state file.
    $tempPath = "$script:StatePath.tmp"
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tempPath, $json, $utf8NoBom)
    Move-Item -LiteralPath $tempPath -Destination $script:StatePath -Force
}

function Read-Allowlist {
    foreach ($path in $script:ConfigPaths) {
        if (Test-Path -LiteralPath $path) {
            $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $ids = New-Object System.Collections.Generic.List[string]
            # StrictMode-safe: user configs may omit AllowedDisks, UniqueId, or SerialNumber.
            $allowed = Get-DiskProp $cfg 'AllowedDisks' $null
            if ($allowed) {
                foreach ($entry in @($allowed)) {
                    $u = Get-DiskProp $entry 'UniqueId' $null
                    $s = Get-DiskProp $entry 'SerialNumber' $null
                    if ($u) { [void]$ids.Add([string]$u) }
                    if ($s) { [void]$ids.Add([string]$s) }
                }
            }
            Write-Output -NoEnumerate @($ids.ToArray())
            return
        }
    }
    Write-Output -NoEnumerate @()
}

# ---------------------------------------------------------------------------
# ATA / SCSI spindown (embedded P/Invoke)
# ---------------------------------------------------------------------------

function Initialize-AtaNative {
    if ('HddSpindown.Native.AtaIo' -as [type]) {
        return
    }

    $code = @'
using System;
using System.Runtime.InteropServices;

namespace HddSpindown.Native
{
    public static class AtaIo
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        private const uint IOCTL_ATA_PASS_THROUGH = 0x0004D02C;
        private const uint IOCTL_SCSI_PASS_THROUGH = 0x0004D004;

        private const byte ATA_STANDBY_IMMEDIATE = 0xE0;
        private const byte ATA_CHECK_POWER_MODE = 0xE5;
        private const byte ATA_FLAGS_DRDY_REQUIRED = 0x01;
        private const byte SCSI_START_STOP_UNIT = 0x1B;

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        private struct ATA_PASS_THROUGH_EX
        {
            public ushort Length;
            public ushort AtaFlags;
            public byte PathId;
            public byte TargetId;
            public byte Lun;
            public byte ReservedAsUchar;
            public uint DataTransferLength;
            public uint TimeOutValue;
            public IntPtr DataBufferOffset;
            public uint ReservedAsUlong;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
            public byte[] PreviousTaskFile;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
            public byte[] CurrentTaskFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SCSI_PASS_THROUGH
        {
            public ushort Length;
            public byte ScsiStatus;
            public byte PathId;
            public byte TargetId;
            public byte Lun;
            public byte CdbLength;
            public byte SenseInfoLength;
            public byte DataIn;
            public uint DataTransferLength;
            public uint TimeOutValue;
            public IntPtr DataBufferOffset;
            public uint SenseInfoOffset;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
            public byte[] Cdb;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFile(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            IntPtr hDevice,
            uint dwIoControlCode,
            IntPtr lpInBuffer,
            uint nInBufferSize,
            IntPtr lpOutBuffer,
            uint nOutBufferSize,
            out uint lpBytesReturned,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        private static IntPtr OpenDisk(int diskNumber, out string error)
        {
            error = null;
            string path = @"\\.\PhysicalDrive" + diskNumber;
            IntPtr handle = CreateFile(
                path,
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                IntPtr.Zero);

            if (handle == INVALID_HANDLE_VALUE)
            {
                error = "CreateFile failed for " + path + " (Win32=" + Marshal.GetLastWin32Error() + ")";
                return INVALID_HANDLE_VALUE;
            }
            return handle;
        }

        public static string SpinDown(int diskNumber)
        {
            string openError;
            IntPtr handle = OpenDisk(diskNumber, out openError);
            if (handle == INVALID_HANDLE_VALUE)
                return openError;

            try
            {
                string ataError = TryAtaStandby(handle);
                if (ataError == null)
                    return null;

                string scsiError = TryScsiStartStop(handle);
                if (scsiError == null)
                    return null;

                return "ATA standby failed (" + ataError + "); SCSI START STOP failed (" + scsiError + ")";
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        // Returns Standby|Idle|Active|Unknown|Error:...
        // ATA CHECK POWER MODE (0xE5) is intended not to change power state.
        public static string CheckPowerMode(int diskNumber)
        {
            string openError;
            IntPtr handle = OpenDisk(diskNumber, out openError);
            if (handle == INVALID_HANDLE_VALUE)
                return "Error:" + openError;

            try
            {
                var apt = new ATA_PASS_THROUGH_EX();
                apt.Length = (ushort)Marshal.SizeOf(typeof(ATA_PASS_THROUGH_EX));
                apt.AtaFlags = 0; // do not require DRDY; tolerate standby
                apt.DataTransferLength = 0;
                apt.TimeOutValue = 5;
                apt.DataBufferOffset = IntPtr.Zero;
                apt.PreviousTaskFile = new byte[8];
                apt.CurrentTaskFile = new byte[8];
                apt.CurrentTaskFile[6] = ATA_CHECK_POWER_MODE;

                int size = Marshal.SizeOf(apt);
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.StructureToPtr(apt, buffer, false);
                    uint returned;
                    bool ok = DeviceIoControl(
                        handle,
                        IOCTL_ATA_PASS_THROUGH,
                        buffer,
                        (uint)size,
                        buffer,
                        (uint)size,
                        out returned,
                        IntPtr.Zero);

                    if (!ok)
                        return "Error:Win32=" + Marshal.GetLastWin32Error();

                    var result = (ATA_PASS_THROUGH_EX)Marshal.PtrToStructure(buffer, typeof(ATA_PASS_THROUGH_EX));
                    byte status = result.CurrentTaskFile[7];
                    if ((status & 0x01) != 0)
                        return "Error:ATA status=0x" + status.ToString("X2");

                    // Sector Count holds power mode after CHECK POWER MODE
                    byte mode = result.CurrentTaskFile[1];
                    if (mode == 0x00) return "Standby";
                    if (mode == 0x80) return "Idle";
                    if (mode == 0xFF) return "Active";
                    return "Unknown:0x" + mode.ToString("X2");
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        private static string TryAtaStandby(IntPtr handle)
        {
            var apt = new ATA_PASS_THROUGH_EX();
            apt.Length = (ushort)Marshal.SizeOf(typeof(ATA_PASS_THROUGH_EX));
            apt.AtaFlags = ATA_FLAGS_DRDY_REQUIRED;
            apt.DataTransferLength = 0;
            apt.TimeOutValue = 10;
            apt.DataBufferOffset = IntPtr.Zero;
            apt.PreviousTaskFile = new byte[8];
            apt.CurrentTaskFile = new byte[8];
            apt.CurrentTaskFile[6] = ATA_STANDBY_IMMEDIATE;

            int size = Marshal.SizeOf(apt);
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(apt, buffer, false);
                uint returned;
                bool ok = DeviceIoControl(
                    handle,
                    IOCTL_ATA_PASS_THROUGH,
                    buffer,
                    (uint)size,
                    buffer,
                    (uint)size,
                    out returned,
                    IntPtr.Zero);

                if (!ok)
                    return "Win32=" + Marshal.GetLastWin32Error();

                var result = (ATA_PASS_THROUGH_EX)Marshal.PtrToStructure(buffer, typeof(ATA_PASS_THROUGH_EX));
                byte status = result.CurrentTaskFile[7];
                if ((status & 0x01) != 0)
                    return "ATA status error (status=0x" + status.ToString("X2") + ")";

                return null;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static string TryScsiStartStop(IntPtr handle)
        {
            var spt = new SCSI_PASS_THROUGH();
            spt.Length = (ushort)Marshal.SizeOf(typeof(SCSI_PASS_THROUGH));
            spt.CdbLength = 6;
            spt.SenseInfoLength = 0;
            spt.DataIn = 0;
            spt.DataTransferLength = 0;
            spt.TimeOutValue = 10;
            spt.DataBufferOffset = IntPtr.Zero;
            spt.SenseInfoOffset = 0;
            spt.Cdb = new byte[16];
            spt.Cdb[0] = SCSI_START_STOP_UNIT;
            spt.Cdb[4] = 0;

            int size = Marshal.SizeOf(spt);
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(spt, buffer, false);
                uint returned;
                bool ok = DeviceIoControl(
                    handle,
                    IOCTL_SCSI_PASS_THROUGH,
                    buffer,
                    (uint)size,
                    buffer,
                    (uint)size,
                    out returned,
                    IntPtr.Zero);

                if (!ok)
                    return "Win32=" + Marshal.GetLastWin32Error();

                var result = (SCSI_PASS_THROUGH)Marshal.PtrToStructure(buffer, typeof(SCSI_PASS_THROUGH));
                if (result.ScsiStatus != 0)
                    return "SCSI status=0x" + result.ScsiStatus.ToString("X2");

                return null;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
'@

    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
}

function Invoke-DiskSpinDown {
    param(
        [Parameter(Mandatory)][int] $Number,
        [switch] $Quiet
    )

    Initialize-AtaNative
    $errorText = [HddSpindown.Native.AtaIo]::SpinDown($Number)
    if ($null -eq $errorText) {
        return $true
    }
    if (-not $Quiet) {
        Write-Warning "Spindown IOCTL did not succeed for disk $Number : $errorText"
    }
    return $false
}

function Get-DiskPowerMode {
    param([Parameter(Mandatory)][int] $Number)
    Initialize-AtaNative
    return [string][HddSpindown.Native.AtaIo]::CheckPowerMode($Number)
}

function Test-PowerModeAwake {
    param([string] $Mode)
    if ([string]::IsNullOrEmpty($Mode)) { return $false }
    if ($Mode.StartsWith('Error')) { return $false }
    if ($Mode -eq 'Standby') { return $false }
    # Idle / Active / Unknown:* count as awake for wake detection
    return $true
}

function Test-PnpInstanceDisabled {
    param([string] $InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $false }
    Import-Module PnpDevice -ErrorAction SilentlyContinue | Out-Null
    $dev = $null
    try { $dev = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue } catch { }
    if (-not $dev) { return $false }
    $status = [string](Get-DiskProp $dev 'Status' '')
    $problem = [string](Get-DiskProp $dev 'Problem' '')
    if ($problem -match 'DISABLED' -or $problem -eq 'CM_PROB_DISABLED') { return $true }
    if ($status -ne 'OK' -and $status -ne '') { return $true }
    return $false
}

function Find-DiskByLockedEntry {
    <#
      Disk numbers shift after PnP disable/enable. Prefer UniqueId, then SerialNumber,
      then the Number saved in state.
    #>
    param([Parameter(Mandatory)] $Entry)

    $uid = [string](Get-DiskProp $Entry 'UniqueId' '')
    $serial = ([string](Get-DiskProp $Entry 'SerialNumber' '')).Trim()
    $savedNum = $null
    if ($null -ne (Get-DiskProp $Entry 'Number' $null)) {
        $savedNum = [int]$Entry.Number
    }

    $all = @()
    try { $all = @(Get-Disk -ErrorAction SilentlyContinue) } catch { $all = @() }

    if ($uid) {
        foreach ($d in $all) {
            if ([string](Get-DiskProp $d 'UniqueId' '') -eq $uid) { return $d }
        }
    }
    if ($serial) {
        foreach ($d in $all) {
            if (([string](Get-DiskProp $d 'SerialNumber' '')).Trim() -eq $serial) { return $d }
        }
    }
    if ($null -ne $savedNum) {
        foreach ($d in $all) {
            if ([int]$d.Number -eq $savedNum) { return $d }
        }
        try { return Get-Disk -Number $savedNum -ErrorAction Stop } catch { }
    }
    return $null
}

function Wait-DiskByLockedEntry {
    param(
        [Parameter(Mandatory)] $Entry,
        [int] $TimeoutSec = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $d = Find-DiskByLockedEntry -Entry $Entry
        if ($d) { return $d }
        Start-Sleep -Milliseconds 500
    }
    $label = Get-DiskProp $Entry 'FriendlyName' 'disk'
    throw ("Timed out waiting for '{0}' to reappear after PnP enable ({1} sec)." -f $label, $TimeoutSec)
}

function Update-LockedEntryNumber {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)][int] $NewNumber
    )
    $old = [int](Get-DiskProp $Entry 'Number' -1)
    if ($old -eq $NewNumber) { return }
    $state = Read-State
    $uid = [string](Get-DiskProp $Entry 'UniqueId' '')
    $serial = ([string](Get-DiskProp $Entry 'SerialNumber' '')).Trim()
    $changed = $false
    foreach ($e in @($state.LockedDisks)) {
        $same = ($uid -and ([string](Get-DiskProp $e 'UniqueId' '') -eq $uid)) -or
                ($serial -and (([string](Get-DiskProp $e 'SerialNumber' '')).Trim() -eq $serial)) -or
                (($null -ne (Get-DiskProp $e 'Number' $null)) -and ([int]$e.Number -eq $old))
        if ($same) {
            $e | Add-Member -NotePropertyName Number -NotePropertyValue $NewNumber -Force
            $changed = $true
        }
    }
    if ($changed) {
        Write-State -State $state
        $Entry | Add-Member -NotePropertyName Number -NotePropertyValue $NewNumber -Force
    }
}

function Invoke-RespinDownLockedDisks {
    <#
      SATA/AHCI often re-enumerates the whole host when one disk goes online/offline,
      which wakes sibling drives. Re-send ATA standby to every locked disk using only
      \\.\PhysicalDriveN (no Get-Partition).

      -AllowPnpCycle: used by explicit Respin. Temporarily enables PnP-disabled disks,
      sends standby, then disables them again. Without this, hard-locked disks are
      skipped (no PhysicalDrive handle while CM_PROB_DISABLED).
    #>
    param(
        [string] $Reason = 'storage bus activity',
        [switch] $AllowPnpCycle
    )

    $state = Read-State
    $locked = @($state.LockedDisks)
    if ($locked.Count -eq 0) { return }

    # Guard against stale state: if a "locked" disk is actually online (e.g. the
    # user brought it back via Disk Management), sending standby would park a
    # mounted disk and stall its next access. Skip those and tell the user.
    $onlineByKey = @{}
    foreach ($d in Get-OnlineDisksSafe) {
        $onlineByKey["n:$([int]$d.Number)"] = $true
        $u = [string](Get-DiskProp $d 'UniqueId' '')
        $s = ([string](Get-DiskProp $d 'SerialNumber' '')).Trim()
        if ($u) { $onlineByKey["u:$u"] = $true }
        if ($s) { $onlineByKey["s:$s"] = $true }
    }

    $directTargets = New-Object System.Collections.Generic.List[object]
    $pnpCycleTargets = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $locked) {
        $uid = [string](Get-DiskProp $entry 'UniqueId' '')
        $serial = ([string](Get-DiskProp $entry 'SerialNumber' '')).Trim()
        $num = [int](Get-DiskProp $entry 'Number' -1)
        $name = [string](Get-DiskProp $entry 'FriendlyName' '')

        $isOnline = $false
        if ($uid -and $onlineByKey.ContainsKey("u:$uid")) { $isOnline = $true }
        elseif ($serial -and $onlineByKey.ContainsKey("s:$serial")) { $isOnline = $true }
        elseif ($num -ge 0 -and $onlineByKey.ContainsKey("n:$num")) { $isOnline = $true }

        if ($isOnline) {
            Write-Warning ("  Disk {0} ({1}) is recorded as locked but is currently online; skipping standby. Run Unlock -DiskNumber {0} to clean up state." -f $num, $name)
            continue
        }

        $pnpId = Get-DiskProp $entry 'PnpDeviceId' $null
        $needsPnpCycle = $false
        if ($pnpId -and (Test-PnpInstanceDisabled -InstanceId $pnpId)) {
            $needsPnpCycle = $true
        } elseif (Get-DiskProp $entry 'DeviceDisabled' $false) {
            # State says disabled; live check may fail if InstanceId vanished.
            $needsPnpCycle = $true
        }

        if ($needsPnpCycle) {
            if (-not $AllowPnpCycle) {
                Write-Host ("  Disk {0} ({1}): PnP-disabled - skipping ATA (device not exposed). Run Respin to briefly enable, standby, and re-disable." -f $num, $name)
                continue
            }
            if (-not $pnpId) {
                Write-Warning ("  Disk {0} ({1}): marked PnP-disabled but no PnpDeviceId in state; cannot cycle." -f $num, $name)
                continue
            }
            [void]$pnpCycleTargets.Add($entry)
            continue
        }

        $disk = Find-DiskByLockedEntry -Entry $entry
        if (-not $disk) {
            Write-Warning ("  Disk {0} ({1}): not found (may be PnP-disabled or removed); skipping." -f $num, $name)
            continue
        }
        Update-LockedEntryNumber -Entry $entry -NewNumber ([int]$disk.Number)
        [void]$directTargets.Add([pscustomobject]@{
            Entry  = $entry
            Number = [int]$disk.Number
            Name   = $name
        })
    }

    $anyWork = ($directTargets.Count -gt 0) -or ($pnpCycleTargets.Count -gt 0)
    if (-not $anyWork) { return }

    if ($directTargets.Count -gt 0) {
        Write-Host ("Re-spindown of {0} locked disk(s) after {1}..." -f $directTargets.Count, $Reason)
        Start-Sleep -Milliseconds 500
        foreach ($t in $directTargets) {
            $ok = Invoke-DiskSpinDown -Number $t.Number
            if ($ok) {
                Write-Host ("  Disk {0} ({1}): standby sent." -f $t.Number, $t.Name)
            } else {
                Write-Warning ("  Disk {0} ({1}): standby failed." -f $t.Number, $t.Name)
            }
        }
        Start-Sleep -Milliseconds 1200
        foreach ($t in $directTargets) {
            [void](Invoke-DiskSpinDown -Number $t.Number -Quiet)
        }
    }

    if ($pnpCycleTargets.Count -gt 0) {
        Write-Host ("PnP cycle re-spindown of {0} hard-locked disk(s) after {1}..." -f $pnpCycleTargets.Count, $Reason)
        Write-Host '  Temporarily enabling PnP devices (volumes stay offline)...'

        $armed = New-Object System.Collections.Generic.List[object]
        foreach ($entry in $pnpCycleTargets) {
            $pnpId = [string](Get-DiskProp $entry 'PnpDeviceId' '')
            $name = [string](Get-DiskProp $entry 'FriendlyName' '')
            $num = [int](Get-DiskProp $entry 'Number' -1)
            Write-Host ("  Enabling {0}..." -f $name)
            $enabled = Enable-DiskPnpDevice -InstanceId $pnpId
            if (-not $enabled) {
                Write-Warning ("  Could not enable '{0}'; skipping standby." -f $name)
                continue
            }
            try {
                $disk = Wait-DiskByLockedEntry -Entry $entry -TimeoutSec 60
                Update-LockedEntryNumber -Entry $entry -NewNumber ([int]$disk.Number)
                # Keep offline so letters do not remount during the brief enable window.
                if (-not (Get-DiskProp $disk 'IsOffline' $false)) {
                    try {
                        Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction Stop
                        Write-Host ("  Disk {0}: forced offline before standby." -f $disk.Number)
                    } catch {
                        Write-Warning ("  Disk {0}: could not force offline ({1})." -f $disk.Number, $_.Exception.Message)
                    }
                }
                [void]$armed.Add([pscustomobject]@{
                    Entry  = $entry
                    Number = [int]$disk.Number
                    Name   = $name
                    PnpId  = $pnpId
                })
            } catch {
                Write-Warning ("  {0}" -f $_.Exception.Message)
                try { Disable-DiskPnpDevice -InstanceId $pnpId -DiskNumber $num | Out-Null } catch { }
            }
        }

        if ($armed.Count -gt 0) {
            Start-Sleep -Milliseconds 500
            foreach ($t in $armed) {
                $ok = Invoke-DiskSpinDown -Number $t.Number
                if ($ok) {
                    Write-Host ("  Disk {0} ({1}): standby sent." -f $t.Number, $t.Name)
                } else {
                    Write-Warning ("  Disk {0} ({1}): standby failed." -f $t.Number, $t.Name)
                }
            }
            Start-Sleep -Milliseconds 1200
            foreach ($t in $armed) {
                [void](Invoke-DiskSpinDown -Number $t.Number -Quiet)
            }

            Write-Host '  Re-disabling PnP devices...'
            foreach ($t in $armed) {
                $disabled = Disable-DiskPnpDevice -InstanceId $t.PnpId -DiskNumber $t.Number
                if (-not $disabled) {
                    Write-Warning ("  Disk {0} ({1}): re-disable failed; disk may remain enabled but offline." -f $t.Number, $t.Name)
                }
            }
        }
    }

    Write-Host 'Re-spindown pass complete.'
}

# ---------------------------------------------------------------------------
# Disk helpers
# ---------------------------------------------------------------------------

function Get-DiskProp {
    param($Disk, [string] $Name, $Default = $false)
    $p = $Disk.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-DiskLetters {
    param($Disk)
    $letters = New-Object System.Collections.Generic.List[string]
    try {
        $parts = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DriveLetter -and
                ([string]$_.DriveLetter).Length -gt 0 -and
                [int][char]([string]$_.DriveLetter)[0] -ne 0
            })
        foreach ($p in $parts) {
            if ($p.DriveLetter) {
                [void]$letters.Add(([string]$p.DriveLetter).ToUpperInvariant())
            }
        }
    } catch {
        # Offline disks may throw; ignore
    }
    Write-Output -NoEnumerate @($letters | Select-Object -Unique)
}

function Get-DiskPnpInstanceId {
    param([Parameter(Mandatory)][int] $Number)
    try {
        $drive = Get-CimInstance -ClassName Win32_DiskDrive -Filter "Index=$Number" -ErrorAction Stop
        if ($drive -and $drive.PNPDeviceID) {
            return [string]$drive.PNPDeviceID
        }
    } catch { }
    return $null
}

function Disable-DiskPnpDevice {
    param(
        [Parameter(Mandatory)][string] $InstanceId,
        [int] $DiskNumber = -1
    )
    # Returns $true if disabled (or already disabled), $false if not possible.
    # DiskDrive devices often refuse Disable-PnpDevice while something holds a
    # raw disk handle (Task Manager Performance tab, SMART tools, etc.), or when
    # a previous disable is pending reboot.

    Import-Module PnpDevice -ErrorAction SilentlyContinue | Out-Null
    $label = if ($DiskNumber -ge 0) { "Disk $DiskNumber" } else { 'Disk' }

    $dev = $null
    try { $dev = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue } catch { }
    if ($dev) {
        $status = [string](Get-DiskProp $dev 'Status' '')
        $problem = [string](Get-DiskProp $dev 'Problem' '')
        if ($status -ne 'OK' -and ($problem -match 'DISABLED' -or $problem -eq 'CM_PROB_DISABLED')) {
            Write-Host ("  {0}: PnP device already disabled." -f $label)
            return $true
        }
    }

    # 1) Prefer pnputil /force (more reliable than CIM Disable-PnpDevice for disks)
    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    if (Test-Path -LiteralPath $pnputil) {
        $out = & $pnputil /disable-device $InstanceId /force 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("  {0}: PnP device disabled via pnputil." -f $label)
            return $true
        }
        $combined = $out
        if ($combined -match 'reboot' -or $combined -match 'pending') {
            Write-Warning ("  {0}: PnP disable needs a reboot (pending operation or open handle). Offline lock still applies. Close Task Manager / disk tools, reboot once, then re-run Lock to finish PnP disable." -f $label)
            return $false
        }
        if ($combined -match 'not supported') {
            Write-Warning ("  {0}: pnputil disable not supported on this Windows edition; keeping offline-only lock." -f $label)
            # fall through to CIM attempt
        } else {
            Write-Warning ("  {0}: pnputil disable failed (exit {1})." -f $label, $LASTEXITCODE)
        }
    }

    # 2) CIM fallback
    try {
        Disable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        Write-Host ("  {0}: PnP device disabled (Device Manager)." -f $label)
        return $true
    } catch {
        Write-Warning ("  {0}: PnP disable failed ({1}). Keeping offline + spindown lock. Tip: close Task Manager (Performance/disk view) and other disk utilities, then retry Lock; a reboot may clear a pending disable." -f $label, $_.Exception.Message.Trim())
        return $false
    }
}

function Enable-DiskPnpDevice {
    param([Parameter(Mandatory)][string] $InstanceId)
    Import-Module PnpDevice -ErrorAction SilentlyContinue | Out-Null

    $dev = $null
    try { $dev = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue } catch { }
    if ($dev -and ([string](Get-DiskProp $dev 'Status' '')) -eq 'OK') {
        Write-Host '  PnP device already enabled.'
        return $true
    }

    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    if (Test-Path -LiteralPath $pnputil) {
        $null = & $pnputil /enable-device $InstanceId 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host '  PnP device enabled via pnputil.'
            return $true
        }
    }

    try {
        Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop
        Write-Host '  PnP device enabled.'
        return $true
    } catch {
        Write-Warning ("  PnP enable failed: {0}. Enable the disk manually in Device Manager if needed." -f $_.Exception.Message)
        return $false
    }
}

function Wait-DiskNumberReady {
    param(
        [Parameter(Mandatory)][int] $Number,
        [int] $TimeoutSec = 45
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $d = Get-Disk -Number $Number -ErrorAction Stop
            if ($d) { return $d }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    throw ("Timed out waiting for Disk {0} to reappear after PnP enable ({1} sec)." -f $Number, $TimeoutSec)
}

function Test-IsProtectedDisk {
    param($Disk)
    # State-backed stubs are disks we already locked earlier — do not probe partitions
    # (Get-Partition would wake them).
    if (Get-DiskProp $Disk '_FromState' $false) { return $false }

    # Do not key off Number -eq 0: with NVMe boot the system disk is often not disk 0.
    if (Get-DiskProp $Disk 'IsSystem') { return $true }
    if (Get-DiskProp $Disk 'IsBoot') { return $true }
    if (Get-DiskProp $Disk 'IsPageFileDisk') { return $true }
    if (Get-DiskProp $Disk 'IsHibernationDisk') { return $true }
    # Also refuse if any partition is the Windows system/boot partition
    try {
        $sys = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue |
            Where-Object { $_.IsSystem -or $_.IsBoot })
        if (@($sys).Count -gt 0) { return $true }
    } catch { }
    return $false
}

function Get-ProtectedReason {
    param($Disk)
    $reasons = New-Object System.Collections.Generic.List[string]
    if (Get-DiskProp $Disk 'IsSystem') { [void]$reasons.Add('System') }
    if (Get-DiskProp $Disk 'IsBoot') { [void]$reasons.Add('Boot') }
    if (Get-DiskProp $Disk 'IsPageFileDisk') { [void]$reasons.Add('Pagefile') }
    if (Get-DiskProp $Disk 'IsHibernationDisk') { [void]$reasons.Add('Hibernation') }
    try {
        $sys = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue |
            Where-Object { $_.IsSystem -or $_.IsBoot })
        if ($sys.Count -gt 0) { [void]$reasons.Add('SystemOrBootPartition') }
    } catch { }
    if ($reasons.Count -eq 0) { return 'Protected' }
    return ($reasons -join ', ')
}

function ConvertTo-ArgTokenList {
    param($Value)
    if ($null -eq $Value) { return @() }

    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $s = ([string]$item).Trim()
        if ($s -eq '' -or $s -eq '-1') { continue }

        foreach ($part in $s.Split(@(',', ';', ' '), [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $t = $part.Trim().TrimEnd(':')
            if ($t) { [void]$tokens.Add($t) }
        }
    }
    Write-Output -NoEnumerate @($tokens)
}

function New-DiskStubFromState {
    param([Parameter(Mandatory)] $Entry)
    # Minimal stand-in so Lock can re-spindown without Get-Disk (which wakes the drive).
    [pscustomobject]@{
        Number            = [int]$Entry.Number
        FriendlyName      = [string]$Entry.FriendlyName
        SerialNumber      = [string]$Entry.SerialNumber
        UniqueId          = [string](Get-DiskProp $Entry 'UniqueId' '')
        BusType           = [string](Get-DiskProp $Entry 'BusType' '')
        Size              = $(if (Get-DiskProp $Entry 'SizeBytes' $null) { [UInt64]$Entry.SizeBytes } else { [UInt64]0 })
        IsOffline         = $true
        IsSystem          = $false
        IsBoot            = $false
        IsPageFileDisk    = $false
        IsHibernationDisk = $false
        _FromState        = $true
        _StateEntry       = $Entry
    }
}

function Find-LockedEntryByNumber {
    param([int] $Number)
    $map = Get-LockedDiskMap
    if ($map.ContainsKey($Number)) { return $map[$Number] }
    return $null
}

function Find-LockedEntryByLetter {
    param([string] $Letter)
    $letter = $Letter.ToUpperInvariant()
    foreach ($entry in @((Read-State).LockedDisks)) {
        foreach ($p in @($entry.Partitions)) {
            if (([string]$p.DriveLetter).ToUpperInvariant() -eq $letter) {
                return $entry
            }
        }
    }
    return $null
}

function Resolve-LockDiskList {
    $disks = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $lockedMap = Get-LockedDiskMap

    $numberTokens = ConvertTo-ArgTokenList $DiskNumber
    if ($null -eq $numberTokens) { $numberTokens = @() }
    foreach ($tok in $numberTokens) {
        $n = 0
        if (-not [int]::TryParse($tok, [ref]$n)) {
            throw "Invalid disk number '$tok'. Use integers like 0,1,3."
        }
        if ($seen.ContainsKey($n)) { continue }

        if ($lockedMap.ContainsKey($n)) {
            # Already locked: use state stub — Get-Disk would wake the drive.
            [void]$disks.Add((New-DiskStubFromState -Entry $lockedMap[$n]))
        } else {
            $disk = Get-Disk -Number $n -ErrorAction Stop
            [void]$disks.Add($disk)
        }
        $seen[$n] = $true
    }

    $letterTokens = ConvertTo-ArgTokenList $DriveLetter
    if ($null -eq $letterTokens) { $letterTokens = @() }
    foreach ($tok in $letterTokens) {
        if ($tok -notmatch '^[A-Za-z]$') {
            throw "Invalid drive letter '$tok'. Use letters like F,D,E."
        }
        $letter = $tok.ToUpperInvariant()
        $n = -1
        $disk = $null

        try {
            $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
            $n = [int]$part.DiskNumber
            if ($lockedMap.ContainsKey($n)) {
                $disk = New-DiskStubFromState -Entry $lockedMap[$n]
            } else {
                $disk = Get-Disk -Number $n -ErrorAction Stop
            }
        } catch {
            $entry = Find-LockedEntryByLetter -Letter $letter
            if ($entry) {
                $n = [int]$entry.Number
                $disk = New-DiskStubFromState -Entry $entry
            } else {
                throw "Drive letter $letter is not mounted and not found in locked state."
            }
        }

        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        [void]$disks.Add($disk)
    }

    if ($disks.Count -eq 0) {
        throw 'Specify -DiskNumber and/or -DriveLetter (comma-separated for bulk), e.g. -DiskNumber 0,1,3 or -DriveLetter F,D.'
    }
    Write-Output -NoEnumerate @($disks.ToArray())
}

function Resolve-UnlockJobList {
    $state = Read-State
    $jobs = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    $numberTokens = ConvertTo-ArgTokenList $DiskNumber
    if ($null -eq $numberTokens) { $numberTokens = @() }
    foreach ($tok in $numberTokens) {
        $n = 0
        if (-not [int]::TryParse($tok, [ref]$n)) {
            throw "Invalid disk number '$tok'. Use integers like 0,1,3."
        }
        if ($seen.ContainsKey($n)) { continue }

        $entry = $null
        foreach ($e in @($state.LockedDisks)) {
            if ([int]$e.Number -eq $n) { $entry = $e; break }
        }

        $disk = $null
        if ($entry -and (Get-DiskProp $entry 'DeviceDisabled' $false)) {
            # PnP-disabled: disk is not in Get-Disk until Enable — use state stub.
            $disk = New-DiskStubFromState -Entry $entry
        } else {
            if ($entry -and $entry.UniqueId) {
                $disk = Get-Disk -UniqueId $entry.UniqueId -ErrorAction SilentlyContinue
            }
            if (-not $disk) {
                try {
                    $disk = Get-Disk -Number $n -ErrorAction Stop
                } catch {
                    if ($entry) {
                        $disk = New-DiskStubFromState -Entry $entry
                    } else {
                        throw
                    }
                }
            }
        }

        $seen[[int]$disk.Number] = $true
        [void]$jobs.Add([pscustomobject]@{
            Entry  = $entry
            Disk   = $disk
            Number = [int]$disk.Number
        })
    }

    $letterTokens = ConvertTo-ArgTokenList $DriveLetter
    if ($null -eq $letterTokens) { $letterTokens = @() }
    foreach ($tok in $letterTokens) {
        if ($tok -notmatch '^[A-Za-z]$') {
            throw "Invalid drive letter '$tok'. Use letters like F,D,E."
        }
        $letter = $tok.ToUpperInvariant()
        $entry = $null
        foreach ($e in @($state.LockedDisks)) {
            foreach ($p in @($e.Partitions)) {
                if (([string]$p.DriveLetter).ToUpperInvariant() -eq $letter) {
                    $entry = $e
                    break
                }
            }
            if ($entry) { break }
        }

        $disk = $null
        if ($entry -and (Get-DiskProp $entry 'DeviceDisabled' $false)) {
            $disk = New-DiskStubFromState -Entry $entry
        } elseif ($entry) {
            if ($entry.UniqueId) {
                $disk = Get-Disk -UniqueId $entry.UniqueId -ErrorAction SilentlyContinue
            }
            if (-not $disk) {
                try {
                    $disk = Get-Disk -Number ([int]$entry.Number) -ErrorAction Stop
                } catch {
                    $disk = New-DiskStubFromState -Entry $entry
                }
            }
        } else {
            try {
                $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
                $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
            } catch {
                throw "No locked disk found for drive letter $letter, and the letter is not currently mounted."
            }
        }

        $num = [int]$disk.Number
        if ($seen.ContainsKey($num)) { continue }
        $seen[$num] = $true
        [void]$jobs.Add([pscustomobject]@{
            Entry  = $entry
            Disk   = $disk
            Number = $num
        })
    }

    if ($jobs.Count -eq 0) {
        throw 'Specify -DiskNumber and/or -DriveLetter (comma-separated for bulk), e.g. -DiskNumber 0,1 or -DriveLetter F,D.'
    }
    Write-Output -NoEnumerate @($jobs.ToArray())
}

function Assert-AllowlistIfConfigured {
    param($Disk)
    $allow = Read-Allowlist
    if ($null -eq $allow -or $allow.Count -eq 0) { return }

    $placeholders = @('REPLACE_WITH_SERIAL', 'REPLACE_WITH_UNIQUE_ID')
    $realIds = @($allow | Where-Object { $_ -and ($placeholders -notcontains $_) })
    if ($realIds.Count -eq 0) {
        throw 'config.json still has placeholder allowlist values (REPLACE_WITH_*). Edit SerialNumber/UniqueId, use an empty AllowedDisks array, or delete config.json.'
    }

    $serial = [string](Get-DiskProp $Disk 'SerialNumber' '')
    $unique = [string](Get-DiskProp $Disk 'UniqueId' '')
    $ok = $false
    foreach ($id in $realIds) {
        if (-not $id) { continue }
        if ($serial -and ($serial -eq $id -or $serial.Trim() -eq $id.Trim())) { $ok = $true; break }
        if ($unique -and ($unique -eq $id -or $unique.Trim() -eq $id.Trim())) { $ok = $true; break }
    }
    if (-not $ok) {
        throw ("Disk {0} (Serial='{1}') is not in the allowlist in config.json. Add UniqueId or SerialNumber, or remove the config to allow any non-system disk." -f $Disk.Number, $serial)
    }
}

function Get-PartitionSnapshot {
    param($Disk)

    $snapshots = New-Object System.Collections.Generic.List[object]
    $parts = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)
    foreach ($p in $parts) {
        $letter = $null
        if ($p.DriveLetter -and ([string]$p.DriveLetter).Length -gt 0 -and [int][char]([string]$p.DriveLetter)[0] -ne 0) {
            $letter = ([string]$p.DriveLetter).ToUpperInvariant()
        }
        if (-not $letter) { continue }

        $label = $null
        try {
            $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            if ($vol) { $label = [string]$vol.FileSystemLabel }
        } catch { }

        [void]$snapshots.Add([pscustomobject]@{
            Offset      = [UInt64]$p.Offset
            DriveLetter = $letter
            Size        = [UInt64]$p.Size
            Label       = $label
        })
    }
    Write-Output -NoEnumerate @($snapshots.ToArray())
}

function Format-SizeGB {
    param([UInt64]$Bytes)
    if ($Bytes -le 0) { return '0 GB' }
    return ('{0:N1} GB' -f ($Bytes / 1GB))
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

function Get-LockedDiskMap {
    $map = @{}
    $state = Read-State
    foreach ($entry in @($state.LockedDisks)) {
        if ($null -ne $entry.Number) {
            $map[[int]$entry.Number] = $entry
        }
    }
    return $map
}

function Get-OnlineDisksSafe {
    # Prefer a CIM filter so offline/locked disks are not opened for partition probes.
    try {
        return @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName 'MSFT_Disk' `
                -Filter 'IsOffline = FALSE' -ErrorAction Stop)
    } catch {
        # Fallback: Get-Disk then skip offline — still may briefly touch offline devices.
        Write-Warning 'Online-only CIM query failed; falling back to Get-Disk (may wake offline drives).'
        return @(Get-Disk | Where-Object { -not (Get-DiskProp $_ 'IsOffline' $false) })
    }
}

function Format-SerialShort {
    param([string] $Serial)
    $serial = ([string]$Serial).Trim()
    if ($serial.Length -gt 24) {
        return $serial.Substring(0, 21) + '...'
    }
    return $serial
}

function Get-LockedLetters {
    param($Entry)
    $letters = New-Object System.Collections.Generic.List[string]
    if ($Entry.Partitions) {
        foreach ($p in @($Entry.Partitions)) {
            if ($p.DriveLetter) { [void]$letters.Add([string]$p.DriveLetter) }
        }
    }
    return ($letters -join ',')
}

function Get-LockedSizeText {
    param($Entry)
    if ($Entry.PSObject.Properties['SizeBytes'] -and $Entry.SizeBytes) {
        return (Format-SizeGB ([UInt64]$Entry.SizeBytes))
    }
    $sum = [UInt64]0
    if ($Entry.Partitions) {
        foreach ($p in @($Entry.Partitions)) {
            if ($p.Size) { $sum += [UInt64]$p.Size }
        }
    }
    if ($sum -gt 0) { return (Format-SizeGB $sum) }
    return '?'
}

function Invoke-List {
    $lockedMap = Get-LockedDiskMap
    $rows = New-Object System.Collections.Generic.List[object]
    $staleNumbers = @{}

    # Online disks only — never call Get-Partition on locked/offline disks.
    foreach ($d in (Get-OnlineDisksSafe | Sort-Object Number)) {
        $num = [int]$d.Number

        $flags = New-Object System.Collections.Generic.List[string]
        if (Get-DiskProp $d 'IsSystem') { [void]$flags.Add('System') }
        if (Get-DiskProp $d 'IsBoot') { [void]$flags.Add('Boot') }
        if (Get-DiskProp $d 'IsPageFileDisk') { [void]$flags.Add('Pagefile') }
        if (Get-DiskProp $d 'IsHibernationDisk') { [void]$flags.Add('Hibernation') }
        if (Test-IsProtectedDisk -Disk $d) {
            if (-not $flags.Contains('System') -and -not $flags.Contains('Boot')) {
                [void]$flags.Add('Protected')
            }
        }
        if ($lockedMap.ContainsKey($num)) {
            # State says locked but the disk is online — stale entry. Show the
            # live row and flag it; skip the state-based row below.
            $staleNumbers[$num] = $true
            [void]$flags.Add('StaleLock')
        }

        $letterArr = Get-DiskLetters -Disk $d
        if ($null -eq $letterArr) { $letterArr = @() }

        [void]$rows.Add([pscustomobject]@{
            Number       = $num
            FriendlyName = $d.FriendlyName
            Bus          = $d.BusType
            Size         = Format-SizeGB ([UInt64]$d.Size)
            Offline      = $false
            Letters      = ($letterArr -join ',')
            Flags        = $(if ($flags.Count -gt 0) { $flags -join ',' } else { '-' })
            Serial       = (Format-SerialShort (Get-DiskProp $d 'SerialNumber' ''))
        })
    }

    # Locked disks: state.json only — do not probe the hardware.
    foreach ($num in ($lockedMap.Keys | Sort-Object)) {
        if ($staleNumbers.ContainsKey([int]$num)) { continue }
        $entry = $lockedMap[$num]
        $bus = '-'
        if ($entry.PSObject.Properties['BusType'] -and $entry.BusType) { $bus = [string]$entry.BusType }

        [void]$rows.Add([pscustomobject]@{
            Number       = [int]$entry.Number
            FriendlyName = $entry.FriendlyName
            Bus          = $bus
            Size         = (Get-LockedSizeText -Entry $entry)
            Offline      = $true
            Letters      = (Get-LockedLetters -Entry $entry)
            Flags        = $(if (Get-DiskProp $entry 'DeviceDisabled' $false) { 'Locked,PnPDisabled' } else { 'Locked' })
            Serial       = (Format-SerialShort $entry.SerialNumber)
        })
    }

    $rows = @($rows | Sort-Object Number)
    $rows | Format-Table -Property Number, FriendlyName, Bus, Size, Offline, Letters, Flags, Serial -AutoSize |
        Out-String -Width 200 | Write-Host
    if ($lockedMap.Count -gt 0) {
        Write-Host 'Note: Locked disks are listed from state only (not probed), so List will not spin them up.'
    }
}

function Invoke-Status {
    $state = Read-State
    if (-not $state.LockedDisks -or @($state.LockedDisks).Count -eq 0) {
        Write-Host 'No disks are currently recorded as locked.'
        return
    }

    # Do not call Get-Disk on locked volumes — that wakes them.
    $rows = foreach ($entry in @($state.LockedDisks)) {
        [pscustomobject]@{
            Number       = $entry.Number
            FriendlyName = $entry.FriendlyName
            Serial       = $entry.SerialNumber
            LockedAt     = $entry.LockedAt
            SavedLetters = (Get-LockedLetters -Entry $entry)
            Size         = (Get-LockedSizeText -Entry $entry)
            Flags        = $(if (Get-DiskProp $entry 'DeviceDisabled' $false) { 'Locked,PnPDisabled (not probed)' } else { 'Locked (not probed)' })
        }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host ("State file: {0}" -f $script:StatePath)
    Write-Host 'Status reads state.json only and does not query locked disks.'
}

function Lock-OneDisk {
    param(
        [Parameter(Mandatory)] $Disk,
        [switch] $SkipSecondStandby
    )

    $num = [int]$Disk.Number
    $lockedMap = Get-LockedDiskMap
    $alreadyTracked = $lockedMap.ContainsKey($num)
    $fromState = [bool](Get-DiskProp $Disk '_FromState' $false)
    $alreadyOffline = $fromState -or [bool](Get-DiskProp $Disk 'IsOffline' $false)
    $usePnpDisable = -not $Soft

    # Already offline + already in state: do not snapshot or wipe letters.
    if ($alreadyOffline -and $alreadyTracked) {
        $entry = $lockedMap[$num]
        $letterList = Get-LockedLetters -Entry $entry
        if (-not $letterList) { $letterList = '(saved)' }
        Write-Host ("--- Disk {0}  {1} already locked (Letters={2})." -f `
            $num, $Disk.FriendlyName, $letterList)

        $deviceDisabled = [bool](Get-DiskProp $entry 'DeviceDisabled' $false)
        if (-not $deviceDisabled) {
            # Soft locks / older state: try ATA, then optionally upgrade to PnP disable.
            $spun = Invoke-DiskSpinDown -Number $num
            if ($spun) {
                Write-Host ("  Spindown accepted for PhysicalDrive{0}." -f $num)
                if (-not $SkipSecondStandby) {
                    Start-Sleep -Milliseconds 1500
                    [void](Invoke-DiskSpinDown -Number $num -Quiet)
                }
            } else {
                Write-Warning ("  Spindown IOCTL failed for disk {0}." -f $num)
            }

            if ($usePnpDisable) {
                $pnpId = Get-DiskProp $entry 'PnpDeviceId' $null
                if (-not $pnpId) { $pnpId = Get-DiskPnpInstanceId -Number $num }
                if ($pnpId) {
                    $disabled = Disable-DiskPnpDevice -InstanceId $pnpId -DiskNumber $num
                    $state = Read-State
                    foreach ($e in @($state.LockedDisks)) {
                        if ([int]$e.Number -eq $num) {
                            $e | Add-Member -NotePropertyName PnpDeviceId -NotePropertyValue $pnpId -Force
                            $e | Add-Member -NotePropertyName DeviceDisabled -NotePropertyValue ([bool]$disabled) -Force
                        }
                    }
                    Write-State -State $state
                    if ($disabled) {
                        Write-Host '  Upgraded lock to PnP-disabled.'
                    }
                } else {
                    Write-Warning '  Could not resolve PnP InstanceId; left as offline-only lock.'
                }
            }
        } else {
            Write-Host '  Already PnP-disabled; nothing to probe (OS cannot open the device).'
        }
        return
    }

    if (Test-IsProtectedDisk -Disk $Disk) {
        throw ("Refusing to lock protected disk {0} ({1})." -f $Disk.Number, (Get-ProtectedReason -Disk $Disk))
    }

    Assert-AllowlistIfConfigured -Disk $Disk

    if ($alreadyOffline -and -not $alreadyTracked) {
        Write-Warning ("Disk {0} is offline but not in state.json; locking without saved drive letters." -f $num)
    }

    $parts = Get-PartitionSnapshot -Disk $Disk
    if ($null -eq $parts) { $parts = @() }
    $parts = @($parts)

    if ($parts.Count -eq 0 -and $alreadyTracked) {
        $old = @($lockedMap[$num].Partitions)
        if (@($old).Count -gt 0) {
            Write-Warning ("Disk {0}: live snapshot has no letters; keeping previously saved partition letters." -f $num)
            $parts = @($old)
        }
    }

    $letterList = @($parts | ForEach-Object { $_.DriveLetter }) -join ', '
    if (-not $letterList) {
        $letterList = '(no letters)'
        Write-Warning ("Disk {0} has no drive letters to save; Unlock will not be able to restore letters." -f $num)
    }

    Write-Host ("--- Locking Disk {0}  {1}  Serial={2}  Letters={3}" -f `
        $Disk.Number, $Disk.FriendlyName, ([string](Get-DiskProp $Disk 'SerialNumber' '')).Trim(), $letterList)

    # Capture PnP id while the device is still present.
    $pnpId = Get-DiskPnpInstanceId -Number $num

    $snapshot = [pscustomobject]@{
        Number         = [int]$Disk.Number
        UniqueId       = [string](Get-DiskProp $Disk 'UniqueId' '')
        SerialNumber   = ([string](Get-DiskProp $Disk 'SerialNumber' '')).Trim()
        FriendlyName   = [string]$Disk.FriendlyName
        BusType        = [string]$Disk.BusType
        SizeBytes      = [UInt64](Get-DiskProp $Disk 'Size' 0)
        LockedAt       = (Get-Date).ToString('o')
        Partitions     = @($parts)
        PnpDeviceId    = $pnpId
        DeviceDisabled = $false
    }

    $fsutil = Join-Path $env:SystemRoot 'System32\fsutil.exe'
    foreach ($p in $parts) {
        try {
            if (Test-Path -LiteralPath $fsutil) {
                & $fsutil volume flush ("{0}:" -f $p.DriveLetter) *> $null
            }
        } catch { }
    }

    if (-not $alreadyOffline) {
        try {
            Set-Disk -Number $Disk.Number -IsOffline $true -ErrorAction Stop
            Write-Host ("  Disk {0} is offline." -f $Disk.Number)
        } catch {
            throw ("Failed to take disk {0} offline: {1}" -f $Disk.Number, $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 800
    } else {
        Write-Host ("  Disk {0} was already offline." -f $Disk.Number)
    }

    $spun = Invoke-DiskSpinDown -Number ([int]$Disk.Number)
    if ($spun) {
        Write-Host ("  Spindown accepted for PhysicalDrive{0}." -f $Disk.Number)
        if (-not $SkipSecondStandby) {
            Start-Sleep -Milliseconds 1500
            if (Invoke-DiskSpinDown -Number ([int]$Disk.Number) -Quiet) {
                Write-Host '  Second spindown accepted.'
            }
        }
    } else {
        Write-Warning ("  Spindown IOCTL failed for disk {0}. Stays locked (inaccessible); may spin down via APM." -f $Disk.Number)
    }

    if ($usePnpDisable) {
        if (-not $pnpId) {
            Write-Warning ("  No PnP InstanceId for disk {0}; left offline-only (use Device Manager manually if needed)." -f $num)
        } else {
            $disabled = Disable-DiskPnpDevice -InstanceId $pnpId -DiskNumber $num
            $snapshot.DeviceDisabled = [bool]$disabled
            if (-not $disabled) {
                Write-Host '  Continuing with offline + spindown lock (still effective against volume access).'
            }
        }
    } else {
        Write-Host '  Soft lock: skipped PnP disable (-Soft).'
    }

    $state = Read-State
    $remaining = @()
    foreach ($e in @($state.LockedDisks)) {
        $sameUnique = $snapshot.UniqueId -and $e.UniqueId -and ($e.UniqueId -eq $snapshot.UniqueId)
        $sameNumber = ($null -ne $e.Number) -and ([int]$e.Number -eq [int]$snapshot.Number)
        if (-not ($sameUnique -or $sameNumber)) {
            $remaining += $e
        }
    }
    $remaining += $snapshot
    $state.LockedDisks = $remaining
    Write-State -State $state

    Write-Host ("  Locked: Disk {0}." -f $Disk.Number)
}

function Invoke-Lock {
    Assert-Administrator
    $disks = Resolve-LockDiskList
    if ($null -eq $disks) { $disks = @() }
    $disks = @($disks)

    Write-Host ("Lock targets ({0}):" -f $disks.Count)
    $lockedMap = Get-LockedDiskMap
    foreach ($disk in $disks) {
        $num = [int]$disk.Number
        if ((Get-DiskProp $disk '_FromState' $false) -or (Get-DiskProp $disk 'IsOffline' $false) -or $lockedMap.ContainsKey($num)) {
            $letters = '-'
            if ($lockedMap.ContainsKey($num)) {
                $letters = Get-LockedLetters -Entry $lockedMap[$num]
                if (-not $letters) { $letters = '(locked)' }
            } else {
                $letters = '(offline)'
            }
            Write-Host ("  Disk {0}  {1}  Letters={2}" -f $disk.Number, $disk.FriendlyName, $letters)
        } else {
            $parts = Get-PartitionSnapshot -Disk $disk
            if ($null -eq $parts) { $parts = @() }
            $letterList = @($parts | ForEach-Object { $_.DriveLetter }) -join ', '
            if (-not $letterList) { $letterList = '(no letters)' }
            Write-Host ("  Disk {0}  {1}  Letters={2}" -f $disk.Number, $disk.FriendlyName, $letterList)
        }
    }

    if (-not $Force) {
        $modeHint = if ($Soft) { 'offline (soft)' } else { 'offline + PnP-disable (hard)' }
        $prompt = if ($disks.Count -eq 1) {
            "Spin down and lock this disk ($modeHint)? [y/N]"
        } else {
            ("Spin down and lock these {0} disks ({1})? [y/N]" -f $disks.Count, $modeHint)
        }
        $answer = Read-Host $prompt
        if ($answer -notmatch '^[Yy]') {
            Write-Host 'Aborted.'
            return
        }
    }

    $bulk = $disks.Count -gt 1
    $okCount = 0
    $failCount = 0
    foreach ($disk in $disks) {
        try {
            Lock-OneDisk -Disk $disk -SkipSecondStandby:$bulk
            $okCount++
        } catch {
            $failCount++
            Write-Warning ("Disk {0} failed: {1}" -f $disk.Number, $_.Exception.Message)
        }
    }

    Write-Host ("State saved: {0}" -f $script:StatePath)
    Write-Host ("Lock finished: {0} ok, {1} failed." -f $okCount, $failCount)
    try {
        Invoke-RespinDownLockedDisks -Reason 'Lock'
    } catch {
        Write-Warning ("Re-spindown after Lock failed: {0}" -f $_.Exception.Message)
    }
    if ($failCount -gt 0) {
        throw ("Lock completed with {0} failure(s)." -f $failCount)
    }
}

function Restore-DriveLetter {
    param(
        [Parameter(Mandatory)] $Disk,
        [Parameter(Mandatory)] $PartitionEntry
    )

    $wanted = ([string]$PartitionEntry.DriveLetter).ToUpperInvariant()
    $offset = [UInt64]$PartitionEntry.Offset

    $part = Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop |
        Where-Object { [UInt64]$_.Offset -eq $offset } |
        Select-Object -First 1

    if (-not $part) {
        Write-Warning ("Partition at offset {0} not found on disk {1}." -f $offset, $Disk.Number)
        return
    }

    $current = $null
    if ($part.DriveLetter -and [int][char]([string]$part.DriveLetter)[0] -ne 0) {
        $current = ([string]$part.DriveLetter).ToUpperInvariant()
    }
    if ($current -eq $wanted) {
        Write-Host ("  {0}: already assigned." -f $wanted)
        return
    }

    # Conflict check — only probe the wanted letter (never enumerate all partitions;
    # that wakes every locked HDD on the bus).
    $conflict = $null
    try {
        $existing = Get-Partition -DriveLetter $wanted -ErrorAction Stop
        if (-not (
                $existing.DiskNumber -eq $Disk.Number -and
                [UInt64]$existing.Offset -eq $offset
            )) {
            $conflict = $existing
        }
    } catch {
        # Letter is free
    }

    if ($conflict) {
        Write-Warning ("  Letter {0}: is in use by Disk {1}. Volume left online without that letter." -f $wanted, $conflict.DiskNumber)
        return
    }

    try {
        Set-Partition -DiskNumber $Disk.Number -Offset $offset -NewDriveLetter $wanted -ErrorAction Stop
        Write-Host ("  Restored {0}:" -f $wanted)
    } catch {
        Write-Warning ("  Failed to assign {0}: {1}" -f $wanted, $_.Exception.Message)
    }
}

function Unlock-OneDisk {
    param(
        [Parameter(Mandatory)] $Disk,
        $Entry
    )

    $num = [int]$Disk.Number
    Write-Host ("--- Unlocking Disk {0}  {1}" -f $num, $Disk.FriendlyName)

    # Hard locks: re-enable PnP before any Get-Disk / Set-Disk online.
    $pnpId = $null
    if ($Entry) { $pnpId = Get-DiskProp $Entry 'PnpDeviceId' $null }
    $wasDisabled = $Entry -and (Get-DiskProp $Entry 'DeviceDisabled' $false)

    if ($pnpId -and $wasDisabled) {
        Enable-DiskPnpDevice -InstanceId $pnpId
        Start-Sleep -Milliseconds 800
        $Disk = Wait-DiskNumberReady -Number $num -TimeoutSec 60
        Write-Host ("  Disk {0} reappeared." -f $num)
    } elseif ($pnpId) {
        # State may have id without disabled flag — ensure enabled anyway.
        try { Enable-DiskPnpDevice -InstanceId $pnpId } catch { }
        try { $Disk = Get-Disk -Number $num -ErrorAction Stop } catch { }
    }

    if (-not (Get-DiskProp $Disk '_FromState' $false)) {
        if (Test-IsProtectedDisk -Disk $Disk) {
            throw ("Refusing to manipulate protected disk {0} ({1})." -f $Disk.Number, (Get-ProtectedReason -Disk $Disk))
        }
    }

    if (Get-DiskProp $Disk 'IsOffline' $false) {
        Set-Disk -Number $Disk.Number -IsOffline $false -ErrorAction Stop
        Write-Host '  Disk is online.'
        Start-Sleep -Milliseconds 500
    } else {
        Write-Host '  Disk was already online.'
    }

    if ($Entry -and $Entry.Partitions) {
        foreach ($p in @($Entry.Partitions)) {
            Restore-DriveLetter -Disk $Disk -PartitionEntry $p
        }
    } else {
        Write-Warning '  No saved partition letters in state; assign letters manually in Disk Management if needed.'
    }

    if ($Entry) {
        $state = Read-State
        $remaining = @()
        foreach ($e in @($state.LockedDisks)) {
            $sameUnique = $Entry.UniqueId -and $e.UniqueId -and ($e.UniqueId -eq $Entry.UniqueId)
            $sameNumber = ($null -ne $e.Number) -and ([int]$e.Number -eq [int]$Entry.Number)
            if (-not ($sameUnique -or $sameNumber)) {
                $remaining += $e
            }
        }
        $state.LockedDisks = $remaining
        Write-State -State $state
    }

    Write-Host ("  Unlocked: Disk {0}." -f $Disk.Number)
}

function Invoke-Unlock {
    Assert-Administrator
    $jobs = Resolve-UnlockJobList
    if ($null -eq $jobs) { $jobs = @() }
    $jobs = @($jobs)

    Write-Host ("Unlock targets ({0}):" -f $jobs.Count)
    foreach ($job in $jobs) {
        Write-Host ("  Disk {0}  {1}" -f $job.Number, $job.Disk.FriendlyName)
    }

    if (-not $Force) {
        $prompt = if ($jobs.Count -eq 1) {
            'Bring this disk online and restore letters? [y/N]'
        } else {
            ("Bring these {0} disks online and restore letters? [y/N]" -f $jobs.Count)
        }
        $answer = Read-Host $prompt
        if ($answer -notmatch '^[Yy]') {
            Write-Host 'Aborted.'
            return
        }
    }

    $okCount = 0
    $failCount = 0
    foreach ($job in $jobs) {
        try {
            Unlock-OneDisk -Disk $job.Disk -Entry $job.Entry
            $okCount++
        } catch {
            $failCount++
            Write-Warning ("Disk {0} failed: {1}" -f $job.Number, $_.Exception.Message)
        }
    }

    Write-Host ("Unlock finished: {0} ok, {1} failed." -f $okCount, $failCount)
    try {
        Invoke-RespinDownLockedDisks -Reason 'Unlock'
    } catch {
        Write-Warning ("Re-spindown after Unlock failed: {0}" -f $_.Exception.Message)
    }
    if ($failCount -gt 0) {
        throw ("Unlock completed with {0} failure(s)." -f $failCount)
    }
}

function Invoke-Respin {
    Assert-Administrator
    $state = Read-State
    if (-not $state.LockedDisks -or @($state.LockedDisks).Count -eq 0) {
        Write-Host 'No disks are recorded as locked; nothing to re-spindown.'
        return
    }
    # Hard (PnP) locks have no PhysicalDrive handle until briefly re-enabled.
    Invoke-RespinDownLockedDisks -Reason 'Respin' -AllowPnpCycle
}

function Invoke-Install {
    Ensure-AppDataDir

    $scriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
        throw 'Could not resolve HddSpindown.ps1 path for install.'
    }

    $shimDir = $script:AppDataDir
    $cmdPath = Join-Path $shimDir 'hddspindown.cmd'
    $ps1ShimPath = Join-Path $shimDir 'hddspindown.ps1'

    # Batch launcher (works from cmd.exe and from PowerShell via PATH)
    $cmdLines = @(
        '@echo off'
        'setlocal'
        ('set "HDDSPINDOWN_SCRIPT={0}"' -f $scriptPath)
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HDDSPINDOWN_SCRIPT%" %*'
    )
    Set-Content -LiteralPath $cmdPath -Value ($cmdLines -join "`r`n") -Encoding ASCII

    # PowerShell-friendly shim (optional; same folder)
    $ps1Shim = @(
        '# Auto-generated shim — points at the real HddSpindown.ps1'
        ('& "{0}" @args' -f $scriptPath)
    )
    Set-Content -LiteralPath $ps1ShimPath -Value ($ps1Shim -join "`r`n") -Encoding UTF8

    # Add shim dir to user PATH if missing
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($null -eq $userPath) { $userPath = '' }
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
    $already = $false
    foreach ($p in $parts) {
        if ([string]::Equals($p.TrimEnd('\'), $shimDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            $already = $true
            break
        }
    }
    if (-not $already) {
        $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $shimDir } else { $userPath.TrimEnd(';') + ';' + $shimDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        # Update current process PATH so it works immediately in this session
        $env:Path = $env:Path.TrimEnd(';') + ';' + $shimDir
        Write-Host ("Added to user PATH: {0}" -f $shimDir)
    } else {
        Write-Host ("Already on user PATH: {0}" -f $shimDir)
        if ($env:Path -notmatch [regex]::Escape($shimDir)) {
            $env:Path = $env:Path.TrimEnd(';') + ';' + $shimDir
        }
    }

    Write-Host ("Launcher: {0}" -f $cmdPath)
    Write-Host ("Script:   {0}" -f $scriptPath)
    Write-Host ''
    Write-Host 'Open a new terminal (or use this session), then run:'
    Write-Host '  hddspindown List'
    Write-Host '  hddspindown Lock -DiskNumber 0,1 -Force'
    Write-Host 'Lock/Unlock/Respin will prompt for UAC when needed.'
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

# Auto-elevate actions that need admin (UAC prompt). List/Status/Install stay unelevated.
if ($Action -in @('Lock', 'Unlock', 'Respin')) {
    if (-not (Test-IsAdministrator)) {
        Request-ElevationAndExit
    }
}

switch ($Action) {
    'List'    { Invoke-List }
    'Status'  { Invoke-Status }
    'Lock'    { Invoke-Lock }
    'Unlock'  { Invoke-Unlock }
    'Respin'  { Invoke-Respin }
    'Install' { Invoke-Install }
    default   { throw "Unknown action: $Action" }
}
