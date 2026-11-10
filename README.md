# VHDX Boot Manager

A point-and-click Windows tool for running **several independent, bare-metal Windows installs** from `.vhdx` files, using Windows' built-in _native VHD boot_. You build one clean **base** Windows, then create as many lightweight **environments** (work, gaming, sandbox, ...) on top of it. Each environment stores only its own changes, so it starts at a few MB, boots on real hardware (no virtual machine), and can be snapshotted, rolled back or reset to fresh in seconds.

It is a single PowerShell script with a WinForms GUI. No installation, no dependencies. Every operation is a button with a hover description.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Getting started](#getting-started)
- [Typical workflow](#typical-workflow)
- [Tab reference](#tab-reference)
- [Answer files (autounattend.xml)](#answer-files-autounattendxml)
- [Files and folders the tool creates](#files-and-folders-the-tool-creates)
- [Safety features](#safety-features)
- [Limitations and good-to-know](#limitations-and-good-to-know)
- [Troubleshooting](#troubleshooting)
- [Under the hood](#under-the-hood)

---

## How it works

```
 ISO  --DISM apply-->  base.vhdx   (set up once, then locked, never booted again)
                          |
          +---------------+---------------+
          |               |               |
      work.vhdx      gaming.vhdx     sandbox.vhdx     <- differencing disks (children)
```

- The **base** is a normal dynamic VHDX with Windows applied from an ISO.
- Each **environment** is a _differencing_ VHDX whose parent is the base. It holds only what differs from the base.
- Every VHDX gets its own entry in the Windows boot menu (BCD), and you pick one at startup.
- Because children depend on the base, the base is **locked** (read-only, removed from the boot menu) once environments exist.

## Requirements

| Need                                                        | Notes                                                                                |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Windows 10 / 11 **Pro, Enterprise or Education**            | Windows Home cannot boot from a VHDX.                                                |
| **UEFI** firmware                                           | Checked by the _Check system_ tab.                                                   |
| **NTFS drive, not BitLocker / Device Encryption encrypted** | Native VHDX boot fails from an encrypted drive.                                      |
| Free space                                                  | About 25 GB minimum to build a base; plenty more for environments.                   |
| **Administrator rights**                                    | Needed for `diskpart`, `dism`, `bcdedit`. The script relaunches itself elevated.     |
| Windows PowerShell **5.1**                                  | Built into Windows. The script relaunches itself in 5.1 64-bit if started elsewhere. |
| An official **Windows ISO**                                 | e.g. from microsoft.com/software-download/windows11, or a custom ISO.                |

The Hyper-V PowerShell module is **optional**; if present it is used for exact disk info and standalone copies, otherwise the tool works around it.

## Getting started

1. Put `manager.ps1` and `Start VHDX Manager.cmd` in the same folder.
2. Double-click **`Start VHDX Manager.cmd`**. It unblocks the script and launches it hidden; accept the UAC prompt.

Alternatives:

```powershell
# Right-click manager.ps1 > "Run with PowerShell", or:
powershell.exe -ExecutionPolicy Bypass -File .\manager.ps1

# If the script was downloaded, unblock it first:
Unblock-File .\manager.ps1
```

At the top of the window set the **VHD folder** (default `C:\VHD`). Everything (disks, snapshots, backups, log) lives there. Use a plain ASCII path (no accents or quotes); `diskpart` and `bcdedit` require it.

## Typical workflow

1. **Check system** tab: _Run system check_. Fix anything marked FAIL.
2. **Create base** tab: pick the ISO, _Read editions_, choose an edition (Pro is preselected), optionally pick an answer file, click _Create base VHDX_. Takes about 5-15 minutes.
3. Restart into the base from the boot menu and finish Windows setup (or let your [answer file](#answer-files-autounattendxml) do it). Install drivers, Windows Updates and the apps **every** environment should have. Keep it lean.
4. _Optional:_ run sysprep inside the base (button _Copy sysprep command_) as the very last step so every environment gets a unique identity.
5. Shut down, start your normal Windows, open the tool.
6. **Environments** tab: select the base, _New environment from selected_. Repeat for each environment. Let the tool lock the base when asked.
7. From then on: boot an environment, snapshot before risky changes, reset or restore when needed. **Never boot or modify the base again**; everything depends on it.

## Tab reference

### Top bar

| Control                      | What it does                                                                                                                           |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| VHD folder                   | Where all files are kept. Inside a VHDX-booted Windows the physical drive has a different letter; the tool detects this automatically. |
| Browse... / Open in Explorer | Change or open the folder.                                                                                                             |
| Refresh everything           | Re-read VHDX files and the boot menu after changes made outside the tool.                                                              |

The window is resizable and can be maximized (minimum about 800x680; at small sizes the Create base tab scrolls and hides its side instructions). Lists, the system check output and the log grow with the window, and the button columns stay on the right edge. Window size and position are remembered in `%APPDATA%\VhdxBootManager\window.json`.

A description panel shows help text for whatever control you hover over, and a log box records every action (also written to `vhd-manager.log`).

### 1. Check system

Read-only. Checks Windows edition, UEFI, NTFS, free space, BitLocker/Device Encryption status of the VHD drive, whether you are currently booted from a VHDX, Hyper-V module availability and the current boot menu.

### 2. Create base

| Field                                          | Meaning                                                                                                                                                                                                                                                                                                                    |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Windows ISO / Browse / Read editions           | Mounts the ISO and lists its editions (like `dism /Get-WimInfo`).                                                                                                                                                                                                                                                          |
| Edition                                        | Which edition to apply. Home triggers a warning.                                                                                                                                                                                                                                                                           |
| File name                                      | Disk file name (letters, digits, `-`, `_`; `.vhdx` added). Tip: include the version, e.g. `base-25H2`.                                                                                                                                                                                                                     |
| Boot menu name                                 | Label shown in the boot menu.                                                                                                                                                                                                                                                                                              |
| Max size (GB)                                  | Largest size the dynamic disk can grow to (40-4000, default 100). All environments inherit it.                                                                                                                                                                                                                             |
| Add it to the boot menu                        | Creates the boot entry so you can set the base up. Your current default is unchanged.                                                                                                                                                                                                                                      |
| Don't expand the file to full size when booted | Writes `VirtualDiskExpandOnMount=4` into the new Windows so the file does not grow to its full maximum while booted. Risk: if the physical drive fills up, that Windows crashes.                                                                                                                                           |
| Answer file / Use ISO's autounattend.xml       | See [Answer files](#answer-files-autounattendxml).                                                                                                                                                                                                                                                                         |
| **Create base VHDX**                           | Creates and partitions the disk (`diskpart`), applies the edition with `DISM /Apply-Image`, applies the answer file and the no-expand setting, detaches the disk, adds the boot entry and offers to restart into it. A boot-config backup is taken first. If anything fails you are offered to delete the incomplete file. |
| Copy sysprep command                           | Copies `C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown` to the clipboard.                                                                                                                                                                                                                             |

### 3. Environments

Lists every `.vhdx` in the VHD folder with its type: **Base** (has children), **Child** (built on a base) or **Standalone** (no parent). The running one is marked `RUNNING`; locked ones `locked`.

| Button                                | What it does                                                                                                 |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| New environment from selected         | Creates a differencing child of the selected base, adds a boot entry, offers to lock the base.               |
| Snapshot                              | Copies the environment into `snapshots\` as `<name>__<timestamp>[_note].vhdx`.                               |
| Restore snapshot...                   | Rolls the environment back to a chosen snapshot.                                                             |
| Reset to fresh                        | Recreates the child empty on its base. Name and boot entry are kept. Ideal for throwaway sandboxes.          |
| Make standalone copy                  | Merges an environment with its base into one independent full disk.                                          |
| Open snapshots folder                 | Opens `snapshots\` in Explorer.                                                                              |
| Delete environment                    | Deletes the file, its boot entries and optionally its snapshots. Refused for a base that has children.       |
| Restart into this                     | Boots into it for one restart only (`bcdedit /bootsequence`); default unchanged.                             |
| Set as default boot                   | Makes it the automatic boot choice.                                                                          |
| Add / Rename / Remove boot menu entry | Manage its boot menu entry without touching the file.                                                        |
| Disable expand-on-boot                | Applies the no-expand registry setting to an existing environment.                                           |
| Lock / unlock                         | Read-only + removed from the boot menu (lock), or writable again (unlock; only when nothing is built on it). |

Most actions refuse to run on the Windows you are currently running, and refuse to change a base that has children.

### 4. Boot menu

A view of the Windows boot entries: set default, restart into an entry once, rename, delete an entry (files are never deleted), and set the boot menu wait time. Every change made here is backed up automatically; undo it on tab 5.

### 5. Backup / restore

Every state of the boot menu configuration (BCD) the tool has saved, **newest first** (date/time, reason, size).

- **Automatic backups:** before every change the tool makes to the boot menu (adding, removing, renaming or locking entries, default, wait time, creating a base or environment, restore) a timestamped backup is saved first. The reason (the action that caused it) is part of the file name. At most one backup is made per action, and none if nothing changed since the previous one.
- **Select a backup** to see the entries it contains, its default and wait time, any entries whose `.vhdx` file no longer exists, and what restoring it would add or remove compared to the current menu.

| Button                        | What it does                                                                                                                                                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Back up now                   | Saves the current configuration immediately, with an optional note. Manual backups (blue) are never pruned.                                                                                                    |
| Restore selected...           | Shows the changes, then replaces the whole boot configuration with the backup. The current state is saved first as a `before-restore` backup, so a restore can itself be undone. VHDX files are never touched. |
| Delete selected               | Deletes the selected backup file(s).                                                                                                                                                                           |
| Open backups folder           | Opens `bcd-backups\` in Explorer.                                                                                                                                                                              |
| Keep newest automatic backups | Older automatic backups are deleted beyond this number (default 100, each is only tens of KB).                                                                                                                 |

## Answer files (autounattend.xml)

Normally only Windows Setup reads `autounattend.xml`. This tool does **not** run Setup (it applies the image with DISM), so by itself an answer file in the ISO would be ignored. The tool therefore applies it for you:

1. **From the ISO:** after _Read editions_, if the ISO root contains `autounattend.xml`, the option _Use the autounattend.xml found in the ISO_ is enabled and ticked. If the ISO has a `sources\$OEM$` folder, `$$` is copied into `Windows\` and `$1` into the drive root (as Setup would).
2. **External file:** use the _Answer file_ box / Browse. A chosen file **overrides** the one in the ISO.

The file is validated (must be well-formed XML with `<unattend>` / `<settings>`), shown in the confirmation dialog, and copied byte-for-byte to `Windows\Panther\unattend.xml` inside the VHDX. Windows then processes it on the base's first boot.

**What works:** the `specialize`, `oobeSystem` and `offlineServicing` passes: computer name, locale / keyboard / time zone, skipping OOBE, creating the local account, auto-logon, `FirstLogonCommands`, `RunSynchronous` scripts, a product key set in the specialize pass, and so on.

**What cannot work:** the `windowsPE` pass only runs inside Setup. Disk layout, image/edition selection (use the edition picker instead), the Setup product key and TPM/Secure Boot bypass settings are ignored. The confirmation dialog lists any `windowsPE` components found so there are no surprises.

Notes:

- Specialize runs once, on the base's first boot. Child environments inherit the configured state. If you sysprep the base, each child runs specialize / oobeSystem again.
- Credentials in an answer file are stored in the VHDX; use throwaway or low-value passwords.

## Files and folders the tool creates

Inside the VHD folder:

| Path               | Purpose                                                                                                        |
| ------------------ | -------------------------------------------------------------------------------------------------------------- |
| `*.vhdx`           | Bases, environments and standalone disks.                                                                      |
| `snapshots\`       | Snapshot copies of environments.                                                                               |
| `bcd-backups\`     | Boot configuration backups, `bcd-YYYYMMDD-HHMMSS_<reason>` (the time shown in the tool is read from the name). |
| `vhd-manager.json` | Metadata (parent and max size) used when the VHDX header cannot be read.                                       |
| `vhd-manager.log`  | Log of everything the tool did.                                                                                |

## Safety features

- **Boot configuration is backed up before every change** (timestamped, with the reason), and on demand. Restore any earlier state from tab 5; restoring itself is backed up too.
- Confirmation dialogs for anything destructive (delete, reset, restore, overwrite).
- The currently running VHDX is protected from modification.
- Bases with children cannot be deleted, reset, unlocked or booted without warnings.
- Warnings for BitLocker-encrypted drives, Home editions and low disk space.
- Failed base creation offers to remove the incomplete file; the VHDX is always detached and the ISO unmounted.
- Your default Windows is never changed unless you click _Set as default_.

## Limitations and good-to-know

- **Hibernation and BitLocker** do not work inside a VHDX-booted Windows.
- **Windows version upgrades** (e.g. 24H2 to 25H2) cannot be installed in place: build a new base from the new ISO. Monthly cumulative updates work normally.
- A dynamic VHDX grows to its full maximum size while booted unless _don't expand_ is set. Keep enough free space or tick that option.
- Changing a base after children exist corrupts them. That is why the tool locks it.
- Activation: a digital licence normally activates the same edition you already have on the PC.
- Keep games and big data on a physical drive rather than inside the VHDX.
- The tool targets Windows PowerShell 5.1 and 64-bit Windows.

## Troubleshooting

| Problem                                       | Try                                                                                                                                                                                             |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Nothing happens when launching                | Run the `.cmd` file, or `Unblock-File .\manager.ps1`; accept the UAC prompt.                                                                                                                    |
| "VHD folder must be a full local folder path" | Use something like `C:\VHD`, ASCII characters only.                                                                                                                                             |
| Boot fails with an encryption-related error   | The VHD folder's drive is encrypted. Use another NTFS drive or turn off Device Encryption.                                                                                                      |
| Boot menu is wrong or missing entries         | Tab 5 _Backup / restore_: pick the backup from before the problem (newest first) and click _Restore selected..._.                                                                               |
| Answer file did nothing                       | Confirm the dialog listed it. Settings in the `windowsPE` pass are ignored; move them to `specialize` / `oobeSystem`. Check `C:\Windows\Panther\` inside the booted environment for setup logs. |
| Base creation failed midway                   | Accept deleting the incomplete file, check `vhd-manager.log`, retry.                                                                                                                            |
| An action says the environment is running     | Boot a different Windows (e.g. your normal one) and run the action from there.                                                                                                                  |

## Under the hood

The tool is a thin GUI over standard Windows utilities, so everything it does can be reproduced by hand:

| Task                                                                 | Tool                                                                                 |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Create / attach / format / detach disks, create differencing disks   | `diskpart`                                                                           |
| Apply the Windows image                                              | `dism /Apply-Image`, `Get-WindowsImage`                                              |
| Mount the ISO                                                        | `Mount-DiskImage`                                                                    |
| Boot menu entries, default, one-time boot, timeout, backup / restore | `bcdedit`                                                                            |
| No-expand setting                                                    | `reg load` / `reg add VirtualDiskExpandOnMount=4` on the offline SYSTEM hive         |
| Disk info (parent, size)                                             | Hyper-V `Get-VHD` when available, otherwise parsing the VHDX header / saved metadata |
| Merge into a standalone copy                                         | Hyper-V `Convert-VHD` when available, otherwise `diskpart create vdisk source=`      |

Run `manager.ps1` itself to see the source; it is a single, commented script.
