# HDD Spindown (Windows)

PowerShell tool to spin down selected mechanical HDDs and **hard-lock** them so Windows services (Search, Defender, indexing, etc.) cannot wake them again until you explicitly unlock.

Designed for secondary data drives that should stay parked most of the time.

## How it works

**Lock** (default, “hard” lock):

1. Saves partition layout and drive letters to state
2. Flushes volumes
3. Takes the disk **offline** (`Set-Disk -IsOffline $true`) — drive letters disappear
4. Sends **ATA STANDBY IMMEDIATE** to park the platters
5. Tries to **disable the disk in PnP** (Device Manager) for an extra layer of protection

**Unlock**:

1. Re-enables the PnP device (if it was disabled)
2. Brings the disk **online**
3. Restores saved drive letters

Offline is applied **before** standby, because the offline transition itself wakes the drive; spindown must run after that.

**Soft lock** (`-Soft`): offline + standby only — skips PnP disable. Easier to unlock, but less isolation from low-level disk access.

## Requirements

- Windows 10 or later
- PowerShell 5.1+
- Administrator rights for **Lock**, **Unlock**, and **Respin** (UAC prompt when needed)
- SATA/AHCI HDDs (typical desktop/laptop mechanical drives)

NVMe and SSDs are usually not the target; the tool refuses system/boot/pagefile/hibernation disks automatically.

## Installation

Clone or copy this repo, then from PowerShell:

```powershell
cd path\to\hdd-spindown-win
.\HddSpindown.ps1 Install
```

`Install` adds a `hddspindown` launcher to your **user** PATH:

- Launcher: `%LOCALAPPDATA%\HddSpindown\hddspindown.cmd`
- Points at the real `HddSpindown.ps1` wherever you installed it

Open a new terminal (or use the same session after install), then:

```powershell
hddspindown List
```

You can also run the script directly:

```powershell
.\HddSpindown.ps1 List
```

## Quick start

```powershell
# See disks (online disks from Windows; locked disks from state only — won't wake them)
hddspindown List

# Lock one disk by number (prompts for confirmation)
hddspindown Lock -DiskNumber 2

# Lock by drive letter, skip confirmation
hddspindown Lock -DriveLetter D -Force

# Lock several disks
hddspindown Lock -DiskNumber 2,3,4 -Force

# Soft lock (no PnP disable)
hddspindown Lock -DriveLetter F -Soft -Force

# Unlock and restore letters
hddspindown Unlock -DiskNumber 2
hddspindown Unlock -DriveLetter D,F

# What's locked (reads state only — does not probe disks)
hddspindown Status

# Re-send standby to locked disks (e.g. after reboot)
hddspindown Respin
```

`Lock`, `Unlock`, and `Respin` prompt for UAC if you are not already elevated.

## Commands

| Action | Admin | Description |
|--------|-------|-------------|
| `List` | No | Show online disks + locked disks from state |
| `Status` | No | Show locked disks from `state.json` only |
| `Lock` | Yes (UAC) | Offline, standby, optional PnP disable |
| `Unlock` | Yes (UAC) | Online, restore letters, clear lock state |
| `Respin` | Yes (UAC) | Re-send standby to all locked disks |
| `Install` | No | Add `hddspindown` to user PATH |

## Parameters

| Parameter | Used by | Description |
|-----------|---------|-------------|
| `-DiskNumber` | Lock, Unlock | Disk index, e.g. `2` or `2,3,4` |
| `-DriveLetter` | Lock, Unlock | Letter(s), e.g. `D` or `F,D,E` |
| `-Force` | Lock | Skip confirmation prompt |
| `-Soft` | Lock | Offline + standby only; skip PnP disable |

## After reboot

- **Offline** state usually persists across reboots — locked HDDs stay offline and letters stay hidden.
- **Standby** does **not** persist — drives spin up during boot/enumeration.
- **PnP-disabled** disks may not appear in `Get-Disk` until re-enabled.

The script does **not** run automatically at startup and does **not** watch for random spin-ups in the background. If locked drives are offline but still spinning after boot, run:

```powershell
hddspindown Respin
```

For **hard (PnP) locks**, `Respin` briefly enables each device, sends standby, then disables PnP again — required because a disabled disk has no `\\.\PhysicalDrive` handle.

## SATA sibling wake

Locking or unlocking one HDD on a shared SATA/AHCI controller can wake **other** drives on the same bus (Windows re-enumerates the host). After `Lock` / `Unlock`, the script re-sends standby to other locked disks that still have a `PhysicalDrive` handle. PnP-disabled siblings are skipped in that pass to avoid repeated enable/disable cycles; use `Respin` if you need them spun down again.

## Safety

The script **refuses** to lock disks that are:

- Windows system or boot disk
- Pagefile or hibernation disk
- Any disk with a system/boot partition

### Optional allowlist

Copy `config.example.json` to `config.json` (beside the script or in `%LOCALAPPDATA%\HddSpindown\`) and set `AllowedDisks` with `UniqueId` or `SerialNumber` entries. If the list is non-empty, only matching disks can be locked.

```json
{
  "AllowedDisks": [
    { "SerialNumber": "WD-WCC6Y7UYYK79" },
    { "UniqueId": "50014E2EB8CE13E1" }
  ]
}
```

Leave `AllowedDisks` empty to allow any non-system disk. Get identifiers from `hddspindown List` or `Get-Disk | Format-List Number, SerialNumber, UniqueId`.

## Files and paths

| Path | Purpose |
|------|---------|
| `HddSpindown.ps1` | Main script |
| `config.example.json` | Example allowlist |
| `%LOCALAPPDATA%\HddSpindown\state.json` | Locked disk records (letters, PnP id, etc.) |
| `%LOCALAPPDATA%\HddSpindown\hddspindown.cmd` | PATH launcher (after `Install`) |
| `%LOCALAPPDATA%\HddSpindown\config.json` | Optional user-level allowlist |

## Troubleshooting

### PnP disable fails (“Generic failure”, pending reboot)

Something may hold a raw disk handle (Task Manager Performance tab, SMART tools, backup software). Close those, reboot if a prior disable was pending, then run `Lock` again. Offline lock still works even when PnP disable fails.

### UAC prompt then nothing happens

Paths with spaces in the script location are handled by quoting the `-File` argument. If problems persist, run elevated PowerShell directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\HddSpindown.ps1" Unlock -DiskNumber 2
```

### Unlock does not restore letters

Letters are saved at lock time. If the disk had no letters when locked, assign them manually in Disk Management. Check `hddspindown Status` for saved letters.

### `List` shows `StaleLock`

State says locked but the disk is online — run `Unlock` to clean up, or lock again if you want it offline.

### Disk numbers changed

After PnP disable/enable or hardware changes, disk numbers can shift. The script matches by `UniqueId` / `SerialNumber` in state for unlock and respin.

## Limitations

- No background watcher — random spin-ups are **not** automatically chased with repeated standby commands (by design; reduces unnecessary wear from polling).
- Best effort on mixed storage setups (USB, some RAID, virtual disks).
- PnP disable behavior varies by Windows edition and open handles.
- `List` and `Status` intentionally avoid probing locked disks so listing does not wake them.
- Locking multiple disks at once, or running two instances concurrently, is not protected by a lock file — `state.json` writes could race. Run one `Lock`/`Unlock`/`Respin` at a time.

