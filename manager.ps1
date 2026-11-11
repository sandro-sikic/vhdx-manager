#Requires -Version 5.1
<#
.SYNOPSIS
    VHDX Boot Manager - a point-and-click GUI for running several bare-metal
    Windows environments from VHDX files (Windows "native VHD boot").

.DESCRIPTION
    Companion to windows-vhdx-native-boot-guide.md. Every step of that guide is
    a button here:
      1. Check system      - edition, UEFI, BitLocker, disk space
      2. Create base       - ISO -> new VHDX -> Windows applied -> boot menu entry
      3. Environments      - create / snapshot / restore / reset / copy / delete
      4. Boot menu         - default, rename, delete, restart-into, wait time
      5. Backup / restore  - timestamped boot-config backups, restore any earlier state

    Hover over any button to see what it does in the description panel.

.NOTES
    Run it with either of these:
      * Right-click the file > "Run with PowerShell"
      * powershell.exe -ExecutionPolicy Bypass -File .\VhdxBootManager.ps1
    If you downloaded it, first run:  Unblock-File .\VhdxBootManager.ps1
    The script asks for administrator rights (needed for diskpart, dism and bcdedit).
    Before every change to the boot menu it saves a timestamped backup of the
    boot configuration into <VHD folder>\bcd-backups (restore it on tab 5).
#>
# Test-only switches: -NoElevate skips the elevate/relaunch block; -AutoCloseSeconds N closes the window after N s;
# -ScreenshotDir <dir> saves page1..page5.png of the window and closes.
param([switch]$NoElevate, [int]$AutoCloseSeconds = 0, [string]$ScreenshotDir = '', [string]$VhdFolder = '')

# --------------------------------------------------------------------------
#  Relaunch elevated, 64-bit, in Windows PowerShell 5.1 (WinForms + DISM)
# --------------------------------------------------------------------------
$isAdmin =([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$is32on64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
$isCore = $PSVersionTable.PSEdition -eq 'Core'
if (-not $NoElevate -and (-not $isAdmin -or $is32on64 -or $isCore)) {
  $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if ($is32on64) { $exe = Join-Path $env:SystemRoot 'SysNative\WindowsPowerShell\v1.0\powershell.exe' }
  Start-Process -FilePath $exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', "`"$PSCommandPath`"")
  exit
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$Sys32 = Join-Path $env:SystemRoot 'System32'
$BcdEdit = Join-Path $Sys32 'bcdedit.exe'
$DiskPart = Join-Path $Sys32 'diskpart.exe'
$Dism = Join-Path $Sys32 'dism.exe'
$RegExe = Join-Path $Sys32 'reg.exe'
$CmdExe = Join-Path $Sys32 'cmd.exe'
$PsExe = Join-Path $Sys32 'WindowsPowerShell\v1.0\powershell.exe'
$OemEnc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
$GuidRx = '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
$SysprepCmd = 'C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown'

$script:Help = @{}
$script:HelpCounter = 0
$script:MountedIso = $null
$script:CurrentAction = ''      # name of the button action running (used as backup reason)
$script:BackedUpThisAction = $false  # at most one automatic boot-config backup per action
$script:LastBcdText = $null   # boot config text at the time of the last backup (skip identical backups)
$script:LastBackupFile = $null
$script:KeepBackups = 100     # newest automatic backups to keep (manual ones are never pruned)
$script:HasHyperV = [bool](Get-Command Get-VHD -ErrorAction SilentlyContinue)

# ==========================================================================
#  Logging, dialogs, busy state
# ==========================================================================
function Write-Log([string]$Message) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
  if ($script:LogBox) { $script:LogBox.AppendText($line + "`r`n") }
  try {
    $f = $script:TxtFolder.Text.Trim().TrimEnd('\')
    if ($f -and (Test-Path -LiteralPath $f)) { Add-Content -LiteralPath (Join-Path $f 'vhd-manager.log') -Value $line }
  }
  catch {}
  [System.Windows.Forms.Application]::DoEvents()
}

function Set-Status([string]$Text) {
  if ($script:StatusLbl) { $script:StatusLbl.Text = $Text }
  [System.Windows.Forms.Application]::DoEvents()
}

function Confirm-Action([string]$Text, [string]$Title = 'Please confirm') {
  $r = [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
  return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Show-Info([string]$Text, [string]$Title = 'VHDX Boot Manager') {
  [void][System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Read-Text([string]$Prompt, [string]$Title, [string]$Default = '') {
  return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $Default).Trim()
}

function Set-Busy([bool]$Busy) {
  $script:Tabs.Enabled = -not $Busy
  $script:TopPanel.Enabled = -not $Busy
  if ($Busy) { $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
  else { $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default }
  [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-Action([string]$Name, [scriptblock]$Action) {
  Set-Busy $true
  Write-Log "=== $Name ==="
  $script:CurrentAction = $Name
  $script:BackedUpThisAction = $false
  try {
    & $Action
    Write-Log "--- finished: $Name"
  }
  catch {
    $msg = $_.Exception.Message
    Write-Log "ERROR: $msg"
    [void][System.Windows.Forms.MessageBox]::Show($script:Form, $msg, $Name, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
  }
  finally {
    Set-Busy $false
    Set-Status ''
  }
}

function Show-HelpText([string]$Title, [string]$Text) {
  $script:DescTitle.Text = $Title
  $script:DescText.Text = $Text
}

function Add-Help($Control, [string]$Title, [string]$Text) {
  if (-not $Control.Name) { $script:HelpCounter++; $Control.Name = "ctl$($script:HelpCounter)" }
  $script:Help[$Control.Name] = @($Title, $Text)
  $Control.Add_MouseEnter({ $h = $script:Help[$this.Name]; if ($h) { Show-HelpText $h[0] $h[1] } })
  $Control.Add_Enter({ $h = $script:Help[$this.Name]; if ($h) { Show-HelpText $h[0] $h[1] } })
}

# ==========================================================================
#  Running external tools without freezing the window
# ==========================================================================
function Read-NewOutput([string]$Path, $State, [bool]$Silent) {
  $buf = $null; $n = 0
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      if ($fs.Length -le $State.Pos) { return }
      [void]$fs.Seek($State.Pos, [IO.SeekOrigin]::Begin)
      $buf = New-Object byte[] ([int]($fs.Length - $State.Pos))
      $n = $fs.Read($buf, 0, $buf.Length)
      $State.Pos += $n
    }
    finally { $fs.Dispose() }
  }
  catch { return }
  if ($n -le 0) { return }

  $chunk = $OemEnc.GetString($buf, 0, $n)
  [void]$State.All.Append($chunk)
  $parts = ($State.Partial + $chunk) -split "`n"
  $State.Partial = $parts[-1]
  for ($i = 0; $i -lt $parts.Count - 1; $i++) {
    $seg = ($parts[$i] -split "`r") | Where-Object { $_.Trim() } | Select-Object -Last 1
    if (-not $seg) { continue }
    if ($seg -match '^\s*\[.*%') { Set-Status $seg.Trim() }       # DISM progress bar
    elseif (-not $Silent) { Write-Log ('    ' + $seg.Trim()) }
  }
  $last = ($State.Partial -split "`r") | Where-Object { $_.Trim() } | Select-Object -Last 1
  if ($last -and $last -match '^\s*\[.*%') { Set-Status $last.Trim() }
}

function Invoke-External {
  param([Parameter(Mandatory = $true)][string]$CommandLine, [switch]$Silent, [switch]$NoThrow)
  $out = [IO.Path]::GetTempFileName()
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $CmdExe
  $psi.Arguments = '/d /s /c "' + $CommandLine + ' > "' + $out + '" 2>&1"'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $state = @{ Pos = [long]0; Partial = ''; All = (New-Object System.Text.StringBuilder) }
  while (-not $proc.HasExited) {
    Start-Sleep -Milliseconds 150
    Read-NewOutput $out $state ([bool]$Silent)
    [System.Windows.Forms.Application]::DoEvents()
  }
  $proc.WaitForExit()
  Read-NewOutput $out $state ([bool]$Silent)
  if ($state.Partial.Trim() -and -not $Silent -and $state.Partial -notmatch '^\s*\[.*%') { Write-Log ('    ' + $state.Partial.Trim()) }
  $code = $proc.ExitCode
  Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
  Set-Status ''
  if ($code -ne 0 -and -not $NoThrow) { throw "Command failed (exit code $code). See the log for details.`r`n$CommandLine" }
  return [pscustomobject]@{ ExitCode = $code; Output = $state.All.ToString() }
}

function Invoke-Diskpart([string[]]$Lines) {
  $f = [IO.Path]::GetTempFileName()
  Set-Content -LiteralPath $f -Value $Lines -Encoding ASCII
  Write-Log ('diskpart: ' + ($Lines -join '  |  '))
  try {
    $r = Invoke-External -CommandLine ('"' + $DiskPart + '" /s "' + $f + '"') -Silent -NoThrow
    $useful = ($r.Output -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch 'Microsoft DiskPart|Copyright|On computer|^\s*DISKPART>' }
    foreach ($u in $useful) { Write-Log ('    ' + $u.Trim()) }
    if ($r.ExitCode -ne 0) { throw "diskpart failed (exit code $($r.ExitCode)). See the log for details." }
  }
  finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

$script:BcdChangingVerbs = @('/copy', '/delete', '/deletevalue', '/set', '/default', '/timeout', '/import', '/displayorder', '/bootsequence', '/create')
function Invoke-Bcd([string[]]$A) {
  # Every command that changes the boot configuration is preceded by an automatic backup
  # (once per action; skipped when nothing changed since the last backup).
  if ($script:BcdChangingVerbs -contains $A[0]) { Backup-Bcd }
  $ErrorActionPreference = 'Continue'
  $o = & $BcdEdit @A 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw ("bcdedit {0} failed: {1}" -f ($A -join ' '), $o.Trim()) }
  return $o
}

# ==========================================================================
#  Paths, drive letters, metadata
# ==========================================================================
function Get-VhdFolder {
  $f = $script:TxtFolder.Text.Trim().TrimEnd('\')
  if ($f -notmatch '^[A-Za-z]:\\.+') { throw 'The VHD folder must be a full local folder path, for example C:\VHD (not a drive root).' }
  if ($f -match "[^\x20-\x7E]|['`"]") { throw 'Please use a VHD folder path with plain English letters only (no accents or quotes) - diskpart and bcdedit need that.' }
  if (-not (Test-Path -LiteralPath $f)) {
    New-Item -ItemType Directory -Path $f -Force | Out-Null
    Write-Log "Created folder $f"
  }
  return $f
}

function ConvertTo-BcdVhd([string]$Path) {
  return 'vhd=[' + $Path.Substring(0, 2).ToUpper() + ']' + $Path.Substring(2)
}

function Get-FreeLetter {
  $used = @()
  $used += [IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() }
  $used += Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpper() }
  foreach ($l in 'V', 'W', 'X', 'Y', 'Z', 'U', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J') {
    if ($used -notcontains $l) { return $l }
  }
  throw 'No free drive letter available.'
}

function Get-MetaFile { return (Join-Path (Get-VhdFolder) 'vhd-manager.json') }

function Read-Meta {
  $h = @{}
  $f = Get-MetaFile
  if (Test-Path -LiteralPath $f) {
    try {
      $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
      foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = @{ parent = [string]$p.Value.parent; maxGB = [int]$p.Value.maxGB } }
    }
    catch { Write-Log "Could not read vhd-manager.json: $($_.Exception.Message)" }
  }
  return $h
}

function Save-Meta($h) { ($h | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Get-MetaFile) -Encoding UTF8 }

function Set-MetaEntry([string]$Leaf, [string]$Parent, [int]$MaxGB) {
  $h = Read-Meta
  $h[$Leaf.ToLower()] = @{ parent = $Parent; maxGB = $MaxGB }
  Save-Meta $h
}

function Remove-MetaEntry([string]$Leaf) {
  $h = Read-Meta
  if ($h.ContainsKey($Leaf.ToLower())) { $h.Remove($Leaf.ToLower()); Save-Meta $h }
}

# Reads the parent file name straight from the VHDX header (no Hyper-V needed).
# Returns '' = not a differencing disk, '?' = differencing but unknown parent, $null = could not read.
function Get-VhdxParentFromHeader([string]$Path) {
  $buf = $null; $len = 0
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      $len = [int][math]::Min($fs.Length, 8MB)
      $buf = New-Object byte[] $len
      $len = $fs.Read($buf, 0, $len)
    }
    finally { $fs.Dispose() }
  }
  catch { return $null }
  foreach ($off in 0, 1) {
    $t = [Text.Encoding]::Unicode.GetString($buf, $off, $len - $off)
    $i = $t.IndexOf('parent_linkage')
    if ($i -ge 0) {
      $m = [regex]::Match($t.Substring($i), '\\([^\\\x00-\x1F]{1,200}?\.vhdx)', 'IgnoreCase')
      if ($m.Success) { return $m.Groups[1].Value }
      return '?'
    }
  }
  return ''
}

# ==========================================================================
#  Boot configuration (BCD)
# ==========================================================================
function Get-BootEntries([string]$Which = 'osloader', [string]$Store = '') {
  $ErrorActionPreference = 'Continue'
  if ($Store) { $o = & $BcdEdit /store $Store /enum $Which /v 2>&1 | Out-String }
  else { $o = & $BcdEdit /enum $Which /v 2>&1 | Out-String }
  $list = @()
  foreach ($block in ($o -split '\r?\n\s*\r?\n')) {
    $kv = @()
    foreach ($l in ($block -split '\r?\n')) {
      if ($l -match '^(\S+)\s{2,}(\S.*)$') { $kv += , @($Matches[1], $Matches[2].Trim()) }
    }
    if ($kv.Count -lt 2) { continue }
    $id = [regex]::Match($kv[0][1], $GuidRx)
    if (-not $id.Success) { continue }
    $desc = $null
    foreach ($p in $kv) { if ($p[0] -match '^(description|beschreibung|opis|descripci|popis|omschrijving|descrizione)') { $desc = $p[1]; break } }
    if (-not $desc -and $kv.Count -ge 4) { $desc = $kv[3][1] }
    $vhd = $null; $dev = $kv[1][1]
    foreach ($p in $kv) {
      $m = [regex]::Match($p[1], 'vhd=\[([A-Za-z]:)\]([^,]+)')
      if ($m.Success) { $vhd = $m.Groups[1].Value.ToUpper() + $m.Groups[2].Value.Trim(); $dev = $p[1]; break }
    }
    $list += [pscustomobject]@{ Id = $id.Value; Description = $desc; Device = $dev; VhdPath = $vhd }
  }
  return , $list
}

function Get-RunningVhd {
  $c = Get-BootEntries '{current}'
  if ($c.Count) { return $c[0].VhdPath }
  return $null
}

# ---- boot configuration backups -------------------------------------------
# Files: <VHD folder>\bcd-backups\bcd-YYYYMMDD-HHMMSS_<reason>   (the time is read from the name)
function Get-BackupDir {
  $d = Join-Path (Get-VhdFolder) 'bcd-backups'
  New-Item -ItemType Directory -Path $d -Force | Out-Null
  return $d
}

function ConvertTo-Slug([string]$Text, [int]$Max = 40) {
  $s = ($Text.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
  if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max).Trim('-') }
  return $s
}

function Get-BcdText {
  $ErrorActionPreference = 'Continue'
  return (& $BcdEdit /enum all /v 2>&1 | Out-String)
}

# Automatic calls (no -Force): at most one backup per action, and none if nothing changed since the last one.
function Backup-Bcd([string]$Reason = '', [switch]$Force) {
  if (-not $Force -and $script:BackedUpThisAction) { return }
  $text = Get-BcdText
  if (-not $Force -and $script:LastBackupFile -and $text -eq $script:LastBcdText -and (Test-Path -LiteralPath $script:LastBackupFile)) {
    $script:BackedUpThisAction = $true
    return
  }
  if (-not $Reason) { $Reason = $script:CurrentAction }
  $slug = ConvertTo-Slug $Reason
  $dir = Get-BackupDir
  $base = 'bcd-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  if ($slug) { $base += "_$slug" }
  $file = Join-Path $dir $base; $n = 2
  while (Test-Path -LiteralPath $file) { $file = Join-Path $dir "$base-$n"; $n++ }
  Invoke-Bcd @('/export', $file) | Out-Null
  $script:BackedUpThisAction = $true
  $script:LastBcdText = $text
  $script:LastBackupFile = $file
  Write-Log "Boot configuration backed up: $(Split-Path $file -Leaf)"
  Remove-OldBackups
}

function Get-BcdBackups {
  $list = @()
  $dir = Join-Path (Get-VhdFolder) 'bcd-backups'
  if (-not (Test-Path -LiteralPath $dir)) { return , $list }
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match($f.Name, '^bcd-(\d{8})-(\d{6})(?:_(.*))?$')
    if (-not $m.Success) { continue }
    try { $t = [datetime]::ParseExact($m.Groups[1].Value + $m.Groups[2].Value, 'yyyyMMddHHmmss', $null) } catch { continue }
    $list += [pscustomobject]@{ Path = $f.FullName; Name = $f.Name; Time = $t; Reason = $m.Groups[3].Value; SizeKB = [math]::Round($f.Length / 1KB) }
  }
  return , @($list | Sort-Object Time -Descending)
}

function Remove-OldBackups {
  try {
    $auto = @(Get-BcdBackups | Where-Object { $_.Reason -notmatch '^manual' })
    if ($auto.Count -gt $script:KeepBackups) {
      foreach ($b in ($auto | Select-Object -Skip $script:KeepBackups)) { Remove-Item -LiteralPath $b.Path -Force -ErrorAction SilentlyContinue }
      Write-Log "Removed $($auto.Count - $script:KeepBackups) old automatic backup(s) (keeping the newest $($script:KeepBackups))."
    }
  }
  catch {}
}

function Get-BackupInfo($b) {
  $old = Get-BootEntries 'osloader' $b.Path
  $cur = Get-BootEntries
  $def = Get-BootEntries '{default}' $b.Path
  $lines = @("Backup of $($b.Time.ToString('yyyy-MM-dd HH:mm:ss'))  -  $(if ($b.Reason) { $b.Reason } else { 'older backup' })")
  $defName = '?'; if ($def.Count) { $defName = $def[0].Description }
  $lines += "Default at that time: $defName"
  $to = & $BcdEdit /store $b.Path /enum '{bootmgr}' 2>$null | Out-String
  $m = [regex]::Match($to, '(?im)^timeout\s+(\d+)')
  if ($m.Success) { $lines += "Boot menu wait: $($m.Groups[1].Value) s" }
  $lines += ''
  $lines += "Entries in this backup ($($old.Count)):"
  foreach ($e in $old) {
    $w = ''
    if ($e.VhdPath -and -not (Test-Path -LiteralPath $e.VhdPath)) { $w = '   [FILE MISSING]' }
    $lines += "  - $($e.Description)   $(if ($e.VhdPath) { $e.VhdPath } else { '(physical disk)' })$w"
  }
  $oldIds = @($old | ForEach-Object { $_.Id }); $curIds = @($cur | ForEach-Object { $_.Id })
  $gain = @($old | Where-Object { $curIds -notcontains $_.Id }); $lose = @($cur | Where-Object { $oldIds -notcontains $_.Id })
  $lines += ''
  $lines += 'Restoring it would:'
  if (-not $gain.Count -and -not $lose.Count) { $lines += '  - keep the same set of entries (names, default or wait time may change)' }
  foreach ($e in $gain) { $lines += "  + bring back entry '$($e.Description)'" }
  foreach ($e in $lose) { $lines += "  - remove entry '$($e.Description)'" }
  return ($lines -join "`r`n")
}

function Get-SelectedBackups {
  if ($script:BackupList.SelectedItems.Count -eq 0) { throw 'Select a backup in the list first.' }
  return @($script:BackupList.SelectedItems | ForEach-Object { $_.Tag })
}

function Update-BackupList {
  $script:BackupList.BeginUpdate()
  $script:BackupList.Items.Clear()
  try {
    foreach ($b in (Get-BcdBackups)) {
      $it = New-Object System.Windows.Forms.ListViewItem($b.Time.ToString('yyyy-MM-dd HH:mm:ss'))
      $r = $b.Reason; if (-not $r) { $r = '(older backup)' }
      [void]$it.SubItems.Add($r)
      [void]$it.SubItems.Add("$($b.SizeKB) KB")
      $it.Tag = $b
      if ($b.Reason -match '^manual') { $it.ForeColor = [System.Drawing.Color]::DarkBlue }
      [void]$script:BackupList.Items.Add($it)
    }
  }
  finally { $script:BackupList.EndUpdate() }
  $script:BackupInfo.Text = ''
  if ($script:BackupList.Items.Count) { $script:BackupList.Items[0].Selected = $true }
}

function Restore-BcdBackup {
  $sel = Get-SelectedBackups
  if ($sel.Count -ne 1) { throw 'Select exactly one backup to restore.' }
  $b = $sel[0]
  $info = Get-BackupInfo $b
  if (-not (Confirm-Action "Replace the ENTIRE boot menu configuration with the backup from $($b.Time.ToString('yyyy-MM-dd HH:mm:ss'))?`r`n`r`n$info`r`n`r`nVHDX files are not touched. A backup of the current state is made first, so you can undo this." 'Restore boot configuration')) { return }
  Backup-Bcd -Reason 'before-restore' -Force
  Invoke-Bcd @('/import', $b.Path) | Out-Null
  $script:LastBcdText = $null
  Write-Log "Boot configuration restored from $($b.Name)"
  Update-All
  Show-Info 'Boot configuration restored. The previous state was saved as a "before-restore" backup.' 'Restore'
}

function New-BootEntry([string]$VhdPath, [string]$Label) {
  if (-not $Label) { $Label = 'Win - ' + [IO.Path]::GetFileNameWithoutExtension($VhdPath) }
  $o = Invoke-Bcd @('/copy', '{current}', '/d', $Label)
  $m = [regex]::Match($o, $GuidRx)
  if (-not $m.Success) { throw "Could not read the new boot entry id from bcdedit: $o" }
  $g = $m.Value
  $dev = ConvertTo-BcdVhd $VhdPath
  Invoke-Bcd @('/set', $g, 'device', $dev)   | Out-Null
  Invoke-Bcd @('/set', $g, 'osdevice', $dev) | Out-Null
  try { Invoke-Bcd @('/set', $g, 'recoveryenabled', 'No')       | Out-Null } catch {}
  try { Invoke-Bcd @('/deletevalue', $g, 'recoverysequence')    | Out-Null } catch {}
  try { Invoke-Bcd @('/deletevalue', $g, 'resumeobject')        | Out-Null } catch {}
  try { Invoke-Bcd @('/displayorder', $g, '/addlast')           | Out-Null } catch {}
  Write-Log "Boot menu entry '$Label' $g -> $VhdPath"
  return $g
}

function Start-RestartInto([string]$Id, [string]$Label) {
  Invoke-Bcd @('/bootsequence', $Id) | Out-Null
  Write-Log "Next restart (one time only) will boot '$Label'."
  if (Confirm-Action "The next restart will boot into '$Label' (one time only; afterwards the normal default is used again).`r`n`r`nRestart now? Save your work first." 'Restart') {
    Write-Log 'Restarting in 5 seconds...'
    & (Join-Path $Sys32 'shutdown.exe') /r /t 5
  }
}

# ==========================================================================
#  Registry tweak: stop dynamic VHDX expanding to full size at boot
# ==========================================================================
function Set-NoExpandOffline([string]$WinRoot) {
  $hive = Join-Path $WinRoot 'Windows\System32\config\SYSTEM'
  if (-not (Test-Path -LiteralPath $hive)) { throw "No Windows registry found at $hive" }
  $ErrorActionPreference = 'Continue'
  $key = 'HKLM\VHDMGR_OFFLINE'
  & $RegExe load $key $hive 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not load the offline registry of that Windows.' }
  try {
    $sets = & $RegExe query $key 2>$null | Where-Object { $_ -match '\\ControlSet\d{3}\s*$' }
    foreach ($s in $sets) {
      & $RegExe add ($s.Trim() + '\Services\FsDepends\Parameters') /v VirtualDiskExpandOnMount /t REG_DWORD /d 4 /f 2>&1 | Out-Null
      Write-Log "    VirtualDiskExpandOnMount = 4 in $($s.Trim())"
    }
  }
  finally {
    [gc]::Collect(); Start-Sleep -Milliseconds 700
    & $RegExe unload $key 2>&1 | Out-Null
  }
}

function Set-NoExpandOnline {
  $ErrorActionPreference = 'Continue'
  & $RegExe add 'HKLM\SYSTEM\CurrentControlSet\Services\FsDepends\Parameters' /v VirtualDiskExpandOnMount /t REG_DWORD /d 4 /f 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not write the registry value.' }
  Write-Log 'VirtualDiskExpandOnMount = 4 set in the running Windows.'
}

function Mount-Vhdx([string]$Path) {
  Write-Log "Attaching $Path"
  $img = Mount-DiskImage -ImagePath $Path -PassThru
  Start-Sleep -Seconds 1
  $disk = $img | Get-Disk
  $part = Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
  if ("$($part.DriveLetter)" -notmatch '^[A-Za-z]$') {
    $part | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
    Start-Sleep -Seconds 1
    $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber
  }
  if ("$($part.DriveLetter)" -notmatch '^[A-Za-z]$') { throw 'Could not give the VHDX a drive letter.' }
  return "$($part.DriveLetter):\"
}

function Dismount-Vhdx([string]$Path) {
  Write-Log "Detaching $Path"
  Dismount-DiskImage -ImagePath $Path | Out-Null
}

# ==========================================================================
#  System checks
# ==========================================================================
function Get-EncryptionStatus([string]$DriveLetter) {
  # returns $true = encrypted, $false = not encrypted, $null = unknown
  try {
    $vol = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$DriveLetter'" -ErrorAction Stop
    if (-not $vol) { return $false }
    $c = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus -ErrorAction Stop
    return ($c.ConversionStatus -ne 0)
  }
  catch { return $null }
}

function Invoke-SystemCheck {
  $sb = New-Object System.Text.StringBuilder
  $add = { param($s, $m) [void]$sb.AppendLine(('[{0,-4}] {1}' -f $s, $m)) }

  & $add 'OK' 'Running as administrator.'
  $os = Get-CimInstance Win32_OperatingSystem
  & $add 'OK' ("This Windows: {0} (build {1})" -f $os.Caption, $os.BuildNumber)
  if ($os.Caption -match 'Home') {
    & $add 'WARN' 'Home edition. The Windows you put INSIDE the VHDX must be Pro, Enterprise or Education (pick that edition in step 2).'
  }

  if ($env:firmware_type -eq 'UEFI') { & $add 'OK' 'Firmware: UEFI.' }
  else { & $add 'WARN' "Firmware: $($env:firmware_type). This tool and guide assume UEFI." }

  $running = Get-RunningVhd
  if ($running) { & $add 'INFO' "You are currently booted from a VHDX: $running" }
  else { & $add 'INFO' 'You are currently booted from a normal (physical) Windows install.' }

  $folder = Get-VhdFolder
  $drive = New-Object IO.DriveInfo($folder.Substring(0, 1))
  if ($drive.DriveFormat -eq 'NTFS') { & $add 'OK' "VHD folder $folder is on an NTFS drive." }
  else { & $add 'FAIL' "VHD folder drive is $($drive.DriveFormat). It must be NTFS." }
  $freeGB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
  if ($freeGB -ge 150) { & $add 'OK' "Free space on $($drive.Name): $freeGB GB." }
  else { & $add 'WARN' "Free space on $($drive.Name): $freeGB GB. A dynamic VHDX can grow to its full size while booted - keep plenty free." }

  $enc = Get-EncryptionStatus $folder.Substring(0, 2)
  if ($enc -eq $true) { & $add 'FAIL' "Drive $($folder.Substring(0,2)) is BitLocker / Device Encryption encrypted. Native VHDX boot does not work from an encrypted drive: use another (unencrypted) NTFS drive or turn encryption off." }
  elseif ($enc -eq $false) { & $add 'OK' "Drive $($folder.Substring(0,2)) is not encrypted." }
  else { & $add 'WARN' 'Could not read the BitLocker status. Check it with: manage-bde -status' }

  if ($script:HasHyperV) { & $add 'OK' 'Hyper-V PowerShell module found (used for exact disk info and standalone copies).' }
  else { & $add 'INFO' 'Hyper-V module not installed - not required, the tool works around it.' }

  $entries = Get-BootEntries
  $def = Get-BootEntries '{default}'
  & $add 'INFO' ("Boot menu has {0} Windows entr{1}. Default: {2}" -f $entries.Count, $(if ($entries.Count -eq 1) { 'y' } else { 'ies' }), $(if ($def.Count) { $def[0].Description } else { '?' }))

  $vhdx = @(Get-ChildItem -LiteralPath $folder -Filter *.vhdx -File -ErrorAction SilentlyContinue)
  & $add 'INFO' "VHDX files in ${folder}: $($vhdx.Count)"

  [void]$sb.AppendLine()
  [void]$sb.AppendLine('Reminders: hibernation and BitLocker do not work inside a VHDX-booted Windows,')
  [void]$sb.AppendLine('and Windows version upgrades (e.g. 24H2 -> 25H2) cannot be installed in place:')
  [void]$sb.AppendLine('build a new base from the new ISO instead. Monthly updates work normally.')
  $script:CheckOut.Text = $sb.ToString()
  Write-Log 'System check complete (see the Check tab).'
}

# ==========================================================================
#  Step 2: create the base
# ==========================================================================
function Mount-Iso {
  $iso = $script:TxtIso.Text.Trim()
  if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { throw 'Choose a Windows ISO file first (Browse...).' }
  $iso = (Resolve-Path -LiteralPath $iso).Path
  $img = Get-DiskImage -ImagePath $iso
  if (-not $img.Attached) {
    Write-Log "Mounting ISO $iso"
    Mount-DiskImage -ImagePath $iso | Out-Null
    $script:MountedIso = $iso
    Start-Sleep -Seconds 2
  }
  $vol = Get-DiskImage -ImagePath $iso | Get-Volume
  if ("$($vol.DriveLetter)" -notmatch '^[A-Za-z]$') { throw 'The ISO is mounted but has no drive letter.' }
  return "$($vol.DriveLetter):\"
}

function Dismount-Iso {
  if ($script:MountedIso) {
    try { Dismount-DiskImage -ImagePath $script:MountedIso | Out-Null; Write-Log 'ISO unmounted.' } catch {}
    $script:MountedIso = $null
  }
}

function Get-InstallImage([string]$Root) {
  foreach ($n in 'install.wim', 'install.esd') {
    $p = Join-Path $Root "sources\$n"
    if (Test-Path -LiteralPath $p) { return $p }
  }
  throw 'This ISO has no sources\install.wim or install.esd. Use an official Windows ISO from Microsoft.'
}

function Read-Editions {
  $root = Mount-Iso
  $wim = Get-InstallImage $root
  Write-Log "Reading editions from $wim"
  $imgs = @(Get-WindowsImage -ImagePath $wim)
  $script:CmbEdition.Items.Clear()
  foreach ($i in $imgs) { [void]$script:CmbEdition.Items.Add(('{0} - {1}' -f $i.ImageIndex, $i.ImageName)) }
  $pick = 0
  for ($k = 0; $k -lt $script:CmbEdition.Items.Count; $k++) {
    if ($script:CmbEdition.Items[$k] -match ' Pro$') { $pick = $k; break }
  }
  if ($script:CmbEdition.Items.Count) { $script:CmbEdition.SelectedIndex = $pick }
  Write-Log "Found $($imgs.Count) edition(s)."
  Update-IsoAnswerOption $root
}

# ---- answer file (autounattend.xml) support ----
# DISM /Apply-Image does not run Windows Setup, so autounattend.xml is never read by itself.
# We copy it to Windows\Panther\unattend.xml in the new image: Windows then processes the
# specialize / oobeSystem / offlineServicing passes on first boot (windowsPE-pass settings cannot apply).
function Get-IsoAnswerPath([string]$Root) {
  $p = Join-Path $Root 'autounattend.xml'
  if (Test-Path -LiteralPath $p) { return $p }
  return $null
}

function Update-IsoAnswerOption([string]$Root) {
  $p = Get-IsoAnswerPath $Root
  if ($p) {
    $script:ChkIsoAnswer.Enabled = $true
    $script:ChkIsoAnswer.Checked = $true
    $script:ChkIsoAnswer.Text = 'Use the autounattend.xml found in the ISO (and its $OEM$ folder, if any)'
    Write-Log 'This ISO contains an autounattend.xml - it will be applied unless you choose another answer file.'
  }
  else {
    $script:ChkIsoAnswer.Checked = $false
    $script:ChkIsoAnswer.Enabled = $false
    $script:ChkIsoAnswer.Text = 'No autounattend.xml found in the ISO'
  }
}

# Returns $null (no answer file) or @{ Path; Source; Passes; Ignored }. Throws if the file is unusable.
function Resolve-AnswerFile([string]$Root) {
  $ext = $script:TxtAnswer.Text.Trim().Trim('"')
  $path = $null; $source = ''
  if ($ext) {
    if (-not (Test-Path -LiteralPath $ext -PathType Leaf)) { throw "Answer file not found: $ext" }
    $path = (Resolve-Path -LiteralPath $ext).Path; $source = 'chosen file'
  }
  elseif ($script:ChkIsoAnswer.Checked) {
    $path = Get-IsoAnswerPath $Root; $source = 'ISO'
  }
  if (-not $path) { return $null }
  try { $xml = New-Object System.Xml.XmlDocument; $xml.Load($path) }
  catch { throw "The answer file is not valid XML: $($_.Exception.Message)" }
  $passes = @(); $ignored = @()
  foreach ($s in @($xml.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'settings' })) {
    $pass = $s.GetAttribute('pass')
    if ($passes -notcontains $pass) { $passes += $pass }
    if ($pass -eq 'windowsPE') {
      foreach ($c in @($s.ChildNodes | Where-Object { $_.LocalName -eq 'component' })) { $ignored += $c.GetAttribute('name') }
    }
  }
  if ($xml.DocumentElement.LocalName -ne 'unattend' -or -not $passes.Count) { throw 'This file is not a Windows answer file (no <unattend> / <settings> found).' }
  return @{ Path = $path; Source = $source; Passes = $passes; Ignored = $ignored }
}

function Install-AnswerFile($Answer, [string]$Root, [string]$Drive) {
  $panther = Join-Path $Drive 'Windows\Panther'
  New-Item -ItemType Directory -Force -Path $panther | Out-Null
  $dst = Join-Path $panther 'unattend.xml'
  Copy-Item -LiteralPath $Answer.Path -Destination $dst -Force
  (Get-Item -LiteralPath $dst).Attributes = 'Normal'
  Write-Log "Answer file ($($Answer.Source)) copied to $dst"
  if ($Answer.Source -eq 'ISO') {
    $oem = Join-Path $Root 'sources\$OEM$'
    foreach ($m in @(@('$$', (Join-Path $Drive 'Windows')), @('$1', $Drive))) {
      $src = Join-Path $oem $m[0]
      if (Test-Path -LiteralPath $src) {
        Write-Log "Copying `$OEM`$ folder $($m[0]) -> $($m[1])"
        Copy-Item -Path (Join-Path $src '*') -Destination $m[1] -Recurse -Force
      }
    }
  }
}

function New-BaseVhdx {
  $folder = Get-VhdFolder
  $name = $script:TxtBaseName.Text.Trim()
  if ($name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw 'File name: use only letters, numbers, - or _ (max 40).' }
  $path = Join-Path $folder "$name.vhdx"
  if (Test-Path -LiteralPath $path) { throw "$path already exists. Pick another file name." }
  $sel = [string]$script:CmbEdition.SelectedItem
  if ($sel -notmatch '^(\d+) - (.+)$') { throw 'Pick the Windows ISO, click "Read editions", then choose an edition.' }
  $index = $Matches[1]; $edition = $Matches[2]
  if ($edition -match 'Home') {
    if (-not (Confirm-Action "'$edition' does not support booting from a VHDX. Use Pro, Enterprise or Education.`r`n`r`nContinue anyway?")) { return }
  }
  $gb = [int]$script:NumSize.Value
  $label = $script:TxtBootLabel.Text.Trim()
  if (-not $label) { $label = "Win - $name" }

  $enc = Get-EncryptionStatus $folder.Substring(0, 2)
  if ($enc -eq $true) {
    if (-not (Confirm-Action "Drive $($folder.Substring(0,2)) is encrypted (BitLocker / Device Encryption). Booting from a VHDX stored there will FAIL.`r`n`r`nContinue anyway?")) { return }
  }
  $free = [math]::Round((New-Object IO.DriveInfo($folder.Substring(0, 1))).AvailableFreeSpace / 1GB, 1)
  if ($free -lt 25) { throw "Only $free GB free on $($folder.Substring(0,2)). You need at least about 25 GB." }
  if ($free -lt $gb -and -not $script:ChkNoExpand.Checked) {
    if (-not (Confirm-Action "Only $free GB is free, but a $gb GB dynamic VHDX expands to its full size while booted (it will fail to boot if the space is missing).`r`n`r`nTick the 'Don't expand' option or choose a smaller size. Continue anyway?")) { return }
  }

  $root = Mount-Iso
  $wim = Get-InstallImage $root
  $answer = Resolve-AnswerFile $root
  $answerText = 'none'
  if ($answer) {
    $answerText = "$($answer.Source) ($(Split-Path $answer.Path -Leaf)), passes: $($answer.Passes -join ', ')"
    if ($answer.Ignored.Count) { $answerText += "`r`n  NOTE: windowsPE-pass settings cannot apply (Setup is not run): $($answer.Ignored -join ', ')" }
  }
  $summary = "Create $path`r`n  Edition: $edition`r`n  Max size: $gb GB (file grows as needed)`r`n  Boot menu: $(if ($script:ChkAddBoot.Checked) { $label } else { 'not added' })`r`n  Answer file: $answerText`r`n`r`nThis takes about 5-15 minutes. Continue?"
  if (-not (Confirm-Action $summary 'Create base VHDX')) { return }

  $letter = Get-FreeLetter
  $volName = $name.Substring(0, [Math]::Min(32, $name.Length))
  Invoke-Diskpart @(
    "create vdisk file=`"$path`" maximum=$($gb * 1024) type=expandable",
    'attach vdisk',
    'create partition primary',
    "format fs=ntfs quick label=`"$volName`"",
    "assign letter=$letter"
  )
  $ok = $false
  try {
    Write-Log "Applying '$edition' into the VHDX (5-15 minutes, progress is shown above the log)..."
    Invoke-External -CommandLine ('"' + $Dism + '" /Apply-Image /ImageFile:"' + $wim + '" /Index:' + $index + ' /ApplyDir:' + $letter + ':\') | Out-Null
    if ($answer) { Install-AnswerFile $answer $root ($letter + ':\') }
    if ($script:ChkNoExpand.Checked) { Set-NoExpandOffline ($letter + ':\') }
    $ok = $true
  }
  finally {
    try { Invoke-Diskpart @("select vdisk file=`"$path`"", 'detach vdisk') } catch { Write-Log "Detach failed: $($_.Exception.Message)" }
    if (-not $ok -and (Test-Path -LiteralPath $path)) {
      if (Confirm-Action "Creating the base failed. Delete the incomplete file $path ?") {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-Log 'Incomplete VHDX deleted.'
      }
    }
  }
  Set-MetaEntry "$name.vhdx" '' $gb
  $g = $null
  if ($script:ChkAddBoot.Checked) { $g = New-BootEntry $path $label }
  Dismount-Iso
  Update-EnvList; Update-BootList

  $setupHint = 'Finish Windows setup,'
  if ($answer) { $setupHint = 'Windows setup runs using your answer file (check it completes),' }
  $next = "Base created: $path`r`n`r`nNext steps:`r`n 1. Restart and choose '$label' in the boot menu.`r`n 2. $setupHint install drivers, Windows Update and the apps EVERY environment should have.`r`n 3. (Optional) run sysprep - see 'Copy sysprep command'.`r`n 4. Shut down, start your normal Windows, open this tool, go to the Environments tab, select the base and click 'New environment from selected'."
  Show-Info $next 'Base created'
  if ($g) { Start-RestartInto $g $label }
}

# ==========================================================================
#  Step 3: environments
# ==========================================================================
function Get-Environments {
  $folder = Get-VhdFolder
  $meta = Read-Meta
  $entries = Get-BootEntries
  $running = Get-RunningVhd
  $envs = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter *.vhdx -File -ErrorAction SilentlyContinue)) {
    $parent = $null; $maxGB = 0
    if ($script:HasHyperV) {
      try {
        $v = Get-VHD -Path $f.FullName -ErrorAction Stop
        if ($v.ParentPath) { $parent = Split-Path $v.ParentPath -Leaf } else { $parent = '' }
        $maxGB = [int][math]::Ceiling($v.Size / 1GB)
      }
      catch {}
    }
    if ($null -eq $parent) { $parent = Get-VhdxParentFromHeader $f.FullName }
    $m = $meta[$f.Name.ToLower()]
    if (($null -eq $parent -or $parent -eq '?') -and $m) { $parent = $m.parent }
    if (-not $maxGB -and $m) { $maxGB = $m.maxGB }
    $boot = @($entries | Where-Object { $_.VhdPath -and ($_.VhdPath -ieq $f.FullName) })
    $isRunning = [bool]($running -and ($running -ieq $f.FullName))
    $envs += [pscustomobject]@{
      Name = $f.BaseName; Leaf = $f.Name; Path = $f.FullName; Parent = $parent
      SizeGB = [math]::Round($f.Length / 1GB, 2); MaxGB = $maxGB; Boot = $boot
      IsRunning = $isRunning; ReadOnly = $f.IsReadOnly; Children = @(); Type = ''
    }
  }
  foreach ($e in $envs) {
    $e.Children = @($envs | Where-Object { $_.Parent -and ($_.Parent -ieq $e.Leaf) } | ForEach-Object { $_.Name })
    if ($e.Parent) { $e.Type = 'Child' }
    elseif ($e.Children.Count) { $e.Type = 'Base' }
    else { $e.Type = 'Standalone' }
  }
  return , $envs
}

function Update-EnvList {
  $script:EnvList.BeginUpdate()
  $script:EnvList.Items.Clear()
  try {
    foreach ($e in (Get-Environments)) {
      $it = New-Object System.Windows.Forms.ListViewItem($e.Name)
      $parentName = '-'
      if ($e.Parent) { $parentName = [IO.Path]::GetFileNameWithoutExtension($e.Parent) }
      $bootName = '(none)'
      if ($e.Boot.Count) { $bootName = ($e.Boot | ForEach-Object { $_.Description }) -join ', ' }
      $status = ''
      if ($e.IsRunning) { $status = 'RUNNING' } elseif ($e.ReadOnly) { $status = 'locked' }
      [void]$it.SubItems.Add($e.Type)
      [void]$it.SubItems.Add($parentName)
      [void]$it.SubItems.Add(('{0:N2} GB' -f $e.SizeGB))
      $maxText = '-'; if ($e.MaxGB) { $maxText = "$($e.MaxGB) GB" }
      [void]$it.SubItems.Add($maxText)
      [void]$it.SubItems.Add($bootName)
      [void]$it.SubItems.Add($status)
      $it.Tag = $e
      if ($e.IsRunning) { $it.ForeColor = [System.Drawing.Color]::DarkGreen }
      elseif ($e.Type -eq 'Base') { $it.ForeColor = [System.Drawing.Color]::DarkBlue }
      [void]$script:EnvList.Items.Add($it)
    }
  }
  finally { $script:EnvList.EndUpdate() }
}

function Get-SelectedEnv {
  if ($script:EnvList.SelectedItems.Count -eq 0) { throw 'Select an environment in the list first.' }
  $name = $script:EnvList.SelectedItems[0].Tag.Name
  $e = (Get-Environments) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
  if (-not $e) { throw "'$name' no longer exists. Click Refresh." }
  return $e
}

function Assert-NotRunning($e) {
  if ($e.IsRunning) { throw "'$($e.Name)' is the Windows you are running right now. Start a different Windows (e.g. your normal one) to do this." }
}

function Assert-NoChildren($e) {
  if ($e.Children.Count) { throw "'$($e.Name)' is the base (parent) of: $($e.Children -join ', '). Changing it would corrupt those environments." }
}

function Get-EnvSummary($e) {
  $lines = @()
  switch ($e.Type) {
    'Base' { $lines += "BASE image - parent of: $($e.Children -join ', '). Never boot or change it." }
    'Child' { $lines += "Environment built on '$([IO.Path]::GetFileNameWithoutExtension($e.Parent))'. Stores only its own changes ($($e.SizeGB) GB)." }
    'Standalone' { $lines += "Standalone disk (no parent). Size on disk: $($e.SizeGB) GB." }
  }
  if ($e.Boot.Count) { $lines += 'Boot menu: ' + (($e.Boot | ForEach-Object { $_.Description }) -join ', ') }
  else { $lines += 'Not in the boot menu.' }
  if ($e.IsRunning) { $lines += 'This is the Windows you are running now.' }
  if ($e.ReadOnly) { $lines += 'File is locked (read-only).' }
  $lines += $e.Path
  return ($lines -join "`r`n")
}

function Lock-Env($e) {
  foreach ($b in $e.Boot) { Invoke-Bcd @('/delete', $b.Id) | Out-Null; Write-Log "Removed boot entry '$($b.Description)'" }
  Set-ItemProperty -LiteralPath $e.Path -Name IsReadOnly -Value $true
  Write-Log "'$($e.Name)' is now read-only and hidden from the boot menu."
}

function New-ChildEnv {
  $p = Get-SelectedEnv
  Assert-NotRunning $p
  if ($p.Type -eq 'Child') {
    if (-not (Confirm-Action "'$($p.Name)' is itself built on another disk. Building a new environment on top of it FREEZES '$($p.Name)': you must never boot or change it again.`r`n`r`nUsually you want to select the BASE instead. Continue anyway?")) { return }
  }
  $folder = Get-VhdFolder
  $name = Read-Text "Name for the new environment (letters, numbers, - or _), e.g. work, gaming, sandbox:" 'New environment' ''
  if (-not $name) { return }
  if ($name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw 'Use only letters, numbers, - or _.' }
  $path = Join-Path $folder "$name.vhdx"
  if (Test-Path -LiteralPath $path) { throw "$path already exists." }
  $label = Read-Text 'Name to show in the boot menu:' 'Boot menu name' "Win - $name"
  if (-not $label) { $label = "Win - $name" }

  Invoke-Diskpart @("create vdisk file=`"$path`" parent=`"$($p.Path)`"")
  Set-MetaEntry "$name.vhdx" $p.Leaf $p.MaxGB
  New-BootEntry $path $label | Out-Null
  Write-Log "Environment '$name' created on top of '$($p.Name)'."

  if ($p.Boot.Count -or -not $p.ReadOnly) {
    if (Confirm-Action "Lock '$($p.Name)' now? (recommended)`r`n`r`nIt becomes read-only and is removed from the boot menu, so it can't be booted or changed by accident - that would corrupt '$name'.") {
      $pName = $p.Name
      $p = (Get-Environments) | Where-Object { $_.Name -eq $pName } | Select-Object -First 1
      Lock-Env $p
    }
  }
}

function Save-Snapshot {
  $e = Get-SelectedEnv
  Assert-NotRunning $e
  $dir = Join-Path (Get-VhdFolder) 'snapshots'
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $note = Read-Text 'Optional short note for this snapshot (e.g. before-driver-update). Leave empty for none:' 'Snapshot' ''
  $note = ($note -replace '[^A-Za-z0-9_-]', '-').Trim('-')
  $file = '{0}__{1}' -f $e.Name, (Get-Date -Format 'yyyyMMdd-HHmmss')
  if ($note) { $file += "_$note" }
  $dest = Join-Path $dir "$file.vhdx"
  Write-Log "Copying $($e.SizeGB) GB to $dest ..."
  Invoke-External -CommandLine ('copy /y "' + $e.Path + '" "' + $dest + '"') -Silent | Out-Null
  Set-ItemProperty -LiteralPath $dest -Name IsReadOnly -Value $false
  Write-Log "Snapshot saved: $dest"
}

function Restore-Snapshot {
  $e = Get-SelectedEnv
  Assert-NotRunning $e
  Assert-NoChildren $e
  $dir = Join-Path (Get-VhdFolder) 'snapshots'
  if (-not (Test-Path -LiteralPath $dir)) { throw "No snapshots yet ($dir does not exist)." }
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.InitialDirectory = $dir
  $dlg.Filter = "Snapshots of $($e.Name)|$($e.Name)__*.vhdx|All VHDX files|*.vhdx"
  $dlg.Title = "Choose a snapshot to restore into '$($e.Name)'"
  if ($dlg.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
  if (-not (Confirm-Action "Replace '$($e.Name)' with:`r`n$([IO.Path]::GetFileName($dlg.FileName))`r`n`r`nEverything changed in '$($e.Name)' since that snapshot will be lost.")) { return }
  if ($e.ReadOnly) { Set-ItemProperty -LiteralPath $e.Path -Name IsReadOnly -Value $false }
  Invoke-External -CommandLine ('copy /y "' + $dlg.FileName + '" "' + $e.Path + '"') -Silent | Out-Null
  Set-ItemProperty -LiteralPath $e.Path -Name IsReadOnly -Value $false
  Write-Log "'$($e.Name)' restored from $($dlg.FileName)"
}

function Reset-Env {
  $e = Get-SelectedEnv
  Assert-NotRunning $e
  Assert-NoChildren $e
  if ($e.Type -ne 'Child' -or $e.Parent -eq '?') { throw "Reset only works for environments built on a base. '$($e.Name)' has no known parent." }
  $parentPath = Join-Path (Get-VhdFolder) $e.Parent
  if (-not (Test-Path -LiteralPath $parentPath)) { throw "The parent $parentPath is missing." }
  if (-not (Confirm-Action "Reset '$($e.Name)' to a fresh copy of '$([IO.Path]::GetFileNameWithoutExtension($e.Parent))'?`r`n`r`nEVERYTHING installed or saved inside '$($e.Name)' will be erased. (Take a snapshot first if unsure.)" 'Reset environment')) { return }
  Remove-Item -LiteralPath $e.Path -Force
  Invoke-Diskpart @("create vdisk file=`"$($e.Path)`" parent=`"$parentPath`"")
  Write-Log "'$($e.Name)' reset. Its boot menu entry still works."
}

function New-StandaloneCopy {
  $e = Get-SelectedEnv
  Assert-NotRunning $e
  $folder = Get-VhdFolder
  $name = Read-Text "Name for the independent copy of '$($e.Name)':" 'Standalone copy' "$($e.Name)-standalone"
  if (-not $name) { return }
  if ($name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw 'Use only letters, numbers, - or _.' }
  $path = Join-Path $folder "$name.vhdx"
  if (Test-Path -LiteralPath $path) { throw "$path already exists." }
  $gb = $e.MaxGB

  if ($e.Type -ne 'Child') {
    Write-Log "'$($e.Name)' has no parent - making a plain copy."
    Invoke-External -CommandLine ('copy /y "' + $e.Path + '" "' + $path + '"') -Silent | Out-Null
    Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $false
  }
  elseif ($script:HasHyperV) {
    Write-Log 'Merging the environment and its base into one file with Convert-VHD...'
    $cmd = '"' + $PsExe + '" -NoProfile -Command "Convert-VHD -Path ''' + $e.Path + ''' -DestinationPath ''' + $path + ''' -VHDType Dynamic"'
    Invoke-External -CommandLine $cmd | Out-Null
  }
  else {
    if (-not $gb) {
      $t = Read-Text "Maximum size of the base disk in GB (the new disk must be at least this big):" 'Size' '100'
      if (-not ($t -as [int])) { return }
      $gb = [int]$t
    }
    Write-Log 'Merging the environment and its base into one file with diskpart...'
    Invoke-Diskpart @("create vdisk file=`"$path`" source=`"$($e.Path)`" type=expandable maximum=$($gb * 1024)")
  }
  Set-MetaEntry "$name.vhdx" '' $gb
  Write-Log "Standalone copy created: $path"
  if (Confirm-Action "Add '$name' to the boot menu?") { New-BootEntry $path "Win - $name" | Out-Null }
}

function Remove-Env {
  $e = Get-SelectedEnv
  Assert-NotRunning $e
  Assert-NoChildren $e
  if (-not (Confirm-Action "Permanently DELETE '$($e.Name)' ($($e.SizeGB) GB) and its boot menu entries?`r`n`r`n$($e.Path)" 'Delete environment')) { return }
  foreach ($b in $e.Boot) { Invoke-Bcd @('/delete', $b.Id) | Out-Null; Write-Log "Removed boot entry '$($b.Description)'" }
  Remove-Item -LiteralPath $e.Path -Force
  Remove-MetaEntry $e.Leaf
  Write-Log "Deleted $($e.Path)"
  $snapDir = Join-Path (Get-VhdFolder) 'snapshots'
  $snaps = @(Get-ChildItem -LiteralPath $snapDir -Filter "$($e.Name)__*.vhdx" -File -ErrorAction SilentlyContinue)
  if ($snaps.Count -and (Confirm-Action "Also delete its $($snaps.Count) snapshot(s)?")) {
    $snaps | Remove-Item -Force
    Write-Log "Deleted $($snaps.Count) snapshot(s)."
  }
}

function Get-EnvBootEntry($e, [switch]$OfferToAdd) {
  if ($e.Boot.Count) { return $e.Boot[0] }
  if ($OfferToAdd -and (Confirm-Action "'$($e.Name)' is not in the boot menu. Add it now?")) {
    Assert-NoChildren $e
    $g = New-BootEntry $e.Path "Win - $($e.Name)"
    return [pscustomobject]@{ Id = $g; Description = "Win - $($e.Name)" }
  }
  throw "'$($e.Name)' is not in the boot menu."
}

function Switch-EnvLock {
  $e = Get-SelectedEnv
  if ($e.ReadOnly) {
    Assert-NoChildren $e
    Set-ItemProperty -LiteralPath $e.Path -Name IsReadOnly -Value $false
    Write-Log "'$($e.Name)' unlocked (writable)."
  }
  else {
    Assert-NotRunning $e
    if (-not (Confirm-Action "Lock '$($e.Name)'? It becomes read-only and its boot menu entries are removed.")) { return }
    Lock-Env $e
  }
}

function Disable-EnvExpand {
  $e = Get-SelectedEnv
  Assert-NoChildren $e
  if (-not (Confirm-Action "Stop '$($e.Name)' from growing to its full maximum size while booted?`r`n`r`nSaves disk space, but if the physical drive ever fills up, that Windows will crash. Keep free space.")) { return }
  if ($e.IsRunning) { Set-NoExpandOnline; return }
  $root = Mount-Vhdx $e.Path
  try { Set-NoExpandOffline $root } finally { Dismount-Vhdx $e.Path }
  Write-Log "Done for '$($e.Name)'."
}

# ---- change the maximum size of a disk ----
# Half of the free space, in whole GB (floor). Callers clamp it to their own limits.
function Get-HalfFreeGB([double]$FreeBytes) {
  return [int][math]::Min(1000000, [math]::Floor($FreeBytes / 1GB / 2))
}

# Suggested new max size for an existing disk: 50% of the free space (max 4000), but only if it is bigger than the current size; else 0.
function Get-SuggestedMaxGB([double]$FreeBytes, [int]$CurrentGB) {
  $s = [int][math]::Min(4000, (Get-HalfFreeGB $FreeBytes))
  if ($s -gt $CurrentGB) { return $s }
  return 0
}

# Parses the size typed by the user: integer 40..4000, otherwise throws.
function Convert-MaxGBInput([string]$Text) {
  if ($Text -notmatch '^\d{1,5}$') { throw 'Please enter the size as a whole number of GB (digits only), between 40 and 4000.' }
  $n = [int]$Text
  if ($n -lt 40 -or $n -gt 4000) { throw 'The size must be between 40 and 4000 GB.' }
  return $n
}

function Set-EnvMaxSize {
  $e = Get-SelectedEnv
  Assert-NotRunning $e
  if ($e.Type -eq 'Child') {
    throw "'$($e.Name)' is a differencing disk built on '$([IO.Path]::GetFileNameWithoutExtension($e.Parent))'. Differencing disks cannot be resized.`r`n`r`nUse 'Make standalone copy' first, then change the size of the copy."
  }
  if ($e.Children.Count) {
    throw "'$($e.Name)' is the base of: $($e.Children -join ', '). A base with environments built on it cannot be resized (that would corrupt them).`r`n`r`nUse 'Make standalone copy' on one of those environments, then change the size of the copy."
  }
  if ($e.ReadOnly) { throw "'$($e.Name)' is locked (read-only). Use 'Lock / unlock' to unlock it first, then try again." }
  $img = $null
  try { $img = Get-DiskImage -ImagePath $e.Path -ErrorAction Stop } catch {}
  if ($img -and $img.Attached) { throw "'$($e.Name)' is currently attached (mounted) in Windows. Detach it (Disk Management > Detach VHD) and try again." }

  $cur = [int]$e.MaxGB
  if ($cur -le 0) {
    try { $cur = [int][math]::Ceiling($img.Size / 1GB) } catch {}
  }
  if ($cur -le 0) { throw "Could not determine the current maximum size of '$($e.Name)'." }

  $drv = $e.Path.Substring(0, 2).ToUpper()
  $freeBytes = (New-Object IO.DriveInfo($e.Path.Substring(0, 1))).AvailableFreeSpace
  $freeGB = [math]::Round($freeBytes / 1GB, 1)
  $sug = Get-SuggestedMaxGB $freeBytes $cur
  $prompt = "New maximum size for '$($e.Name)' in GB (40-4000).`r`nCurrent: $cur GB.   Free space on ${drv}: $freeGB GB."
  $def = "$cur"
  if ($sug) { $prompt += "`r`n`r`nSuggested: $sug GB (50% of the free space on $drv)"; $def = "$sug" }
  $t = Read-Text $prompt 'Change max size' $def
  if (-not $t) { return }
  $new = Convert-MaxGBInput $t
  if ($new -eq $cur) { Show-Info "'$($e.Name)' already has a maximum size of $cur GB. Nothing to do." 'Change max size'; return }

  $grow = ($new -gt $cur)
  $summary = "Change the maximum size of '$($e.Name)':`r`n  $cur GB  ->  $new GB`r`n  Free space on ${drv}: $freeGB GB`r`n`r`nThe disk must not be in use (do not boot it or open files from it meanwhile)."
  if ($grow) {
    $summary += "`r`n`r`nThe virtual disk is enlarged and the Windows partition inside it is extended to use the new space."
    if ($new -gt $freeGB) { $summary += "`r`nNote: $new GB is more than the free space on $drv. The file only grows as data is added, but keep enough space free." }
  }
  else {
    if (-not $script:HasHyperV) { throw "Shrinking a disk needs the Hyper-V PowerShell module (Resize-VHD); diskpart cannot shrink a virtual disk. Install the Hyper-V PowerShell module, or choose a size larger than $cur GB." }
    $summary += "`r`n`r`nWARNING: SHRINKING. The partition inside is shrunk first; this only works if your data fits into $new GB. Make a snapshot or copy first if the data matters."
  }
  if (-not (Confirm-Action ($summary + "`r`n`r`nContinue?") 'Change max size')) { return }

  $path = $e.Path
  if ($grow) {
    # diskpart can only expand a DETACHED vdisk: expand first, then attach and extend the partition.
    Invoke-Diskpart @("select vdisk file=`"$path`"", "expand vdisk maximum=$($new * 1024)")
    Set-MetaEntry $e.Leaf $e.Parent $new
    Write-Log "'$($e.Name)' virtual disk enlarged from $cur GB to $new GB."
    $attached = $false
    try {
      $root = Mount-Vhdx $path; $attached = $true
      $letter = $root.Substring(0, 1)
      try { Update-HostStorageCache } catch {}
      $part = Get-Partition -DriveLetter $letter
      $max = (Get-PartitionSupportedSize -DriveLetter $letter).SizeMax
      if ($max -gt ($part.Size + 1MB)) {
        try { Resize-Partition -DriveLetter $letter -Size $max }
        catch {
          Write-Log "Resize-Partition failed ($($_.Exception.Message)); trying diskpart extend..."
          Invoke-Diskpart @("select volume $letter", 'extend')
        }
        Write-Log "Partition extended to use the new space."
      }
      else { Write-Log 'The partition cannot grow any further (another partition follows it). The extra space stays unallocated.' }
    }
    catch {
      Write-Log "The virtual disk WAS enlarged to $new GB, but the partition inside could not be extended: $($_.Exception.Message) Extend it later in Disk Management (or boot it and extend there)."
      throw
    }
    finally { if ($attached) { try { Dismount-Vhdx $path } catch { Write-Log "Detach failed: $($_.Exception.Message)" } } }
  }
  else {
    $newBytes = [int64]$new * 1GB
    $attached = $false
    try {
      $root = Mount-Vhdx $path; $attached = $true
      $letter = $root.Substring(0, 1)
      try { Update-HostStorageCache } catch {}
      $part = Get-Partition -DriveLetter $letter
      $others = [int64]0
      foreach ($op in @(Get-Partition -DiskNumber $part.DiskNumber)) { if ($op.PartitionNumber -ne $part.PartitionNumber) { $others += [int64]$op.Size } }
      $slack = 32MB   # GPT headers, alignment
      $target = [int64]([math]::Floor(($newBytes - $others - $slack) / 1MB) * 1MB)
      $min = [int64](Get-PartitionSupportedSize -DriveLetter $letter).SizeMin
      if ($target -lt $min) {
        $needGB = [int][math]::Ceiling(($min + $others + $slack) / 1GB)
        throw "Not possible: the data inside '$($e.Name)' needs about $needGB GB at least (partition minimum $([math]::Round($min / 1GB, 1)) GB plus system partitions). Choose $needGB GB or more, or free up space inside it first."
      }
      if ($target -lt $part.Size) {
        Write-Log "Shrinking the partition to $([math]::Round($target / 1GB, 2)) GB..."
        Resize-Partition -DriveLetter $letter -Size $target
      }
    }
    catch {
      Write-Log "Shrink stopped before the virtual disk was changed: $($_.Exception.Message)"
      throw
    }
    finally { if ($attached) { try { Dismount-Vhdx $path } catch { Write-Log "Detach failed: $($_.Exception.Message)" } } }
    try {
      $minDisk = [int64](Get-VHD -Path $path).MinimumSize
      if ($newBytes -lt $minDisk) { throw "The virtual disk cannot be smaller than $([math]::Ceiling($minDisk / 1GB)) GB (data at the end of the disk cannot be moved)." }
      Resize-VHD -Path $path -SizeBytes $newBytes
    }
    catch {
      Write-Log "Virtual disk NOT shrunk (still $cur GB). The partition inside may already be smaller, which is safe: $($_.Exception.Message)"
      throw
    }
    Set-MetaEntry $e.Leaf $e.Parent $new
    Write-Log "'$($e.Name)' virtual disk shrunk from $cur GB to $new GB."
  }
  Write-Log "Max size of '$($e.Name)' is now $new GB."
}

# ==========================================================================
#  Step 4: boot menu
# ==========================================================================
function Update-BootList {
  $entries = Get-BootEntries
  $def = Get-BootEntries '{default}'; $defId = $null; if ($def.Count) { $defId = $def[0].Id }
  $cur = Get-BootEntries '{current}'; $curId = $null; if ($cur.Count) { $curId = $cur[0].Id }
  $script:BootList.BeginUpdate()
  $script:BootList.Items.Clear()
  foreach ($b in $entries) {
    $it = New-Object System.Windows.Forms.ListViewItem([string]$b.Description)
    $from = $b.Device; if ($b.VhdPath) { $from = $b.VhdPath }
    $st = @(); if ($b.Id -eq $defId) { $st += 'default' }; if ($b.Id -eq $curId) { $st += 'running' }
    [void]$it.SubItems.Add([string]$from)
    [void]$it.SubItems.Add(($st -join ', '))
    [void]$it.SubItems.Add($b.Id)
    $it.Tag = $b
    if ($b.Id -eq $defId) { $it.Font = New-Object System.Drawing.Font($script:BootList.Font, [System.Drawing.FontStyle]::Bold) }
    [void]$script:BootList.Items.Add($it)
  }
  $script:BootList.EndUpdate()
}

function Get-SelectedBoot {
  if ($script:BootList.SelectedItems.Count -eq 0) { throw 'Select a boot menu entry first.' }
  return $script:BootList.SelectedItems[0].Tag
}

function Assert-BootableEntry($b) {
  if ($b.VhdPath) {
    $e = (Get-Environments) | Where-Object { $_.Path -ieq $b.VhdPath } | Select-Object -First 1
    if ($e -and $e.Children.Count) { throw "'$($b.Description)' boots the base disk '$($e.Name)', which other environments are built on. Booting it would corrupt them." }
  }
}

# Free bytes on the drive of the VHD folder text (works even if the folder does not exist yet); $null if unknown.
function Get-FolderFreeBytes([string]$Folder) {
  try {
    $f = $Folder.Trim()
    if ($f -notmatch '^([A-Za-z]):') { return $null }
    $d = New-Object IO.DriveInfo($Matches[1])
    if (-not $d.IsReady) { return $null }
    return [double]$d.AvailableFreeSpace
  }
  catch { return $null }
}

# Create base: default max size = 50% of the free space on the VHD folder's drive (40..4000), until the user picks a value by hand.
function Update-DefaultBaseSize {
  if ($script:SizeTouched -or -not $script:NumSize -or -not $script:TxtFolder) { return }
  $free = Get-FolderFreeBytes $script:TxtFolder.Text
  if ($null -eq $free) { return }
  $gb = [math]::Max(40, [math]::Min(4000, (Get-HalfFreeGB $free)))
  if ([int]$script:NumSize.Value -ne $gb) {
    $script:SettingSize = $true
    try { $script:NumSize.Value = $gb } finally { $script:SettingSize = $false }
  }
}

function Update-All {
  try { Update-DefaultBaseSize } catch {}
  Update-EnvList
  Update-BootList
  Update-BackupList
}

# ==========================================================================
#  GUI  (minimal rounded sidebar style - see ui-concepts\11-merged.ps1)
# ==========================================================================
$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class Gfx {
    public static Color C(string h) { return ColorTranslator.FromHtml(h); }
    public static GraphicsPath Round(Rectangle r, int rad) {
        GraphicsPath p = new GraphicsPath();
        rad = Math.Min(rad, Math.Min(r.Width, r.Height) / 2);
        if (rad < 1) { p.AddRectangle(r); return p; }
        int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr h, string app, string idl);
    // thin modern scrollbars for native controls
    public static void Explorer(Control c) {
        try {
            if (c.IsHandleCreated) SetWindowTheme(c.Handle, "Explorer", null);
            c.HandleCreated += delegate { try { SetWindowTheme(c.Handle, "Explorer", null); } catch { } };
        } catch { }
    }
}

public class RBtn : Button {
    public string Kind = "ghost";
    public int Radius = 8;
    bool hot, down;
    public RBtn() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        Cursor = Cursors.Hand; FlatStyle = FlatStyle.Flat;
    }
    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Parent != null ? Parent.BackColor : Color.White);
        Color ink = Gfx.C("#111111");
        Color fill = Color.White, border, text; bool hasFill = false, dashed = false;
        if (!Enabled) {
            border = Gfx.C("#DDDDDD"); text = Gfx.C("#A6A6A6");
            if (Kind == "primary") { hasFill = true; fill = Gfx.C("#F7C2AA"); border = fill; text = Color.White; }
            else if (Kind == "danger") dashed = true;
        } else if (Kind == "primary") {
            hasFill = true; fill = down ? Gfx.C("#C73E00") : hot ? Gfx.C("#E04500") : Gfx.C("#FF4F00"); border = fill; text = Color.White;
        } else if (Kind == "danger") {
            dashed = true; border = ink; text = ink;
            if (hot || down) { hasFill = true; fill = down ? Gfx.C("#333333") : ink; text = Color.White; }
        } else {
            border = hot ? ink : Gfx.C("#BDBDBD"); text = ink;
            if (down) { hasFill = true; fill = Gfx.C("#EFEFEF"); } else if (hot) { hasFill = true; fill = Gfx.C("#F7F7F7"); }
        }
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath p = Gfx.Round(r, Radius)) {
            if (hasFill) using (SolidBrush b = new SolidBrush(fill)) g.FillPath(b, p);
            using (Pen pen = new Pen(border, 1f)) { if (dashed) pen.DashStyle = DashStyle.Dash; g.DrawPath(pen, p); }
        }
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, text,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis);
        if (Focused && ShowFocusCues && Enabled) {
            using (GraphicsPath fp = Gfx.Round(new Rectangle(3, 3, Width - 7, Height - 7), Math.Max(2, Radius - 3)))
            using (Pen pen = new Pen(hasFill && Kind == "primary" ? Color.White : ink)) { pen.DashStyle = DashStyle.Dot; g.DrawPath(pen, fp); }
        }
    }
}

public class RCard : Panel {
    public int Radius = 12;
    public Color Edge = Gfx.C("#DDDDDD");
    public RCard() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.White;
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Parent != null ? Parent.BackColor : Color.White);
        using (GraphicsPath p = Gfx.Round(new Rectangle(0, 0, Width - 1, Height - 1), Radius))
        using (SolidBrush b = new SolidBrush(BackColor)) using (Pen pen = new Pen(Edge)) { g.FillPath(b, p); g.DrawPath(pen, p); }
    }
}

public class RCheck : CheckBox {
    public RCheck() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
    }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Parent != null ? Parent.BackColor : Color.White);
        int s = 18, y = (Height - s) / 2;
        Rectangle rc = new Rectangle(1, y, s, s);
        Color ink = Gfx.C("#111111");
        Color boxFill = Enabled ? ink : Gfx.C("#C8C8C8");
        using (GraphicsPath p = Gfx.Round(rc, 5)) {
            if (Checked) {
                using (SolidBrush b = new SolidBrush(boxFill)) g.FillPath(b, p);
                using (Pen pen = new Pen(Color.White, 2f)) {
                    pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round; pen.LineJoin = LineJoin.Round;
                    g.DrawLines(pen, new PointF[] { new PointF(5.5f, y + 9.5f), new PointF(8.5f, y + 12.5f), new PointF(13.5f, y + 5.5f) });
                }
            } else {
                using (SolidBrush b = new SolidBrush(Color.White)) g.FillPath(b, p);
                using (Pen pen = new Pen(Enabled ? Gfx.C("#8A8A8A") : Gfx.C("#D0D0D0"), 1.2f)) g.DrawPath(pen, p);
            }
        }
        if (Focused && ShowFocusCues) using (GraphicsPath fp = Gfx.Round(new Rectangle(-1, y - 2, s + 4, s + 4), 6)) using (Pen pen = new Pen(ink)) { pen.DashStyle = DashStyle.Dot; g.DrawPath(pen, fp); }
        TextRenderer.DrawText(g, Text, Font, new Rectangle(s + 10, 0, Width - s - 10, Height), Enabled ? ForeColor : Gfx.C("#9A9A9A"),
            TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
    }
}

public class SpinBtn : Control {
    NumericUpDown n; int zone;
    public SpinBtn(NumericUpDown num) {
        n = num; BackColor = Color.White; Cursor = Cursors.Hand; TabStop = false;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(BackColor);
        RField rf = Parent as RField;
        if (rf != null) using (GraphicsPath bp = Gfx.Round(new Rectangle(-Left, -Top, rf.Width - 1, rf.Height - 1), rf.Radius))
            using (Pen bpn = new Pen(rf.Foc ? Gfx.C("#111111") : Gfx.C("#CFCFCF"))) g.DrawPath(bpn, bp);
        float cx = (Width - 4) / 2f; float h = Height / 2f;
        for (int k = 0; k < 2; k++) {
            float cy = h * k + h / 2f; float d = (k == 0) ? 1.5f : -1.5f;
            using (Pen p = new Pen(zone == k + 1 ? Gfx.C("#111111") : Gfx.C("#6B6B6B"), 1.5f)) {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                g.DrawLines(p, new PointF[] { new PointF(cx - 4, cy + d * 1.2f), new PointF(cx, cy - d * 1.2f), new PointF(cx + 4, cy + d * 1.2f) });
            }
        }
    }
    protected override void OnMouseMove(MouseEventArgs e) { int z = e.Y < Height / 2 ? 1 : 2; if (z != zone) { zone = z; Invalidate(); } base.OnMouseMove(e); }
    protected override void OnMouseLeave(EventArgs e) { zone = 0; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Y < Height / 2) n.UpButton(); else n.DownButton(); base.OnMouseDown(e); }
}

// rounded host for a native TextBox / NumericUpDown (native borders and spin buttons are hidden/clipped)
public class RField : Panel {
    public Control Inner; public int Mode; bool foc; public bool Foc { get { return foc; } }
    public int Radius = 8;
    public RField(Control c, int mode) {
        Inner = c; Mode = mode; BackColor = Color.White; Controls.Add(c);
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        c.Enter += delegate { foc = true; Invalidate(); foreach (Control k in Controls) k.Invalidate(); };
        c.Leave += delegate { foc = false; Invalidate(); foreach (Control k in Controls) k.Invalidate(); };
        if (mode == 2) { SpinBtn sp = new SpinBtn((NumericUpDown)c); sp.Name = "spin"; Controls.Add(sp); sp.BringToFront(); }
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); DoLayout(); }
    public void DoLayout() {
        if (Inner == null) return;
        if (Mode == 1) Inner.SetBounds(14, 10, Math.Max(10, Width - 28), Math.Max(10, Height - 20));
        else if (Mode == 2) {
            Inner.Left = 12; Inner.Width = Math.Max(10, Width - 12 + 24); Inner.Top = (Height - Inner.Height) / 2;
            Control sp = Controls["spin"]; if (sp != null) sp.SetBounds(Width - 30, 0, 30, Height);
        } else { Inner.Left = 12; Inner.Width = Math.Max(10, Width - 24); Inner.Top = (Height - Inner.Height) / 2; }
    }
    protected override void OnMouseDown(MouseEventArgs e) { Inner.Focus(); base.OnMouseDown(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Parent != null ? Parent.BackColor : Color.White);
        using (GraphicsPath p = Gfx.Round(new Rectangle(0, 0, Width - 1, Height - 1), Radius))
        using (SolidBrush b = new SolidBrush(BackColor)) using (Pen pen = new Pen(foc ? Gfx.C("#111111") : Gfx.C("#CFCFCF"))) { g.FillPath(b, p); g.DrawPath(pen, p); }
    }
}

public class FlatRenderer : ToolStripProfessionalRenderer {
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { }
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { e.Graphics.Clear(Color.White); }
}

public class PopList : Control {
    RCombo owner; int hot = -1; public int RowH = 28;
    public PopList(RCombo o) {
        owner = o; Width = o.Width; Height = o.Items.Count * RowH + 8; Font = o.Font;
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        Cursor = Cursors.Hand;
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(Color.White);
        using (GraphicsPath p = Gfx.Round(new Rectangle(0, 0, Width - 1, Height - 1), 8)) using (Pen pen = new Pen(Gfx.C("#CFCFCF"))) g.DrawPath(pen, p);
        using (Font bf = new Font("Segoe UI Semibold", Font.Size))
        for (int i = 0; i < owner.Items.Count; i++) {
            Rectangle r = new Rectangle(4, 4 + i * RowH, Width - 9, RowH);
            if (i == hot) using (GraphicsPath hp = Gfx.Round(r, 6)) using (SolidBrush b = new SolidBrush(Gfx.C("#F0F0F0"))) g.FillPath(b, hp);
            TextRenderer.DrawText(g, owner.Items[i], i == owner.SelectedIndex ? bf : Font, new Rectangle(r.X + 8, r.Y, r.Width - 12, r.Height), Gfx.C("#111111"),
                TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
    }
    int Hit(Point p) { int i = (p.Y - 4) / RowH; return (p.Y >= 4 && i >= 0 && i < owner.Items.Count) ? i : -1; }
    protected override void OnMouseMove(MouseEventArgs e) { int h = Hit(e.Location); if (h != hot) { hot = h; Invalidate(); } base.OnMouseMove(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = -1; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseUp(MouseEventArgs e) { int h = Hit(e.Location); if (h >= 0) owner.Choose(h); base.OnMouseUp(e); }
}

// Rounded drop-down list. Mirrors the members the app logic uses on a ComboBox:
// Items (Add / Clear / Count / indexer), SelectedIndex, SelectedItem.
public class RCombo : Control {
    public List<string> Items = new List<string>();
    public string Placeholder = "";
    int sel = -1; bool hot, open; DateTime closedAt = DateTime.MinValue; ToolStripDropDown dd;
    public event EventHandler SelectedChanged;
    public int SelectedIndex {
        get { return (sel >= 0 && sel < Items.Count) ? sel : -1; }
        set {
            int old = sel;
            if (value >= -1 && value < Items.Count) sel = value;
            Invalidate();
            if (old != sel && SelectedChanged != null) SelectedChanged(this, EventArgs.Empty);
        }
    }
    public string SelectedItem { get { int i = SelectedIndex; return i >= 0 ? Items[i] : null; } }
    public RCombo() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        Cursor = Cursors.Hand; BackColor = Color.White;
    }
    public void Choose(int i) { SelectedIndex = i; if (dd != null) dd.Close(); }
    void Open() {
        if (open || Items.Count == 0 || (DateTime.Now - closedAt).TotalMilliseconds < 250) return;
        PopList pl = new PopList(this);
        dd = new ToolStripDropDown(); dd.Padding = Padding.Empty; dd.DropShadowEnabled = false; dd.AutoSize = false; dd.BackColor = Color.White; dd.Renderer = new FlatRenderer();
        ToolStripControlHost h = new ToolStripControlHost(pl); h.Margin = Padding.Empty; h.Padding = Padding.Empty; h.AutoSize = false; h.Size = pl.Size;
        dd.Items.Add(h); dd.Size = pl.Size;
        dd.Opened += delegate { try { using (GraphicsPath p = Gfx.Round(new Rectangle(0, 0, dd.Width, dd.Height), 8)) dd.Region = new Region(p); } catch { } };
        dd.Closed += delegate { open = false; closedAt = DateTime.Now; Invalidate(); };
        open = true; Invalidate(); dd.Show(this, new Point(0, Height + 2));
    }
    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { Focus(); Open(); base.OnMouseDown(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override bool IsInputKey(Keys k) { return k == Keys.Up || k == Keys.Down || base.IsInputKey(k); }
    protected override void OnKeyDown(KeyEventArgs e) {
        if (e.KeyCode == Keys.Down) SelectedIndex = SelectedIndex + 1; else if (e.KeyCode == Keys.Up && SelectedIndex > 0) SelectedIndex = SelectedIndex - 1;
        else if (e.KeyCode == Keys.Space || e.KeyCode == Keys.F4) Open();
        base.OnKeyDown(e);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Parent != null ? Parent.BackColor : Color.White);
        Color ink = Gfx.C("#111111");
        bool on = Enabled;
        using (GraphicsPath p = Gfx.Round(new Rectangle(0, 0, Width - 1, Height - 1), 8))
        using (SolidBrush b = new SolidBrush(Color.White)) using (Pen pen = new Pen(on && (Focused || open || hot) ? ink : Gfx.C("#CFCFCF"))) { g.FillPath(b, p); g.DrawPath(pen, p); }
        int i = SelectedIndex;
        string t = i >= 0 ? Items[i] : Placeholder;
        Color tc = !on ? Gfx.C("#A6A6A6") : (i >= 0 ? ink : Gfx.C("#8A8A8A"));
        TextRenderer.DrawText(g, t, Font, new Rectangle(12, 0, Width - 40, Height), tc, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        float cx = Width - 20, cy = Height / 2f;
        using (Pen p = new Pen(Gfx.C("#6B6B6B"), 1.5f)) { p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; g.DrawLines(p, new PointF[] { new PointF(cx - 4, cy - 2), new PointF(cx, cy + 2), new PointF(cx + 4, cy - 2) }); }
    }
}

// ListView that shows a hint when it has no rows
public class HList : ListView {
    public string Empty = "";
    public HList() { DoubleBuffered = true; }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg == 0x000F && Items.Count == 0 && Empty.Length > 0) {
            try {
                using (Graphics g = Graphics.FromHwnd(Handle)) {
                    Rectangle r = new Rectangle(24, 64, Math.Max(10, ClientSize.Width - 48), Math.Max(10, ClientSize.Height - 72));
                    TextRenderer.DrawText(g, Empty, Font, r, Gfx.C("#6B6B6B"), TextFormatFlags.HorizontalCenter | TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                }
            } catch { }
        }
    }
}

public class NavRail : Control {
    public string[] Items = new string[0];
    public string Sub = "", Footer = "";
    static Font Fit(string text, string face, float start, float min, int maxW) {
        float s = start;
        while (s > min && TextRenderer.MeasureText(text, new Font(face, s), new Size(int.MaxValue, 100), TextFormatFlags.NoPadding).Width > maxW) s -= 0.25f;
        return new Font(face, s);
    }
    public int Selected = 0; int hot = -1;
    public int Top0 = 104, ItemH = 46;
    public event EventHandler SelectedChanged;
    public void Pick(int i) { if (Selected != i) { Selected = i; Invalidate(); if (SelectedChanged != null) SelectedChanged(this, EventArgs.Empty); } }
    public NavRail() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Gfx.C("#FAFAFA"); Cursor = Cursors.Hand;
    }
    void Icon(Graphics g, int i, float cx, float cy, Color c) {
        using (Pen p = new Pen(c, 1.6f)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            switch (i) {
                case 0:
                    g.DrawEllipse(p, cx - 9, cy - 9, 18, 18);
                    g.DrawLines(p, new PointF[] { new PointF(cx - 4.5f, cy), new PointF(cx - 1, cy + 3.5f), new PointF(cx + 5, cy - 3.5f) }); break;
                case 1:
                    using (GraphicsPath rp = Gfx.Round(new Rectangle((int)cx - 9, (int)cy - 9, 18, 18), 4)) g.DrawPath(p, rp);
                    g.DrawLine(p, cx - 4.5f, cy, cx + 4.5f, cy); g.DrawLine(p, cx, cy - 4.5f, cx, cy + 4.5f); break;
                case 2:
                    g.DrawPolygon(p, new PointF[] { new PointF(cx, cy - 9), new PointF(cx + 9, cy - 4.5f), new PointF(cx, cy), new PointF(cx - 9, cy - 4.5f) });
                    g.DrawLines(p, new PointF[] { new PointF(cx - 9, cy), new PointF(cx, cy + 4.5f), new PointF(cx + 9, cy) });
                    g.DrawLines(p, new PointF[] { new PointF(cx - 9, cy + 4.5f), new PointF(cx, cy + 9), new PointF(cx + 9, cy + 4.5f) }); break;
                case 3:
                    g.DrawArc(p, cx - 8, cy - 7, 16, 16, -55, 290);
                    g.DrawLine(p, cx, cy - 10, cx, cy - 1); break;
                default:
                    g.DrawArc(p, cx - 8, cy - 8, 16, 16, 150, 300);
                    g.DrawLines(p, new PointF[] { new PointF(cx, cy - 4.5f), new PointF(cx, cy), new PointF(cx + 3.5f, cy + 2) });
                    g.DrawLines(p, new PointF[] { new PointF(cx - 11, cy - 1), new PointF(cx - 7.5f, cy + 3.5f), new PointF(cx - 4, cy - 1) }); break;
            }
        }
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(BackColor);
        Color ink = Gfx.C("#111111"), grey = Gfx.C("#6B6B6B"), hair = Gfx.C("#DDDDDD");
        bool on = Enabled;
        if (!on) { ink = Gfx.C("#8A8A8A"); }
        using (Pen hp = new Pen(hair)) g.DrawLine(hp, Width - 1, 0, Width - 1, Height);
        using (GraphicsPath lp = Gfx.Round(new Rectangle(24, 28, 36, 36), 10)) using (SolidBrush lb = new SolidBrush(ink)) g.FillPath(lb, lp);
        using (SolidBrush wb = new SolidBrush(Color.White)) {
            for (int k = 0; k < 3; k++) using (GraphicsPath bp = Gfx.Round(new Rectangle(31, 36 + k * 8, 22, 4), 2)) g.FillPath(wb, bp);
        }
        int tw = Width - 70 - 12;
        using (Font f1 = Fit("VHDX Boot Manager", "Segoe UI Semibold", 11f, 8.5f, tw)) TextRenderer.DrawText(g, "VHDX Boot Manager", f1, new Rectangle(70, 28, tw, 20), ink, TextFormatFlags.NoPadding | TextFormatFlags.VerticalCenter);
        using (Font f2 = Fit(Sub, "Segoe UI Semilight", 9f, 7.5f, tw)) TextRenderer.DrawText(g, Sub, f2, new Rectangle(70, 48, tw, 16), grey, TextFormatFlags.NoPadding | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        using (Pen hp = new Pen(hair)) g.DrawLine(hp, 20, 84, Width - 21, 84);
        using (Font f = new Font("Segoe UI Semilight", 10.5f)) using (Font fs = new Font("Segoe UI Semibold", 10f)) {
            for (int i = 0; i < Items.Length; i++) {
                int y = Top0 + i * ItemH; bool sel = (i == Selected);
                Rectangle r = new Rectangle(16, y + 3, Width - 33, ItemH - 6);
                if (sel) using (GraphicsPath sp = Gfx.Round(r, 8)) { using (SolidBrush sb = new SolidBrush(Color.White)) g.FillPath(sb, sp); using (Pen sq = new Pen(hair)) g.DrawPath(sq, sp); }
                else if (i == hot && on) using (GraphicsPath hpth = Gfx.Round(r, 8)) using (SolidBrush hb = new SolidBrush(Gfx.C("#EFEFEF"))) g.FillPath(hb, hpth);
                if (sel) using (GraphicsPath ap = Gfx.Round(new Rectangle(5, y + ItemH / 2 - 10, 4, 20), 2)) using (SolidBrush ab = new SolidBrush(on ? Gfx.C("#FF4F00") : Gfx.C("#F7C2AA"))) g.FillPath(ab, ap);
                Color c = sel ? ink : (on ? Gfx.C("#555555") : Gfx.C("#A0A0A0"));
                Icon(g, i, 40, y + ItemH / 2f, sel ? ink : (on ? grey : Gfx.C("#A0A0A0")));
                TextRenderer.DrawText(g, Items[i], sel ? fs : f, new Rectangle(64, y, Width - 70, ItemH), c, TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter);
            }
        }
        using (Font f3 = new Font("Segoe UI Semilight", 8.5f)) TextRenderer.DrawText(g, Footer, f3, new Rectangle(24, Height - 36, Width - 40, 20), grey, TextFormatFlags.NoPadding | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
    }
    int Hit(Point p) { int i = (p.Y - Top0) / ItemH; return (p.Y >= Top0 && i >= 0 && i < Items.Length) ? i : -1; }
    protected override void OnMouseMove(MouseEventArgs e) { int h = Hit(e.Location); if (h != hot) { hot = h; Invalidate(); } base.OnMouseMove(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = -1; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { int h = Hit(e.Location); if (h >= 0) Pick(h); base.OnMouseDown(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
}
'@
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $cs -Language CSharp
Add-Type -Namespace Win -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr h, int a, ref int v, int s);'
Add-Type -Namespace Win -Name U32 -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr hdc, uint flags);'

function C($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Pt($x, $y) { New-Object System.Drawing.Point($x, $y) }
function Sz($w, $h) { New-Object System.Drawing.Size($w, $h) }
function Pad($l, $t, $r, $b) { New-Object System.Windows.Forms.Padding($l, $t, $r, $b) }

$script:cInk = C '#111111'; $script:cGrey = C '#6B6B6B'; $script:cHair = C '#DDDDDD'; $script:cWhite = [System.Drawing.Color]::White; $script:cAccent = C '#E04500'
$script:fBody = New-Object System.Drawing.Font('Segoe UI Semilight', 10)
$script:fBold = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$script:fItal = New-Object System.Drawing.Font('Segoe UI Semilight', 10, [System.Drawing.FontStyle]::Italic)
$script:fSmall = New-Object System.Drawing.Font('Segoe UI Semilight', 9)
$script:fHdr = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
$script:fBtn = New-Object System.Drawing.Font('Segoe UI', 9)
$script:fBtnB = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$script:fMono = New-Object System.Drawing.Font('Consolas', 9.5)
$script:bWhite = New-Object System.Drawing.SolidBrush($script:cWhite)
$script:bSel = New-Object System.Drawing.SolidBrush((C '#EBEBEB'))
$script:bRunRow = New-Object System.Drawing.SolidBrush((C '#F6F6F6'))
$script:penHair = New-Object System.Drawing.Pen($script:cHair)
$script:penHair2 = New-Object System.Drawing.Pen((C '#EAEAEA'))

# ---- control factories ----
# Rounded button; same click behaviour as before: Invoke-Action <button text> <action>
function New-Btn([string]$Text, [string]$Kind, [string]$HelpText, [scriptblock]$Action, [int]$W = 0, [int]$H = 32) {
  $b = New-Object RBtn
  $b.Text = $Text; $b.Kind = $Kind; $b.BackColor = $script:cWhite
  $b.Font = if ($Kind -eq 'primary') { $script:fBtnB } else { $script:fBtn }
  if ($W -le 0) { $W = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $b.Font).Width + 28 }
  $b.Size = Sz $W $H; $b.Margin = Pad 0 0 8 0
  Add-Help $b $Text $HelpText
  $b.Tag = @{ Name = $Text; Action = $Action }
  $b.Add_Click({ $t = $this.Tag; Invoke-Action $t.Name $t.Action })
  return $b
}

function New-Label([string]$Text, $Font = $script:fBody, $Color = $script:cGrey) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text; $l.Font = $Font; $l.ForeColor = $Color; $l.BackColor = $script:cWhite; $l.AutoSize = $false; $l.UseMnemonic = $false
  return $l
}
# show the vertical scrollbar of a read-only text box only when the text does not fit
function Set-AutoScroll($tb) {
  $upd = {
    param($s, $e)
    $w = [Math]::Max(50, $s.ClientSize.Width - 17)
    $need = ([System.Windows.Forms.TextRenderer]::MeasureText($s.Text + ' ', $s.Font, (Sz $w 0), [System.Windows.Forms.TextFormatFlags]'WordBreak,NoPadding')).Height -gt $s.ClientSize.Height
    $want = if ($need) { 'Vertical' } else { 'None' }
    if ($s.ScrollBars -ne $want) { $s.ScrollBars = $want }
  }
  $tb.Add_TextChanged($upd); $tb.Add_Resize($upd)
}

function New-Host($inner, [int]$mode, [string]$Title, [string]$HelpText) {
  $inner.Font = $script:fBody; $inner.ForeColor = $script:cInk; $inner.BackColor = $script:cWhite
  $inner.BorderStyle = 'None'
  $h = New-Object RField $inner, $mode
  $h.Dock = 'Fill'; $h.Margin = Pad 0 4 14 4
  if ($HelpText) { Add-Help $inner $Title $HelpText; Add-Help $h $Title $HelpText }
  return $h
}
function New-Text([string]$Text, [string]$Title, [string]$HelpText) {
  $t = New-Object System.Windows.Forms.TextBox; $t.Text = $Text
  return (New-Host $t 0 $Title $HelpText)
}
function New-Num($min, $max, $val, [int]$w, [string]$Title, [string]$HelpText) {
  $n = New-Object System.Windows.Forms.NumericUpDown; $n.Minimum = $min; $n.Maximum = $max; $n.Value = $val
  $h = New-Host $n 2 $Title $HelpText; $h.Dock = 'None'; $h.Anchor = 'Left'; $h.Size = Sz $w 32; $h.Margin = Pad 0 4 8 4
  return $h
}
function New-Multi($font = $script:fMono) {
  $t = New-Object System.Windows.Forms.TextBox
  $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Vertical'; $t.WordWrap = $true
  $h = New-Host $t 1 '' ''; $t.Font = $font; $h.Margin = Pad 0 0 0 0
  [Gfx]::Explorer($t); Set-AutoScroll $t
  return $h
}
function New-Combo([string]$Title, [string]$HelpText, [string]$Placeholder) {
  $c = New-Object RCombo
  $c.Font = $script:fBody; $c.Dock = 'Fill'; $c.Margin = Pad 0 4 14 4; $c.Placeholder = $Placeholder
  Add-Help $c $Title $HelpText
  return $c
}
function New-Check([string]$Text, [bool]$Checked, [string]$Title, [string]$HelpText) {
  $c = New-Object RCheck
  $c.Text = $Text; $c.Checked = $Checked; $c.Font = $script:fBody; $c.ForeColor = $script:cInk
  $c.BackColor = $script:cWhite; $c.Margin = Pad 0 2 0 2; $c.Dock = 'Fill'
  Add-Help $c $Title $HelpText
  return $c
}
function New-Page { $p = New-Object System.Windows.Forms.Panel; $p.Dock = 'Fill'; $p.BackColor = $script:cWhite; $p.Padding = Pad 0 16 0 0; $p.Visible = $false; return $p }
function New-Flow {
  $f = New-Object System.Windows.Forms.FlowLayoutPanel
  $f.BackColor = $script:cWhite; $f.WrapContents = $true; $f.FlowDirection = 'LeftToRight'
  return $f
}
function New-ListCard($lv) {
  $c = New-Object RCard; $c.Dock = 'Fill'; $c.Padding = Pad 8 6 8 8; $c.Radius = 12
  $c.Controls.Add($lv); return $c
}
function Grp([string]$text) {
  $l = New-Label $text.ToUpper() $script:fHdr $script:cGrey; $l.Size = Sz 200 20; $l.TextAlign = 'BottomLeft'
  return $l
}

# ---- owner-drawn lists (rounded selection bars, pills, hairlines) ----
$script:flagsL = [System.Windows.Forms.TextFormatFlags]'VerticalCenter,Left,EndEllipsis,NoPrefix,SingleLine'
function Draw-Pill($g, [int]$x, [int]$cy, [string]$text, $fill, $fore, $border) {
  $f = $script:fHdr
  $w = [System.Windows.Forms.TextRenderer]::MeasureText($text, $f).Width + 10; $h = 20
  $r = New-Object System.Drawing.Rectangle($x, ($cy - 10), $w, $h)
  $g.SmoothingMode = 'AntiAlias'
  $p = [Gfx]::Round($r, 10)
  if ($fill) { $br = New-Object System.Drawing.SolidBrush($fill); $g.FillPath($br, $p); $br.Dispose() }
  if ($border) { $pn = New-Object System.Drawing.Pen($border); $g.DrawPath($pn, $p); $pn.Dispose() }
  $p.Dispose()
  [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $f, $r, $fore, [System.Windows.Forms.TextFormatFlags]'HorizontalCenter,VerticalCenter,NoPadding,NoPrefix')
  return ($w + 6)
}
$script:drawHeader = {
  param($s, $e)
  $g = $e.Graphics
  $g.FillRectangle($script:bWhite, $e.Bounds)
  $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 12), $e.Bounds.Y, ([Math]::Max(1, $e.Bounds.Width - 12)), ($e.Bounds.Height - 1))
  [System.Windows.Forms.TextRenderer]::DrawText($g, $e.Header.Text.ToUpper(), $script:fHdr, $r, $script:cGrey, $script:flagsL)
  $g.DrawLine($script:penHair, ($e.Bounds.Left + $(if ($e.ColumnIndex -eq 0) { 4 } else { 0 })), $e.Bounds.Bottom - 1, ($e.Bounds.Right - $(if ($e.ColumnIndex -eq $s.Columns.Count - 1) { 4 } else { 0 })), $e.Bounds.Bottom - 1)
}
$script:drawCell = {
  param($s, $e)
  $g = $e.Graphics; $it = $e.Item; $b = $e.Bounds; $ci = $e.ColumnIndex
  $tag = $it.Tag; $text = [string]$e.SubItem.Text
  $kind = ''
  switch ($s.Name) {
    'EnvList' { if ($tag) { if ($tag.IsRunning) { $kind = 'running' } elseif ($tag.Type -eq 'Base') { $kind = 'base' } } }
    'BootList' { if ($it.SubItems.Count -gt 2 -and $it.SubItems[2].Text -match 'running') { $kind = 'running' } elseif ($it.Font.Bold) { $kind = 'defrow' } }
    'BackupList' { if ($tag -and ([string]$tag.Reason) -match '^manual') { $kind = 'strong' } }
  }
  $g.SmoothingMode = 'AntiAlias'
  $g.FillRectangle($script:bWhite, $b)
  $fb = $null
  if ($it.Selected) { $fb = $script:bSel } elseif ($kind -eq 'running') { $fb = $script:bRunRow }
  $first = ($ci -eq 0); $last = ($ci -eq ($s.Columns.Count - 1))
  if ($fb) {
    $x1 = if ($first) { $b.X + 3 } else { $b.X - 20 }
    $x2 = if ($last) { $b.Right - 3 } else { $b.Right + 20 }
    $rc = New-Object System.Drawing.Rectangle($x1, ($b.Y + 2), ($x2 - $x1), ($b.Height - 5))
    $g.SetClip($b)
    $p = [Gfx]::Round($rc, 8); $g.FillPath($fb, $p); $p.Dispose()
    $g.ResetClip()
  }
  else {
    $g.DrawLine($script:penHair2, ($b.Left + $(if ($first) { 4 } else { 0 })), $b.Bottom - 1, ($b.Right - $(if ($last) { 4 } else { 0 })), $b.Bottom - 1)
  }
  $cy = $b.Y + [int](($b.Height - 1) / 2); $x0 = $b.X + 12
  $g.SetClip($b)
  if ($s.Name -eq 'EnvList') {
    if ($ci -eq 1 -and $text -eq 'Base') { [void](Draw-Pill $g $x0 $cy 'BASE' $null $script:cInk $script:cInk); $g.ResetClip(); return }
    if ($ci -eq 6 -and $text -eq 'RUNNING') { [void](Draw-Pill $g $x0 $cy 'RUNNING' $script:cInk $script:cWhite $null); $g.ResetClip(); return }
    if ($ci -eq 6 -and $text -eq 'locked') { [void](Draw-Pill $g $x0 $cy 'LOCKED' $null $script:cGrey (C '#BDBDBD')); $g.ResetClip(); return }
  }
  if ($s.Name -eq 'BootList' -and $ci -eq 2 -and $text) {
    $x = $x0
    foreach ($tok in ($text -split ',\s*')) {
      if ($tok -eq 'running') { $x += (Draw-Pill $g $x $cy 'RUNNING' $script:cInk $script:cWhite $null) }
      elseif ($tok -eq 'default') { $x += (Draw-Pill $g $x $cy 'DEFAULT' $null $script:cInk $script:cInk) }
    }
    $g.ResetClip(); return
  }
  $font = $script:fBody; $col = $script:cInk
  if ($kind -eq 'base') { $font = $script:fItal; $col = $script:cGrey }
  if ($kind -eq 'running' -and $first) { $font = $script:fBold }
  if ($kind -eq 'strong') { $font = $script:fBold; $col = $script:cAccent }
  if ($kind -eq 'defrow' -and $first) { $font = $script:fBold }
  if ($s.Name -eq 'BootList' -and $ci -eq 3) { $font = $script:fSmall; $col = $script:cGrey }
  $r = New-Object System.Drawing.Rectangle($x0, $b.Y, ([Math]::Max(1, $b.Width - 14)), ($b.Height - 1))
  [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $font, $r, $col, $script:flagsL)
  $g.ResetClip()
}
function New-List([string]$Name, $cols, [string]$EmptyText, [bool]$Multi = $false) {
  $lv = New-Object HList
  $lv.Name = $Name; $lv.Empty = $EmptyText
  $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $Multi; $lv.HideSelection = $false
  $lv.BorderStyle = 'None'; $lv.BackColor = $script:cWhite; $lv.Font = $script:fBody; $lv.OwnerDraw = $true; $lv.Dock = 'Fill'
  $il = New-Object System.Windows.Forms.ImageList; $il.ImageSize = Sz 1 30; $lv.SmallImageList = $il
  foreach ($c in $cols) { [void]$lv.Columns.Add($c[0], $c[1]) }
  $lv.Add_DrawColumnHeader($script:drawHeader); $lv.Add_DrawSubItem($script:drawCell); $lv.Add_DrawItem({ param($s, $e) })
  $lv.Tag = @($cols | ForEach-Object { $_[1] })
  $lv.Add_Resize({
      param($s, $e)
      $w = $s.ClientSize.Width - 4; if ($w -lt 200) { return }
      $t = 0; foreach ($x in $s.Tag) { $t += $x }
      $n = $s.Columns.Count - 1; $used = 0
      for ($i = 0; $i -lt $n; $i++) { $cw = [int]($w * $s.Tag[$i] / $t); $s.Columns[$i].Width = $cw; $used += $cw }
      $s.Columns[$n].Width = $w - $used; $s.Invalidate()
    })
  return $lv
}

# ---- window ----
$Form = New-Object System.Windows.Forms.Form
$Form.Text = 'VHDX Boot Manager - multiple bare-metal Windows environments'
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'Sizable'
$Form.MaximizeBox = $true
$Form.ClientSize = New-Object System.Drawing.Size(800, 680)
$Form.MinimumSize = $Form.Size   # smallest allowed window
$Form.ClientSize = New-Object System.Drawing.Size(1120, 770)
$Form.BackColor = $script:cWhite; $Form.ForeColor = $script:cInk
$Form.Font = $script:fBody
$Form.KeyPreview = $true
$script:Form = $Form

# Window size / position is remembered between runs
$script:WinStateFile = Join-Path $env:APPDATA 'VhdxBootManager\window.json'
function Restore-WindowState {
  try {
    if (-not (Test-Path -LiteralPath $script:WinStateFile)) { return }
    $s = Get-Content -LiteralPath $script:WinStateFile -Raw | ConvertFrom-Json
    if ($s.Keep) { $k = [int]$s.Keep; if ($k -ge 10 -and $k -le 1000) { $script:KeepBackups = $k; $script:NumKeep.Value = $k } }
    $bounds = New-Object System.Drawing.Rectangle([int]$s.X, [int]$s.Y, [int]$s.W, [int]$s.H)
    $visible = $false
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
      $inter = [System.Drawing.Rectangle]::Intersect($scr.WorkingArea, $bounds)
      if ($inter.Width -ge 200 -and $inter.Height -ge 100) { $visible = $true }
    }
    if ($visible -and $bounds.Width -ge $script:Form.MinimumSize.Width -and $bounds.Height -ge $script:Form.MinimumSize.Height) {
      $script:Form.StartPosition = 'Manual'
      $script:Form.Bounds = $bounds
    }
    if ($s.Maximized) { $script:Form.WindowState = 'Maximized' }
  }
  catch {}
}
function Save-WindowState {
  try {
    $f = $script:Form
    $b = if ($f.WindowState -eq 'Normal') { $f.Bounds } else { $f.RestoreBounds }
    New-Item -ItemType Directory -Force -Path (Split-Path $script:WinStateFile) | Out-Null
    [pscustomobject]@{ X = $b.X; Y = $b.Y; W = $b.Width; H = $b.Height; Maximized = ($f.WindowState -eq 'Maximized'); Keep = $script:KeepBackups } |
    ConvertTo-Json | Set-Content -LiteralPath $script:WinStateFile -Encoding UTF8
  }
  catch {}
}

# ---- page host (replaces the tab control; the sidebar picks the page) ----
$Tabs = New-Object System.Windows.Forms.Panel; $Tabs.Dock = 'Fill'; $Tabs.BackColor = $script:cWhite
$script:Tabs = $Tabs
$pCheck = New-Page; $pBase = New-Page; $pEnv = New-Page; $pBoot = New-Page; $pBackup = New-Page
$pageList = @($pCheck, $pBase, $pEnv, $pBoot, $pBackup)
foreach ($p in $pageList) { $Tabs.Controls.Add($p) }

# ======================= PAGE 1: CHECK =======================
$CheckOutHost = New-Multi (New-Object System.Drawing.Font('Consolas', 9.5)); $CheckOutHost.Dock = 'Fill'
$CheckOut = $CheckOutHost.Inner; $script:CheckOut = $CheckOut
$top1 = New-Object System.Windows.Forms.Panel; $top1.Dock = 'Top'; $top1.Height = 70; $top1.BackColor = $script:cWhite
$bRun = New-Btn 'Run system check' 'primary' 'Checks everything needed before you start: your Windows edition, UEFI firmware, whether the VHD folder is on an NTFS drive with enough free space, whether that drive is BitLocker/Device-Encryption encrypted (native VHDX boot fails on encrypted drives), whether you are currently booted from a VHDX, and what is in the boot menu. It only reads information and does not change anything.' { Invoke-SystemCheck } 170 36
$bRun.Location = Pt 0 0; $top1.Controls.Add($bRun)
$chkInfo = New-Label 'Start here. If anything shows FAIL, fix it before creating a base (most often: the drive holding the VHD folder is encrypted - pick another drive or turn off Device Encryption in Settings > Privacy & security).' $script:fSmall $script:cGrey
$chkInfo.Location = Pt 190 0; $chkInfo.Size = Sz 400 64
$top1.Controls.Add($chkInfo); $script:chkInfo = $chkInfo
$top1.Add_Resize({ param($s, $e) $script:chkInfo.Width = [Math]::Max(100, $s.ClientSize.Width - 190) })
$pCheck.Controls.Add($CheckOutHost); $pCheck.Controls.Add($top1); $CheckOutHost.BringToFront()

# ======================= PAGE 2: CREATE BASE =======================
$tl = New-Object System.Windows.Forms.TableLayoutPanel
$tl.Dock = 'Top'; $tl.AutoSize = $true; $tl.BackColor = $script:cWhite; $tl.ColumnCount = 4; $tl.GrowStyle = 'FixedSize'
[void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 124)))
[void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
[void]$tl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
$heights = 36, 36, 36, 36, 36, 30, 30, 36, 30, 62
$tl.RowCount = $heights.Count
foreach ($h in $heights) { [void]$tl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', $h))) }
function Lbl($t) { $l = New-Label $t $script:fBody $script:cGrey; $l.Dock = 'Fill'; $l.TextAlign = 'MiddleLeft'; $l.Margin = Pad 0 0 0 0; return $l }
function Put($c, $col, $row, $span = 1) { $tl.Controls.Add($c, $col, $row); if ($span -gt 1) { $tl.SetColumnSpan($c, $span) } }

$hIso = New-Text '' 'Windows ISO' 'The Windows installation ISO to build the base from. Download the official Windows 11 ISO from microsoft.com/software-download/windows11.'
$TxtIso = $hIso.Inner; $script:TxtIso = $TxtIso
$btnBrowseIso = New-Btn 'Browse...' 'ghost' 'Pick the Windows ISO file. After you choose it, its editions are read automatically.' {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Windows ISO (*.iso)|*.iso'
    if ($d.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) { $script:TxtIso.Text = $d.FileName; Read-Editions }
  } 100 32
$btnBrowseIso.Anchor = 'Left'; $btnBrowseIso.Margin = Pad 0 0 8 0
$btnRead = New-Btn 'Read editions' 'ghost' 'Mounts the ISO and lists the Windows editions inside it (the same as "dism /Get-WimInfo" in the guide). Pro is selected automatically.' { Read-Editions } 124 32
$btnRead.Anchor = 'Left'; $btnRead.Margin = Pad 0 0 0 0
Put (Lbl 'Windows ISO') 0 0; Put $hIso 1 0; Put $btnBrowseIso 2 0; Put $btnRead 3 0

$CmbEdition = New-Combo 'Edition' 'Which Windows edition to install into the base. Choose Pro (or Enterprise/Education): Home cannot boot from a VHDX. Your digital licence usually activates the same edition you already have on this PC.' 'Pick the ISO, then click Read editions'
$script:CmbEdition = $CmbEdition
Put (Lbl 'Edition') 0 1; Put $CmbEdition 1 1 3

$hName = New-Text 'base' 'File name' 'Name of the base disk file (".vhdx" is added). Use a version in the name if you plan to rebuild later, e.g. base-25H2.'
$TxtBaseName = $hName.Inner; $script:TxtBaseName = $TxtBaseName
$lExt = Lbl '.vhdx'; $lExt.Margin = Pad 0 0 0 0
Put (Lbl 'File name') 0 2; Put $hName 1 2; Put $lExt 2 2 2

$hBoot = New-Text 'Win - Base' 'Boot menu name' 'The name shown in the boot menu when the PC starts. You boot the base only once, to set it up; after that it is locked.'
$TxtBootLabel = $hBoot.Inner; $script:TxtBootLabel = $TxtBootLabel
Put (Lbl 'Boot menu name') 0 3; Put $hBoot 1 3 3

$hSize = New-Num 40 4000 100 110 'Maximum size' 'The largest size the virtual disk can grow to. The file starts small and grows as data is added. Every environment built on this base gets the same maximum. The default is 50% of the free space on the drive of the VHD folder (40-4000 GB); once you change it by hand it is left alone. 80-150 GB is typical; keep games and big data on a physical drive instead. You can change the size later with "Change max size..." on the Environments page.'
$NumSize = $hSize.Inner; $script:NumSize = $NumSize
$script:SizeTouched = $false; $script:SettingSize = $false
$NumSize.Add_ValueChanged({ if (-not $script:SettingSize) { $script:SizeTouched = $true } })
$NumSize.Add_TextChanged({ if (-not $script:SettingSize) { $script:SizeTouched = $true } })
Put (Lbl 'Max size (GB)') 0 4; Put $hSize 1 4

$ChkAddBoot = New-Check 'Add it to the boot menu (needed to set it up)' $true 'Add to boot menu' 'Creates a boot menu entry for the base so you can start it once and finish Windows setup. Your current Windows stays the default.'
$script:ChkAddBoot = $ChkAddBoot
$ChkNoExpand = New-Check "Don't expand the file to full size when booted (saves disk space)" $false "Don't expand at boot" 'Normally Windows grows a dynamic VHDX to its FULL maximum size while it is booted (a 100 GB disk takes 100 GB on the drive). Ticking this writes VirtualDiskExpandOnMount=4 into the new Windows, so files stay small. Every environment built on this base inherits it. Risk: if the physical drive fills up completely, the running environment crashes.'
$script:ChkNoExpand = $ChkNoExpand
Put (Lbl 'Options') 0 5; Put $ChkAddBoot 1 5 3; Put $ChkNoExpand 1 6 3

$hAns = New-Text '' 'Answer file (optional)' 'An unattend.xml / autounattend.xml to apply to the new Windows (skip OOBE, create the user, computer name, language, scripts...). It is copied to Windows\Panther\unattend.xml, so the specialize and oobeSystem passes run on the first boot. windowsPE-pass settings (disk layout, edition, setup product key) cannot apply because Windows Setup is not used. Leave empty to use the one inside the ISO, if there is one.'
$TxtAnswer = $hAns.Inner; $script:TxtAnswer = $TxtAnswer
$btnBrowseAf = New-Btn 'Browse...' 'ghost' 'Choose an external answer file. It overrides any autounattend.xml inside the ISO.' {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Answer file (*.xml)|*.xml|All files (*.*)|*.*'
    if ($d.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) { $script:TxtAnswer.Text = $d.FileName }
  } 100 32
$btnBrowseAf.Anchor = 'Left'; $btnBrowseAf.Margin = Pad 0 0 0 0
Put (Lbl 'Answer file') 0 7; Put $hAns 1 7; Put $btnBrowseAf 2 7 2

$ChkIsoAnswer = New-Check 'Pick the ISO and click "Read editions" to look for an autounattend.xml' $false 'Use answer file from ISO' 'Many custom ISOs contain autounattend.xml in the root. Normally only Windows Setup reads it; this tool applies the image directly, so it copies the file (and sources\$OEM$ folders, if present) into the new Windows itself. A file chosen with Browse overrides this.'
$ChkIsoAnswer.Enabled = $false; $script:ChkIsoAnswer = $ChkIsoAnswer
Put $ChkIsoAnswer 1 8 3

$bFlow = New-Flow; $bFlow.Dock = 'Fill'; $bFlow.Margin = Pad 0 0 0 0; $bFlow.Padding = Pad 0 8 0 0
$BtnCreate = New-Btn 'Create base VHDX' 'primary' 'Does guide steps 2-5 in one go: creates the virtual disk file in the VHD folder, partitions and formats it, installs the chosen Windows edition into it with DISM (5-15 minutes), applies the answer file and the optional no-expand setting, detaches it and adds a boot menu entry, without changing your default Windows. A backup of the boot configuration is saved first.' { New-BaseVhdx } 230 42
$BtnCreate.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5); $BtnCreate.Radius = 10; $BtnCreate.Margin = Pad 0 0 14 0
$bSys = New-Btn 'Copy sysprep command' 'ghost' "Copies this command to the clipboard:`r`n$SysprepCmd`r`nOptional: run it in an administrator Command Prompt INSIDE the base, as the last thing before you create environments. It gives every environment its own unique identity (recommended if several will be on the network or join a domain). The base then shuts down; each environment runs a short setup on its first boot." {
    [System.Windows.Forms.Clipboard]::SetText($SysprepCmd)
    Write-Log "Copied to clipboard: $SysprepCmd"
  } 190 42
$bSys.Radius = 10
$bFlow.Controls.Add($BtnCreate); $bFlow.Controls.Add($bSys)
Put $bFlow 1 9 3

$StepsBox = New-Label ("AFTER THE BASE IS CREATED`r`n`r`n" +
    "1.  Restart and pick the base in the boot menu (the tool offers to do this for you).`r`n`r`n" +
    "2.  Finish Windows setup. Install drivers, all Windows Updates, and the apps EVERY environment should have. Keep it lean.`r`n`r`n" +
    "3.  Optional: run sysprep (button on the left) as the last step.`r`n`r`n" +
    "4.  Shut down and start your normal Windows.`r`n`r`n" +
    "5.  Open this tool > Environments > select the base > 'New environment from selected'. Create as many as you like.`r`n`r`n" +
    "After that, never boot or change the base: the environments are built on it.") $script:fSmall $script:cGrey
$StepsBox.Dock = 'Fill'; $StepsBox.Padding = Pad 32 6 0 0
$stepsSep = New-Object System.Windows.Forms.Panel; $stepsSep.Dock = 'Left'; $stepsSep.Width = 1; $stepsSep.BackColor = $script:cHair
$sideBox = New-Object System.Windows.Forms.Panel; $sideBox.Dock = 'Right'; $sideBox.Width = 291; $sideBox.BackColor = $script:cWhite
$sideBox.Controls.Add($StepsBox); $sideBox.Controls.Add($stepsSep); $stepsSep.SendToBack()
$script:SideBox = $sideBox
$pBase.AutoScroll = $true
$pBase.Controls.Add($tl); $pBase.Controls.Add($sideBox); $sideBox.SendToBack(); $tl.BringToFront()
# small window: hide the side instructions when they would crowd the form
$pBase.Add_Resize({ param($s, $e) $v = ($s.ClientSize.Width -ge 840); $script:SideBox.Visible = $v })

# ======================= PAGE 3: ENVIRONMENTS =======================
$EnvList = New-List 'EnvList' @(@('Name', 150), @('Type', 110), @('Built on', 120), @('Size', 90), @('Max', 70), @('Boot menu name', 170), @('Status', 110)) 'No .vhdx files in this VHD folder yet. Create a base on the Create base page.'
$script:EnvList = $EnvList
$EnvList.Add_SelectedIndexChanged({ if ($this.SelectedItems.Count) { $e = $this.SelectedItems[0].Tag; Show-HelpText "Selected: $($e.Name)" (Get-EnvSummary $e) } })
Add-Help $EnvList 'Environments' 'Every .vhdx in the VHD folder. Base = the clean Windows that environments are built on (never boot it). Child = an environment that only stores its own changes on top of a base. Standalone = an independent full disk. Select one, then use the buttons below.'
$cardEnv = New-ListCard $EnvList
$rp = New-Object System.Windows.Forms.Panel; $rp.Dock = 'Bottom'; $rp.Height = 160; $rp.BackColor = $script:cWhite
$rp.Add_Paint({ param($s, $e) $e.Graphics.DrawLine($script:penHair, 0, 0, $s.Width, 0) })
$script:envLayout = {
  param($s, $e)
  $y = 12; $x = 0
  foreach ($c in $s.Controls) {
    if ($c.Tag -is [string] -and $c.Tag -eq 'grp') { if ($x -gt 0) { $y += 32 }; $c.Location = Pt 0 ($y + 0); $x = 100 }
    else {
      if (($x + $c.Width) -gt $s.ClientSize.Width -and $x -gt 100) { $x = 100; $y += 32 }
      $c.Location = Pt $x $y; $x += $c.Width + 8
    }
  }
  $nh = $y + 30 + 6
  if ($s.Height -ne $nh) { $s.Height = $nh }
  if ($s.Parent) { $s.Parent.PerformLayout() }
}
$rp.Add_Resize($script:envLayout); $script:rp = $rp
function Add-EnvGroup([string]$Name) {
  $gl = Grp $Name; $gl.Size = Sz 92 30; $gl.TextAlign = 'MiddleLeft'; $gl.Tag = 'grp'; $script:rp.Controls.Add($gl)
}
Add-EnvGroup 'Create'
$rp.Controls.Add((New-Btn 'New environment from selected' 'primary' "Creates a new environment (e.g. work, gaming, sandbox) built on the selected base. The new file starts at a few MB and stores only what changes compared to the base. A boot menu entry is added, and the tool offers to lock the base (read-only, removed from the boot menu) so it can't be changed by accident." { New-ChildEnv; Update-All }))
$rp.Controls.Add((New-Btn 'Make standalone copy' 'ghost' 'Creates an independent full copy of the selected environment, merged with its base into one file that no longer depends on anything. Useful for keeping an environment forever, moving it to another drive, or making it the base for a new set. Takes longer and uses more space.' { New-StandaloneCopy; Update-All }))
Add-EnvGroup 'Snapshots'
$rp.Controls.Add((New-Btn 'Snapshot' 'ghost' 'Saves a copy of the selected environment into <VHD folder>\snapshots, with the date and an optional note in the name. Do this before risky changes (driver updates, new software). Environments are usually small, so this is quick. The environment must not be the one you are running.' { Save-Snapshot; Update-All }))
$rp.Controls.Add((New-Btn 'Restore snapshot...' 'ghost' "Rolls the selected environment back to a snapshot you choose. Everything changed since that snapshot is lost. Works only while you're NOT running that environment." { Restore-Snapshot; Update-All }))
$rp.Controls.Add((New-Btn 'Open snapshots folder' 'ghost' 'Opens <VHD folder>\snapshots in File Explorer, where you can delete old snapshots you no longer need.' {
    $d = Join-Path (Get-VhdFolder) 'snapshots'; New-Item -ItemType Directory -Path $d -Force | Out-Null; Start-Process explorer.exe $d }))
Add-EnvGroup 'Boot menu'
$rp.Controls.Add((New-Btn 'Restart into this' 'ghost' 'Restarts the PC straight into the selected environment, for this one restart only (bcdedit /bootsequence). Your default does not change. You are asked before the restart happens.' {
    $e = Get-SelectedEnv; Assert-NoChildren $e; $b = Get-EnvBootEntry $e -OfferToAdd; Update-All; Start-RestartInto $b.Id $b.Description }))
$rp.Controls.Add((New-Btn 'Set as default boot' 'ghost' 'Makes the selected environment the one that starts automatically when nobody picks from the boot menu.' {
    $e = Get-SelectedEnv; Assert-NoChildren $e; $b = Get-EnvBootEntry $e -OfferToAdd; Invoke-Bcd @('/default', $b.Id) | Out-Null; Write-Log "Default boot is now '$($b.Description)'."; Update-All }))
$rp.Controls.Add((New-Btn 'Add boot menu entry' 'ghost' 'Adds the selected environment to the boot menu, e.g. a standalone copy, or an environment whose entry you removed. Not allowed for a base that others are built on.' {
    $e = Get-SelectedEnv; Assert-NoChildren $e
    $l = Read-Text 'Name to show in the boot menu:' 'Boot menu name' "Win - $($e.Name)"; if (-not $l) { return }
    New-BootEntry $e.Path $l | Out-Null; Update-All }))
$rp.Controls.Add((New-Btn 'Rename boot menu entry' 'ghost' 'Changes the name shown for the selected environment in the boot menu.' {
    $e = Get-SelectedEnv; $b = Get-EnvBootEntry $e
    $l = Read-Text 'New boot menu name:' 'Rename' $b.Description; if (-not $l) { return }
    Invoke-Bcd @('/set', $b.Id, 'description', $l) | Out-Null; Write-Log "Renamed to '$l'."; Update-All }))
$rp.Controls.Add((New-Btn 'Remove boot menu entries' 'ghost' 'Removes the selected environment from the boot menu. The file is kept, so you can add it back later.' {
    $e = Get-SelectedEnv; Assert-NotRunning $e
    if (-not $e.Boot.Count) { throw "'$($e.Name)' is not in the boot menu." }
    if (-not (Confirm-Action "Remove '$($e.Name)' from the boot menu? (The file is kept.)")) { return }
    foreach ($b in $e.Boot) { Invoke-Bcd @('/delete', $b.Id) | Out-Null; Write-Log "Removed '$($b.Description)'." }; Update-All }))
$rp.Controls.Add((New-Btn 'Disable expand-on-boot' 'ghost' 'Stops the selected environment from growing its file to the full maximum size while it is booted, using the registry setting VirtualDiskExpandOnMount=4 (guide step 9). Not needed if you ticked the option when creating the base. Risk: if the physical drive fills up, that Windows crashes.' { Disable-EnvExpand; Update-All }))
Add-EnvGroup 'Manage'
$rp.Controls.Add((New-Btn 'Change max size...' 'ghost' 'Changes the maximum size (the "Max" column) of a standalone disk, or of a base nobody is built on. Growing enlarges the virtual disk and extends the Windows partition inside it automatically. Shrinking needs the Hyper-V PowerShell module and is only possible if the data inside fits. Environments built on a base (differencing disks) cannot be resized: use "Make standalone copy" first. Not allowed for the running Windows or a locked disk, and the disk must not be in use.' { Set-EnvMaxSize; Update-All }))
$rp.Controls.Add((New-Btn 'Lock / unlock' 'ghost' 'Lock = make the file read-only and remove it from the boot menu, so it cannot be changed. Do this for a base once environments are built on it. Unlock makes it writable again, which is only allowed when nothing is built on it.' { Switch-EnvLock; Update-All }))
$rp.Controls.Add((New-Btn 'Reset to fresh' 'danger' 'Erases everything inside the selected environment and starts it again as a clean copy of its base. Its name and boot menu entry stay the same. Ideal for a throwaway "sandbox" environment.' { Reset-Env; Update-All }))
$rp.Controls.Add((New-Btn 'Delete environment' 'danger' 'Permanently deletes the selected environment file and removes its boot menu entries, and optionally its snapshots. A base that other environments are built on cannot be deleted until those are deleted.' { Remove-Env; Update-All }))
foreach ($c in $rp.Controls) { if ($c -is [RBtn]) { $c.Height = 30 } }
$pEnv.Controls.Add($cardEnv); $pEnv.Controls.Add($rp); $cardEnv.BringToFront()

# ======================= PAGE 4: BOOT MENU =======================
$BootList = New-List 'BootList' @(@('Boot menu name', 190), @('Boots from', 300), @('Status', 190), @('Id', 220)) 'No Windows boot entries could be read. Reading the boot menu needs administrator rights.'
$script:BootList = $BootList
Add-Help $BootList 'Boot menu' 'All Windows entries in the boot menu (the default is shown in bold). "Boots from" shows the VHDX file, or the physical partition for a normal install.'
$cardBoot = New-ListCard $BootList
$f4 = New-Flow; $f4.Dock = 'Bottom'; $f4.AutoSize = $true; $f4.Padding = Pad 0 18 0 0
[void]$f4.Controls.Add((New-Btn 'Set as default' 'primary' 'Makes the selected entry start automatically when nobody picks from the boot menu.' {
    $b = Get-SelectedBoot; Assert-BootableEntry $b; Invoke-Bcd @('/default', $b.Id) | Out-Null; Write-Log "Default is now '$($b.Description)'."; Update-All }))
[void]$f4.Controls.Add((New-Btn 'Restart into this' 'ghost' 'Restarts the PC into the selected entry once. The default does not change. You are asked first.' {
    $b = Get-SelectedBoot; Assert-BootableEntry $b; Start-RestartInto $b.Id $b.Description }))
[void]$f4.Controls.Add((New-Btn 'Rename' 'ghost' 'Changes the name of the selected entry in the boot menu.' {
    $b = Get-SelectedBoot; $l = Read-Text 'New boot menu name:' 'Rename' $b.Description; if (-not $l) { return }
    Invoke-Bcd @('/set', $b.Id, 'description', $l) | Out-Null; Write-Log "Renamed to '$l'."; Update-All }))
[void]$f4.Controls.Add((New-Btn 'Delete entry' 'danger' 'Removes the selected entry from the boot menu. Only the menu entry is removed: no files are deleted. You cannot delete the entry of the Windows you are running.' {
    $b = Get-SelectedBoot
    $cur = Get-BootEntries '{current}'; if ($cur.Count -and $cur[0].Id -eq $b.Id) { throw 'That is the Windows you are running right now; its entry cannot be deleted from here.' }
    if (-not (Confirm-Action "Remove '$($b.Description)' from the boot menu?`r`n(No files are deleted.)")) { return }
    Invoke-Bcd @('/delete', $b.Id) | Out-Null; Write-Log "Deleted entry '$($b.Description)'."; Update-All }))
$bRef4 = New-Btn 'Refresh' 'ghost' 'Re-reads the boot menu.' { Update-BootList }
$f4.Controls.Add($bRef4); $f4.SetFlowBreak($bRef4, $true)
$wl = New-Label 'Boot menu wait (seconds):' $script:fBody $script:cGrey; $wl.AutoSize = $true; $wl.Margin = Pad 0 15 10 0
$hTimeout = New-Num 0 999 10 96 'Boot menu wait' 'How many seconds the boot menu waits for you to choose before starting the default. 0 = skip the menu.'
$NumTimeout = $hTimeout.Inner; $script:NumTimeout = $NumTimeout
$hTimeout.Margin = Pad 0 10 8 0; $hTimeout.Anchor = 'None'
$bWait = New-Btn 'Set wait' 'ghost' 'Applies the boot menu wait time on the left.' {
    Invoke-Bcd @('/timeout', [string][int]$NumTimeout.Value) | Out-Null; Write-Log "Boot menu now waits $([int]$NumTimeout.Value) seconds." } 90 32
$bWait.Margin = Pad 0 10 0 0
$f4.Controls.Add($wl); $f4.Controls.Add($hTimeout); $f4.Controls.Add($bWait); $f4.SetFlowBreak($bWait, $true)
$note4 = New-Label 'Every change to the boot menu is backed up automatically. Restore an earlier state on the Backup / restore page.' $script:fSmall $script:cGrey
$note4.Size = Sz 520 34; $note4.Margin = Pad 0 6 0 0; $f4.Controls.Add($note4)
$pBoot.Controls.Add($cardBoot); $pBoot.Controls.Add($f4); $cardBoot.BringToFront()

# ======================= PAGE 5: BACKUP / RESTORE =======================
$BackupList = New-List 'BackupList' @(@('Date / time', 190), @('Reason / action', 380), @('Size', 90)) 'No boot configuration backups yet. One is made automatically before every change, or click Back up now.' $true
$script:BackupList = $BackupList
Add-Help $BackupList 'Boot configuration backups' 'Every saved state of the boot menu, newest first. A backup is made automatically before each change made with this tool (add / remove / rename entries, default, wait time, restore), plus any you create by hand (orange). Select one to see what is in it and what restoring it would change.'
$cardBackup = New-ListCard $BackupList
$detH = New-Multi (New-Object System.Drawing.Font('Consolas', 9)); $detH.Dock = 'Fill'
$BackupInfo = $detH.Inner; $script:BackupInfo = $BackupInfo
$detWrap = New-Object System.Windows.Forms.Panel; $detWrap.Dock = 'Bottom'; $detWrap.Height = 112; $detWrap.BackColor = $script:cWhite; $detWrap.Padding = Pad 0 6 0 0
$dl = Grp 'Details of selected backup'; $dl.Dock = 'Left'; $dl.Width = 240; $dl.TextAlign = 'MiddleLeft'
$kl = New-Label 'Keep newest automatic backups' $script:fBody $script:cGrey; $kl.Dock = 'Right'; $kl.Width = 220; $kl.TextAlign = 'MiddleRight'
$hKeep = New-Num 10 1000 $script:KeepBackups 100 'Backups to keep' 'How many automatic backups to keep. Older automatic ones are deleted when a new one is made. Backups you create with "Back up now" are never deleted automatically. Each backup is only a few tens of KB.'
$NumKeep = $hKeep.Inner; $script:NumKeep = $NumKeep
$NumKeep.Add_ValueChanged({ $script:KeepBackups = [int]$this.Value })
$hKeep.Anchor = 'None'; $hKeep.Dock = 'Right'; $hKeep.Margin = Pad 0 0 0 0
$ksp = New-Object System.Windows.Forms.Panel; $ksp.Dock = 'Right'; $ksp.Width = 10; $ksp.BackColor = $script:cWhite
$hdr = New-Object System.Windows.Forms.Panel; $hdr.Dock = 'Top'; $hdr.Height = 34; $hdr.BackColor = $script:cWhite
$hdr.Controls.Add($dl); $hdr.Controls.Add($kl); $hdr.Controls.Add($ksp); $hdr.Controls.Add($hKeep)
$detWrap.Controls.Add($detH); $detWrap.Controls.Add($hdr); $detH.BringToFront()
$BackupList.Add_SelectedIndexChanged({
    try {
      $n = $script:BackupList.SelectedItems.Count
      if ($n -eq 1) { $script:BackupInfo.Text = Get-BackupInfo $script:BackupList.SelectedItems[0].Tag }
      elseif ($n -gt 1) { $script:BackupInfo.Text = "$n backups selected." }
      else { $script:BackupInfo.Text = '' }
    }
    catch { $script:BackupInfo.Text = "Could not read this backup: $($_.Exception.Message)" }
  })
$f5 = New-Flow; $f5.Dock = 'Bottom'; $f5.AutoSize = $true; $f5.Padding = Pad 0 14 0 0
[void]$f5.Controls.Add((New-Btn 'Back up now' 'primary' 'Saves the current boot menu configuration right now, with an optional note. Manual backups are never removed automatically.' {
    $note = Read-Text 'Optional short note for this backup (e.g. before-bios-update). Leave empty for none:' 'Back up now' ''
    $reason = 'manual'; $s = ConvertTo-Slug $note; if ($s) { $reason = "manual-$s" }
    Backup-Bcd -Reason $reason -Force; Update-BackupList }))
[void]$f5.Controls.Add((New-Btn 'Restore selected...' 'ghost' 'Replaces the whole boot menu with the selected backup: entries, default and wait time. You see exactly what changes first, and the current state is saved automatically so the restore can be undone. VHDX files are not touched.' { Restore-BcdBackup }))
[void]$f5.Controls.Add((New-Btn 'Delete selected' 'danger' 'Deletes the selected backup file(s). Only the backup is removed.' {
    $sel = Get-SelectedBackups
    if (-not (Confirm-Action "Delete $($sel.Count) backup file(s)?")) { return }
    foreach ($b in $sel) { Remove-Item -LiteralPath $b.Path -Force; Write-Log "Deleted backup $($b.Name)" }
    Update-BackupList }))
[void]$f5.Controls.Add((New-Btn 'Open backups folder' 'ghost' 'Opens <VHD folder>\bcd-backups in File Explorer.' { Start-Process explorer.exe (Get-BackupDir) }))
$bRef5 = New-Btn 'Refresh' 'ghost' 'Re-reads the backup list.' { Update-BackupList }
$f5.Controls.Add($bRef5); $f5.SetFlowBreak($bRef5, $true)
$note5 = New-Label 'A backup is made automatically before every change this tool makes to the boot menu, and before every restore.' $script:fSmall $script:cGrey
$note5.Size = Sz 520 34; $note5.Margin = Pad 0 6 0 0; $f5.Controls.Add($note5)
$pBackup.Controls.Add($cardBackup); $pBackup.Controls.Add($detWrap); $pBackup.Controls.Add($f5); $cardBackup.BringToFront()

# ---- sidebar navigation ----
$Nav = New-Object NavRail
$Nav.Dock = 'Left'; $Nav.Width = 212
$Nav.Items = @('Check system', 'Create base', 'Environments', 'Boot menu', 'Backup / restore')
$Nav.Sub = 'Native VHD boot'
$Nav.Footer = $(if ($isAdmin) { 'Running as administrator' } else { 'Not elevated (limited)' })
$script:Nav = $Nav
$Nav.Add_SelectedChanged({ param($s, $e) Show-Page $s.Selected })
$script:lists = @($EnvList, $BootList, $BackupList)
function Show-Page([int]$i) {
  for ($k = 0; $k -lt $script:pageList.Count; $k++) { $script:pageList[$k].Visible = ($k -eq $i) }
  $script:Nav.Pick($i)
  $script:PageTitle.Text = $script:Nav.Items[$i]
  $script:pageList[$i].BringToFront()
  if ($i -eq 2) { & $script:envLayout $script:rp $null }
  foreach ($l in $script:lists) { if ($l.Visible) { $l.Refresh() } }
}
# the sidebar follows the busy state (Set-Busy disables $script:Tabs)
$Tabs.Add_EnabledChanged({ $script:Nav.Enabled = $this.Enabled })
$Form.Add_KeyDown({
    param($s, $e)
    if ($e.Control -and $e.KeyValue -ge 49 -and $e.KeyValue -le 53 -and $script:Tabs.Enabled) { Show-Page ($e.KeyValue - 49); $e.Handled = $true }
  })

# ---- top bar: page title + VHD folder ----
$top = New-Object System.Windows.Forms.Panel; $top.Dock = 'Top'; $top.Height = 92; $top.BackColor = $script:cWhite
$top.Add_Paint({ param($s, $e) $e.Graphics.DrawLine($script:penHair, 0, $s.Height - 1, $s.Width, $s.Height - 1) })
$PageTitle = New-Label 'Check system' (New-Object System.Drawing.Font('Segoe UI Light', 20)) $script:cInk
$PageTitle.Dock = 'Top'; $PageTitle.Height = 42; $PageTitle.TextAlign = 'MiddleLeft'
$script:PageTitle = $PageTitle
$row = New-Object System.Windows.Forms.Panel; $row.Dock = 'Top'; $row.Height = 44; $row.BackColor = $script:cWhite
$vl = New-Label 'VHD folder' $script:fBody $script:cGrey; $vl.Location = Pt 0 6; $vl.Size = Sz 90 32; $vl.TextAlign = 'MiddleLeft'
$TopPanel = New-Object System.Windows.Forms.Panel
$TopPanel.BackColor = $script:cWhite; $TopPanel.Location = Pt 92 0; $TopPanel.Size = Sz 500 44
$script:TopPanel = $TopPanel
$hFolder = New-Text 'C:\VHD' 'VHD folder' 'Where all environment files (.vhdx), snapshots, boot-config backups and the log are kept. Must be on an NTFS drive that is NOT BitLocker-encrypted. Default: C:\VHD. Inside a VHDX-booted Windows the physical drive has a different letter (often D:), and the tool detects that automatically.'
$TxtFolder = $hFolder.Inner; $script:TxtFolder = $TxtFolder
$hFolder.Dock = 'None'; $hFolder.Margin = Pad 0 0 0 0
$TxtFolder.Add_TextChanged({ try { Update-DefaultBaseSize } catch {} })
$TxtFolder.Add_Leave({ try { Update-All } catch { Write-Log "ERROR: $($_.Exception.Message)" } })
$fl = New-Flow; $fl.AutoSize = $true; $fl.WrapContents = $false; $fl.Margin = Pad 0 0 0 0; $fl.Padding = Pad 0 0 0 0
$b1 = New-Btn 'Browse...' 'ghost' 'Choose a different folder to store the VHDX files in.' {
  $d = New-Object System.Windows.Forms.FolderBrowserDialog
  $d.Description = 'Folder for VHDX files (NTFS, not BitLocker-encrypted)'
  if ($d.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) { $script:TxtFolder.Text = $d.SelectedPath; Update-All }
}
$b2 = New-Btn 'Open in Explorer' 'ghost' 'Opens the VHD folder in File Explorer.' { Start-Process explorer.exe (Get-VhdFolder) }
$b3 = New-Btn 'Refresh everything' 'ghost' 'Re-reads the VHDX files and the boot menu. Use this after changing things outside the tool.' { Update-All; Write-Log 'Refreshed.' }
foreach ($b in $b1, $b2, $b3) { $b.Margin = Pad 8 0 0 0; $fl.Controls.Add($b) }
$TopPanel.Controls.Add($hFolder); $TopPanel.Controls.Add($fl)
$script:topFl = $fl; $script:topHost = $hFolder; $script:topRow = $row; $script:topBar = $top
# narrow window: the buttons move below the folder box
$TopPanel.Add_Resize({
    param($s, $e)
    $w = $s.ClientSize.Width; $fw = $script:topFl.PreferredSize.Width
    if (($w - $fw - 12) -ge 200) {
      $script:topHost.SetBounds(0, 6, ($w - $fw - 12), 32); $script:topFl.Location = Pt ($w - $fw) 6
      $rh = 44
    }
    else {
      $script:topHost.SetBounds(0, 6, $w, 32); $script:topFl.Location = Pt ([Math]::Max(0, $w - $fw)) 42
      $rh = 78
    }
    if ($script:topRow.Height -ne $rh) { $script:topRow.Height = $rh; $script:topBar.Height = 42 + $rh + 6 }
  })
$row.Controls.Add($vl); $row.Controls.Add($TopPanel)
$row.Add_Resize({ param($s, $e) $script:TopPanel.SetBounds(92, 0, [Math]::Max(100, $s.ClientSize.Width - 92), $s.ClientSize.Height) })
$top.Controls.Add($row); $top.Controls.Add($PageTitle)

# ---- bottom card: description, status, log ----
$botCard = New-Object RCard; $botCard.Dock = 'Bottom'; $botCard.Height = 204; $botCard.Padding = Pad 18 10 18 10; $botCard.Radius = 12
$LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Multiline = $true; $LogBox.ReadOnly = $true; $LogBox.BorderStyle = 'None'; $LogBox.BackColor = $script:cWhite; $LogBox.ForeColor = $script:cGrey
$LogBox.Font = New-Object System.Drawing.Font('Consolas', 9); $LogBox.ScrollBars = 'Vertical'; $LogBox.Dock = 'Fill'
$script:LogBox = $LogBox; [Gfx]::Explorer($LogBox)
$logLine = New-Object System.Windows.Forms.Panel; $logLine.Dock = 'Top'; $logLine.Height = 7; $logLine.BackColor = $script:cWhite
$logLine.Add_Paint({ param($s, $e) $e.Graphics.DrawLine($script:penHair, 0, 3, $s.Width, 3) })
$StatusLbl = New-Label '' (New-Object System.Drawing.Font('Consolas', 8.5)) $script:cGrey
$StatusLbl.Dock = 'Top'; $StatusLbl.Height = 20; $StatusLbl.TextAlign = 'MiddleLeft'
$script:StatusLbl = $StatusLbl
$DescText = New-Object System.Windows.Forms.TextBox
$DescText.Multiline = $true; $DescText.ReadOnly = $true; $DescText.BorderStyle = 'None'; $DescText.BackColor = $script:cWhite; $DescText.ForeColor = $script:cGrey
$DescText.Font = $script:fBody; $DescText.ScrollBars = 'None'; $DescText.Dock = 'Top'; $DescText.Height = 66
[Gfx]::Explorer($DescText); Set-AutoScroll $DescText
$DescTitle = New-Label 'Description' (New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)) $script:cInk
$DescTitle.Dock = 'Top'; $DescTitle.Height = 22
$script:DescTitle = $DescTitle; $script:DescText = $DescText
$botCard.Controls.Add($LogBox); $botCard.Controls.Add($logLine); $botCard.Controls.Add($StatusLbl); $botCard.Controls.Add($DescText); $botCard.Controls.Add($DescTitle)
Show-HelpText 'Hover over any button' 'Move the mouse over a button or field and its explanation appears here. Work through the pages from top to bottom: check the PC, create a base Windows, then create environments from it.'

$script:botCard = $botCard
# short window: the description / log card gets smaller to leave room for the page
$Form.Add_Resize({
    $small = ($script:Form.ClientSize.Height -lt 740)
    $h = if ($small) { 168 } else { 204 }
    if ($script:botCard.Height -ne $h) { $script:botCard.Height = $h; $script:DescText.Height = $(if ($small) { 54 } else { 66 }) }
  })
$gap = New-Object System.Windows.Forms.Panel; $gap.Dock = 'Bottom'; $gap.Height = 14; $gap.BackColor = $script:cWhite
$right = New-Object System.Windows.Forms.Panel; $right.Dock = 'Fill'; $right.BackColor = $script:cWhite; $right.Padding = Pad 24 6 24 14
$right.Controls.Add($Tabs); $right.Controls.Add($gap); $right.Controls.Add($botCard); $right.Controls.Add($top)
$Form.Controls.Add($right); $Form.Controls.Add($Nav)
Show-Page 0

# ---- startup / shutdown ----
$running = $null
try { $running = Get-RunningVhd } catch {}
if ($VhdFolder) { $TxtFolder.Text = $VhdFolder } elseif ($running) { $TxtFolder.Text = Split-Path $running -Parent } else { $TxtFolder.Text = 'C:\VHD' }
Restore-WindowState

# window chrome (Windows 11 title bar colours) and verification helpers
function Set-Dwm($attr, $val) { try { [void][Win.Dwm]::DwmSetWindowAttribute($script:Form.Handle, $attr, [ref]$val, 4) } catch {} }
function Save-Shot([string]$Path) {
  $f = $script:Form
  $bmp = New-Object System.Drawing.Bitmap($f.Width, $f.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  try { [void][Win.U32]::PrintWindow($f.Handle, $hdc, 2) } finally { $g.ReleaseHdc($hdc) }
  $g.Dispose(); $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}

$Form.Add_Shown({
    Set-Dwm 20 0; Set-Dwm 35 0x00FFFFFF; Set-Dwm 36 0x00111111; Set-Dwm 34 0x00DDDDDD
    Invoke-Action 'Loading' {
      Write-Log "VHDX Boot Manager started. Booted from: $(if ($running) { $running } else { 'physical disk' })"
      Update-All
      Invoke-SystemCheck
    }
    Show-Page 0
    if ($ScreenshotDir) {
      $script:shotTimer = New-Object System.Windows.Forms.Timer; $script:shotTimer.Interval = 600
      $script:shotTimer.Add_Tick({
          $script:shotTimer.Stop()
          try {
            New-Item -ItemType Directory -Force -Path $ScreenshotDir | Out-Null
            for ($k = 1; $k -le 5; $k++) {
              Show-Page ($k - 1)
              [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 400; [System.Windows.Forms.Application]::DoEvents()
              Save-Shot (Join-Path $ScreenshotDir ("page{0}.png" -f $k))
            }
          }
          finally { $script:Form.Close() }
        })
      $script:shotTimer.Start()
    }
  })
$Form.Add_FormClosing({ Save-WindowState; Dismount-Iso })

if ($AutoCloseSeconds -gt 0) {
  $script:closeTimer = New-Object System.Windows.Forms.Timer; $script:closeTimer.Interval = $AutoCloseSeconds * 1000
  $script:closeTimer.Add_Tick({ $script:closeTimer.Stop(); $script:Form.Close() }); $script:closeTimer.Start()
}
[void]$Form.ShowDialog()
