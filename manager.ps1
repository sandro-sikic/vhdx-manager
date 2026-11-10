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

# --------------------------------------------------------------------------
#  Relaunch elevated, 64-bit, in Windows PowerShell 5.1 (WinForms + DISM)
# --------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$is32on64 = [Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess
$isCore = $PSVersionTable.PSEdition -eq 'Core'
if (-not $isAdmin -or $is32on64 -or $isCore) {
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

function Update-All {
  Update-EnvList
  Update-BootList
  Update-BackupList
}

# ==========================================================================
#  GUI
# ==========================================================================
function New-Btn($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [string]$HelpText, [scriptblock]$Action, [int]$H = 32) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $Text
  $b.Location = New-Object System.Drawing.Point($X, $Y)
  $b.Size = New-Object System.Drawing.Size($W, $H)
  $Parent.Controls.Add($b)
  Add-Help $b $Text $HelpText
  $b.Tag = @{ Name = $Text; Action = $Action }
  $b.Add_Click({ $t = $this.Tag; Invoke-Action $t.Name $t.Action })
  return $b
}

function New-Lbl($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 110, [int]$H = 20) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, $H)
  $Parent.Controls.Add($l)
  return $l
}

$Form = New-Object System.Windows.Forms.Form
$Form.Text = 'VHDX Boot Manager - multiple bare-metal Windows environments'
$Form.ClientSize = New-Object System.Drawing.Size(1040, 770)
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'Sizable'
$Form.MaximizeBox = $true
$Form.ClientSize = New-Object System.Drawing.Size(800, 680)
$Form.MinimumSize = $Form.Size   # smallest allowed window
$Form.ClientSize = New-Object System.Drawing.Size(1040, 770)
$Form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
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

# ---- top bar: VHD folder ----
$TopPanel = New-Object System.Windows.Forms.Panel
$TopPanel.Location = New-Object System.Drawing.Point(10, 8)
$TopPanel.Size = New-Object System.Drawing.Size(1020, 34)
$TopPanel.Anchor = 'Top, Left, Right'
$Form.Controls.Add($TopPanel)
$script:TopPanel = $TopPanel

[void](New-Lbl $TopPanel 'VHD folder:' 0 8 80)
$TxtFolder = New-Object System.Windows.Forms.TextBox
$TxtFolder.Location = New-Object System.Drawing.Point(82, 5)
$TxtFolder.Size = New-Object System.Drawing.Size(520, 24)
$TxtFolder.Anchor = 'Top, Left, Right'
$TopPanel.Controls.Add($TxtFolder)
$script:TxtFolder = $TxtFolder
Add-Help $TxtFolder 'VHD folder' 'Where all environment files (.vhdx), snapshots, boot-config backups and the log are kept. Must be on an NTFS drive that is NOT BitLocker-encrypted. Default: C:\VHD. Inside a VHDX-booted Windows the physical drive has a different letter (often D:), and the tool detects that automatically.'
$TxtFolder.Add_Leave({ try { Update-All } catch { Write-Log "ERROR: $($_.Exception.Message)" } })

$b1 = New-Btn $TopPanel 'Browse...' 610 2 90 'Choose a different folder to store the VHDX files in.' {
  $d = New-Object System.Windows.Forms.FolderBrowserDialog
  $d.Description = 'Folder for VHDX files (NTFS, not BitLocker-encrypted)'
  if ($d.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) { $script:TxtFolder.Text = $d.SelectedPath; Update-All }
} 30
$b2 = New-Btn $TopPanel 'Open in Explorer' 705 2 130 'Opens the VHD folder in File Explorer.' { Start-Process explorer.exe (Get-VhdFolder) } 30
$b3 = New-Btn $TopPanel 'Refresh everything' 840 2 178 'Re-reads the VHDX files and the boot menu. Use this after changing things outside the tool.' { Update-All; Write-Log 'Refreshed.' } 30
foreach ($b in $b1, $b2, $b3) { $b.Anchor = 'Top, Right' }

# ---- tabs ----
$Tabs = New-Object System.Windows.Forms.TabControl
$Tabs.Location = New-Object System.Drawing.Point(10, 48)
$Tabs.Size = New-Object System.Drawing.Size(1020, 420)
$Tabs.Anchor = 'Top, Bottom, Left, Right'
$Form.Controls.Add($Tabs)
$script:Tabs = $Tabs
$TabCheck = New-Object System.Windows.Forms.TabPage; $TabCheck.Text = '  1. Check system  '
$TabBase = New-Object System.Windows.Forms.TabPage; $TabBase.Text = '  2. Create base  '
$TabEnv = New-Object System.Windows.Forms.TabPage; $TabEnv.Text = '  3. Environments  '
$TabBoot = New-Object System.Windows.Forms.TabPage; $TabBoot.Text = '  4. Boot menu  '
$TabBackup = New-Object System.Windows.Forms.TabPage; $TabBackup.Text = '  5. Backup / restore  '
$Tabs.TabPages.AddRange(@($TabCheck, $TabBase, $TabEnv, $TabBoot, $TabBackup))
# Give the pages their real size NOW: anchors are calculated from the parent's size when a control is
# added, and a page that has not been shown yet is tiny, which pushed anchored buttons out of view.
foreach ($tp in $TabCheck, $TabBase, $TabEnv, $TabBoot, $TabBackup) { $tp.Size = New-Object System.Drawing.Size(1012, 390) }

# ---- description panel ----
$DescGroup = New-Object System.Windows.Forms.GroupBox
$DescGroup.Text = 'What does this do?'
$DescGroup.Location = New-Object System.Drawing.Point(10, 474)
$DescGroup.Size = New-Object System.Drawing.Size(1020, 108)
$DescGroup.Anchor = 'Bottom, Left, Right'
$Form.Controls.Add($DescGroup)
$DescTitle = New-Object System.Windows.Forms.Label
$DescTitle.Location = New-Object System.Drawing.Point(10, 20)
$DescTitle.Size = New-Object System.Drawing.Size(1000, 20)
$DescTitle.Anchor = 'Top, Left, Right'
$DescTitle.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$DescGroup.Controls.Add($DescTitle)
$DescText = New-Object System.Windows.Forms.TextBox
$DescText.Location = New-Object System.Drawing.Point(10, 42)
$DescText.Size = New-Object System.Drawing.Size(1000, 60)
$DescText.Anchor = 'Top, Bottom, Left, Right'
$DescText.Multiline = $true
$DescText.ReadOnly = $true
$DescText.BorderStyle = 'None'
$DescText.BackColor = $DescGroup.BackColor
$DescText.ScrollBars = 'Vertical'
$DescGroup.Controls.Add($DescText)
$script:DescTitle = $DescTitle; $script:DescText = $DescText
Show-HelpText 'Hover over any button' 'Move the mouse over a button or field and its explanation appears here. Work through the tabs from left to right: check the PC, create a base Windows, then create environments from it.'

# ---- status + log ----
$StatusLbl = New-Object System.Windows.Forms.Label
$StatusLbl.Location = New-Object System.Drawing.Point(10, 586)
$StatusLbl.Size = New-Object System.Drawing.Size(1020, 18)
$StatusLbl.Anchor = 'Bottom, Left, Right'
$StatusLbl.ForeColor = [System.Drawing.Color]::DarkBlue
$StatusLbl.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$Form.Controls.Add($StatusLbl)
$script:StatusLbl = $StatusLbl

$LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Location = New-Object System.Drawing.Point(10, 606)
$LogBox.Size = New-Object System.Drawing.Size(1020, 156)
$LogBox.Anchor = 'Bottom, Left, Right'
$LogBox.Multiline = $true
$LogBox.ReadOnly = $true
$LogBox.ScrollBars = 'Vertical'
$LogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$LogBox.BackColor = [System.Drawing.Color]::White
$Form.Controls.Add($LogBox)
$script:LogBox = $LogBox

# ======================= TAB 1: CHECK =======================
[void](New-Btn $TabCheck 'Run system check' 10 10 200 'Checks everything needed before you start: your Windows edition, UEFI firmware, whether the VHD folder is on an NTFS drive with enough free space, whether that drive is BitLocker/Device-Encryption encrypted (native VHDX boot fails on encrypted drives), whether you are currently booted from a VHDX, and what is in the boot menu. It only reads information and does not change anything.' { Invoke-SystemCheck } 34)
$chkInfo = New-Lbl $TabCheck 'Start here. If anything shows FAIL, fix it before creating a base (most often: the drive holding the VHD folder is encrypted - pick another drive or turn off Device Encryption in Settings > Privacy & security).' 230 10 770 40
$chkInfo.Anchor = 'Top, Left, Right'
$CheckOut = New-Object System.Windows.Forms.TextBox
$CheckOut.Location = New-Object System.Drawing.Point(10, 55)
$CheckOut.Size = New-Object System.Drawing.Size(990, 325)
$CheckOut.Anchor = 'Top, Bottom, Left, Right'
$CheckOut.Multiline = $true
$CheckOut.ReadOnly = $true
$CheckOut.ScrollBars = 'Vertical'
$CheckOut.Font = New-Object System.Drawing.Font('Consolas', 9)
$CheckOut.BackColor = [System.Drawing.Color]::White
$TabCheck.Controls.Add($CheckOut)
$script:CheckOut = $CheckOut

# ======================= TAB 2: CREATE BASE =======================
[void](New-Lbl $TabBase 'Windows ISO:' 10 18)
$TxtIso = New-Object System.Windows.Forms.TextBox
$TxtIso.Location = New-Object System.Drawing.Point(125, 15); $TxtIso.Size = New-Object System.Drawing.Size(380, 24)
$TabBase.Controls.Add($TxtIso); $script:TxtIso = $TxtIso
Add-Help $TxtIso 'Windows ISO' 'The Windows installation ISO to build the base from. Download the official Windows 11 ISO from microsoft.com/software-download/windows11.'
[void](New-Btn $TabBase 'Browse...' 510 12 100 'Pick the Windows ISO file. After you choose it, its editions are read automatically.' {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Windows ISO (*.iso)|*.iso'
    if ($d.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) { $script:TxtIso.Text = $d.FileName; Read-Editions }
  } 28)

[void](New-Lbl $TabBase 'Edition:' 10 53)
$CmbEdition = New-Object System.Windows.Forms.ComboBox
$CmbEdition.Location = New-Object System.Drawing.Point(125, 50); $CmbEdition.Size = New-Object System.Drawing.Size(380, 24)
$CmbEdition.DropDownStyle = 'DropDownList'
$TabBase.Controls.Add($CmbEdition); $script:CmbEdition = $CmbEdition
Add-Help $CmbEdition 'Edition' 'Which Windows edition to install into the base. Choose Pro (or Enterprise/Education): Home cannot boot from a VHDX. Your digital licence usually activates the same edition you already have on this PC.'
[void](New-Btn $TabBase 'Read editions' 510 47 100 'Mounts the ISO and lists the Windows editions inside it (the same as "dism /Get-WimInfo" in the guide). Pro is selected automatically.' { Read-Editions } 28)

[void](New-Lbl $TabBase 'File name:' 10 88)
$TxtBaseName = New-Object System.Windows.Forms.TextBox
$TxtBaseName.Location = New-Object System.Drawing.Point(125, 85); $TxtBaseName.Size = New-Object System.Drawing.Size(200, 24); $TxtBaseName.Text = 'base'
$TabBase.Controls.Add($TxtBaseName); $script:TxtBaseName = $TxtBaseName
Add-Help $TxtBaseName 'File name' 'Name of the base disk file (".vhdx" is added). Use a version in the name if you plan to rebuild later, e.g. base-25H2.'
[void](New-Lbl $TabBase '.vhdx' 330 88 60)

[void](New-Lbl $TabBase 'Boot menu name:' 10 123)
$TxtBootLabel = New-Object System.Windows.Forms.TextBox
$TxtBootLabel.Location = New-Object System.Drawing.Point(125, 120); $TxtBootLabel.Size = New-Object System.Drawing.Size(200, 24); $TxtBootLabel.Text = 'Win - Base'
$TabBase.Controls.Add($TxtBootLabel); $script:TxtBootLabel = $TxtBootLabel
Add-Help $TxtBootLabel 'Boot menu name' 'The name shown in the boot menu when the PC starts. You boot the base only once, to set it up; after that it is locked.'

[void](New-Lbl $TabBase 'Max size (GB):' 10 158)
$NumSize = New-Object System.Windows.Forms.NumericUpDown
$NumSize.Location = New-Object System.Drawing.Point(125, 155); $NumSize.Size = New-Object System.Drawing.Size(80, 24)
$NumSize.Minimum = 40; $NumSize.Maximum = 4000; $NumSize.Value = 100
$TabBase.Controls.Add($NumSize); $script:NumSize = $NumSize
Add-Help $NumSize 'Maximum size' 'The largest size the virtual disk can grow to. The file starts small and grows as data is added. Every environment built on this base gets the same maximum. 80-150 GB is typical; keep games and big data on a physical drive instead.'

$ChkAddBoot = New-Object System.Windows.Forms.CheckBox
$ChkAddBoot.Location = New-Object System.Drawing.Point(125, 190); $ChkAddBoot.Size = New-Object System.Drawing.Size(480, 22)
$ChkAddBoot.Text = 'Add it to the boot menu (needed to set it up)'; $ChkAddBoot.Checked = $true
$TabBase.Controls.Add($ChkAddBoot); $script:ChkAddBoot = $ChkAddBoot
Add-Help $ChkAddBoot 'Add to boot menu' 'Creates a boot menu entry for the base so you can start it once and finish Windows setup. Your current Windows stays the default.'

$ChkNoExpand = New-Object System.Windows.Forms.CheckBox
$ChkNoExpand.Location = New-Object System.Drawing.Point(125, 214); $ChkNoExpand.Size = New-Object System.Drawing.Size(480, 22)
$ChkNoExpand.Text = "Don't expand the file to full size when booted (saves disk space)"
$TabBase.Controls.Add($ChkNoExpand); $script:ChkNoExpand = $ChkNoExpand
Add-Help $ChkNoExpand "Don't expand at boot" 'Normally Windows grows a dynamic VHDX to its FULL maximum size while it is booted (a 100 GB disk takes 100 GB on the drive). Ticking this writes VirtualDiskExpandOnMount=4 into the new Windows, so files stay small. Every environment built on this base inherits it. Risk: if the physical drive fills up completely, the running environment crashes.'

[void](New-Lbl $TabBase 'Answer file:' 10 248)
$TxtAnswer = New-Object System.Windows.Forms.TextBox
$TxtAnswer.Location = New-Object System.Drawing.Point(125, 245); $TxtAnswer.Size = New-Object System.Drawing.Size(380, 24)
$TabBase.Controls.Add($TxtAnswer); $script:TxtAnswer = $TxtAnswer
Add-Help $TxtAnswer 'Answer file (optional)' 'An unattend.xml / autounattend.xml to apply to the new Windows (skip OOBE, create the user, computer name, language, scripts...). It is copied to Windows\Panther\unattend.xml, so the specialize and oobeSystem passes run on the first boot. windowsPE-pass settings (disk layout, edition, setup product key) cannot apply because Windows Setup is not used. Leave empty to use the one inside the ISO, if there is one.'
[void](New-Btn $TabBase 'Browse...' 510 242 100 'Choose an external answer file. It overrides any autounattend.xml inside the ISO.' {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Answer file (*.xml)|*.xml|All files (*.*)|*.*'
    if ($d.ShowDialog($script:Form) -eq [System.Windows.Forms.DialogResult]::OK) { $script:TxtAnswer.Text = $d.FileName }
  } 28)

$ChkIsoAnswer = New-Object System.Windows.Forms.CheckBox
$ChkIsoAnswer.Location = New-Object System.Drawing.Point(125, 272); $ChkIsoAnswer.Size = New-Object System.Drawing.Size(500, 22)
$ChkIsoAnswer.Text = 'Pick the ISO and click "Read editions" to look for an autounattend.xml'; $ChkIsoAnswer.Enabled = $false
$TabBase.Controls.Add($ChkIsoAnswer); $script:ChkIsoAnswer = $ChkIsoAnswer
Add-Help $ChkIsoAnswer 'Use answer file from ISO' 'Many custom ISOs contain autounattend.xml in the root. Normally only Windows Setup reads it; this tool applies the image directly, so it copies the file (and sources\$OEM$ folders, if present) into the new Windows itself. A file chosen with Browse overrides this.'

$BtnCreate = New-Btn $TabBase 'Create base VHDX' 125 300 250 'Does guide steps 2-5 in one go: creates the virtual disk file in the VHD folder, partitions and formats it, installs the chosen Windows edition into it with DISM (5-15 minutes), applies the answer file and the optional no-expand setting, detaches it and adds a boot menu entry, without changing your default Windows. A backup of the boot configuration is saved first.' { New-BaseVhdx } 42
$BtnCreate.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

[void](New-Btn $TabBase 'Copy sysprep command' 125 350 250 "Copies this command to the clipboard:`r`n$SysprepCmd`r`nOptional: run it in an administrator Command Prompt INSIDE the base, as the last thing before you create environments. It gives every environment its own unique identity (recommended if several will be on the network or join a domain). The base then shuts down; each environment runs a short setup on its first boot." {
    [System.Windows.Forms.Clipboard]::SetText($SysprepCmd)
    Write-Log "Copied to clipboard: $SysprepCmd"
  } 32)

$StepsBox = New-Object System.Windows.Forms.GroupBox
$StepsBox.Text = 'After the base is created'
$StepsBox.Location = New-Object System.Drawing.Point(640, 10); $StepsBox.Size = New-Object System.Drawing.Size(360, 370)
$StepsBox.Anchor = 'Top, Right'
$TabBase.Controls.Add($StepsBox)
# Small window: scroll the Create base form, and hide the side instructions when they would overlap the fields
$TabBase.AutoScroll = $true
$TabBase.AutoScrollMinSize = New-Object System.Drawing.Size(0, 392)
$TabBase.Add_Resize({ $script:StepsBox.Visible = ($this.ClientSize.Width -ge 1000) })
$script:StepsBox = $StepsBox
[void](New-Lbl $StepsBox ("1.  Restart and pick the base in the boot menu (the tool offers to do this for you).`r`n`r`n" +
    "2.  Finish Windows setup. Install drivers, all Windows Updates, and the apps EVERY environment should have. Keep it lean.`r`n`r`n" +
    "3.  Optional: run sysprep (button on the left) as the last step.`r`n`r`n" +
    "4.  Shut down and start your normal Windows.`r`n`r`n" +
    "5.  Open this tool > Environments tab > select the base > 'New environment from selected'. Create as many as you like.`r`n`r`n" +
    "After that, never boot or change the base: the environments are built on it.") 12 22 336 340)

# ======================= TAB 3: ENVIRONMENTS =======================
$EnvList = New-Object System.Windows.Forms.ListView
$EnvList.Location = New-Object System.Drawing.Point(10, 10); $EnvList.Size = New-Object System.Drawing.Size(640, 372)
$EnvList.View = 'Details'; $EnvList.FullRowSelect = $true; $EnvList.MultiSelect = $false; $EnvList.HideSelection = $false; $EnvList.GridLines = $true
[void]$EnvList.Columns.Add('Name', 125); [void]$EnvList.Columns.Add('Type', 75); [void]$EnvList.Columns.Add('Built on', 90)
[void]$EnvList.Columns.Add('Size', 80); [void]$EnvList.Columns.Add('Boot menu name', 180); [void]$EnvList.Columns.Add('Status', 70)
$EnvList.Anchor = 'Top, Bottom, Left, Right'
$EnvList.Add_Resize({ $w = $this.ClientSize.Width - 440 - 4; $this.Columns[4].Width = [Math]::Max(100, $w) })
$TabEnv.Controls.Add($EnvList); $script:EnvList = $EnvList
$EnvList.Add_SelectedIndexChanged({ if ($this.SelectedItems.Count) { $e = $this.SelectedItems[0].Tag; Show-HelpText "Selected: $($e.Name)" (Get-EnvSummary $e) } })
Add-Help $EnvList 'Environments' 'Every .vhdx in the VHD folder. Base = the clean Windows that environments are built on (never boot it). Child = an environment that only stores its own changes on top of a base. Standalone = an independent full disk. Select one, then use the buttons on the right.'

$c1 = 660; $c2 = 835; $w = 168; $y0 = 10; $dy = 38
[void](New-Btn $TabEnv 'New environment from selected' $c1 ($y0 + 0 * $dy) $w "Creates a new environment (e.g. work, gaming, sandbox) built on the selected base. The new file starts at a few MB and stores only what changes compared to the base. A boot menu entry is added, and the tool offers to lock the base (read-only, removed from the boot menu) so it can't be changed by accident." { New-ChildEnv; Update-All })
[void](New-Btn $TabEnv 'Snapshot' $c1 ($y0 + 1 * $dy) $w 'Saves a copy of the selected environment into <VHD folder>\snapshots, with the date and an optional note in the name. Do this before risky changes (driver updates, new software). Environments are usually small, so this is quick. The environment must not be the one you are running.' { Save-Snapshot; Update-All })
[void](New-Btn $TabEnv 'Restore snapshot...' $c1 ($y0 + 2 * $dy) $w "Rolls the selected environment back to a snapshot you choose. Everything changed since that snapshot is lost. Works only while you're NOT running that environment." { Restore-Snapshot; Update-All })
[void](New-Btn $TabEnv 'Reset to fresh' $c1 ($y0 + 3 * $dy) $w 'Erases everything inside the selected environment and starts it again as a clean copy of its base. Its name and boot menu entry stay the same. Ideal for a throwaway "sandbox" environment.' { Reset-Env; Update-All })
[void](New-Btn $TabEnv 'Make standalone copy' $c1 ($y0 + 4 * $dy) $w 'Creates an independent full copy of the selected environment, merged with its base into one file that no longer depends on anything. Useful for keeping an environment forever, moving it to another drive, or making it the base for a new set. Takes longer and uses more space.' { New-StandaloneCopy; Update-All })
[void](New-Btn $TabEnv 'Open snapshots folder' $c1 ($y0 + 5 * $dy) $w 'Opens <VHD folder>\snapshots in File Explorer, where you can delete old snapshots you no longer need.' {
    $d = Join-Path (Get-VhdFolder) 'snapshots'; New-Item -ItemType Directory -Path $d -Force | Out-Null; Start-Process explorer.exe $d })
[void](New-Btn $TabEnv 'Delete environment' $c1 ($y0 + 6 * $dy) $w 'Permanently deletes the selected environment file and removes its boot menu entries, and optionally its snapshots. A base that other environments are built on cannot be deleted until those are deleted.' { Remove-Env; Update-All })

[void](New-Btn $TabEnv 'Restart into this' $c2 ($y0 + 0 * $dy) $w 'Restarts the PC straight into the selected environment, for this one restart only (bcdedit /bootsequence). Your default does not change. You are asked before the restart happens.' {
    $e = Get-SelectedEnv; Assert-NoChildren $e; $b = Get-EnvBootEntry $e -OfferToAdd; Update-All; Start-RestartInto $b.Id $b.Description })
[void](New-Btn $TabEnv 'Set as default boot' $c2 ($y0 + 1 * $dy) $w 'Makes the selected environment the one that starts automatically when nobody picks from the boot menu.' {
    $e = Get-SelectedEnv; Assert-NoChildren $e; $b = Get-EnvBootEntry $e -OfferToAdd; Invoke-Bcd @('/default', $b.Id) | Out-Null; Write-Log "Default boot is now '$($b.Description)'."; Update-All })
[void](New-Btn $TabEnv 'Add boot menu entry' $c2 ($y0 + 2 * $dy) $w 'Adds the selected environment to the boot menu, e.g. a standalone copy, or an environment whose entry you removed. Not allowed for a base that others are built on.' {
    $e = Get-SelectedEnv; Assert-NoChildren $e
    $l = Read-Text 'Name to show in the boot menu:' 'Boot menu name' "Win - $($e.Name)"; if (-not $l) { return }
    New-BootEntry $e.Path $l | Out-Null; Update-All })
[void](New-Btn $TabEnv 'Rename boot menu entry' $c2 ($y0 + 3 * $dy) $w 'Changes the name shown for the selected environment in the boot menu.' {
    $e = Get-SelectedEnv; $b = Get-EnvBootEntry $e
    $l = Read-Text 'New boot menu name:' 'Rename' $b.Description; if (-not $l) { return }
    Invoke-Bcd @('/set', $b.Id, 'description', $l) | Out-Null; Write-Log "Renamed to '$l'."; Update-All })
[void](New-Btn $TabEnv 'Remove boot menu entries' $c2 ($y0 + 4 * $dy) $w 'Removes the selected environment from the boot menu. The file is kept, so you can add it back later.' {
    $e = Get-SelectedEnv; Assert-NotRunning $e
    if (-not $e.Boot.Count) { throw "'$($e.Name)' is not in the boot menu." }
    if (-not (Confirm-Action "Remove '$($e.Name)' from the boot menu? (The file is kept.)")) { return }
    foreach ($b in $e.Boot) { Invoke-Bcd @('/delete', $b.Id) | Out-Null; Write-Log "Removed '$($b.Description)'." }; Update-All })
[void](New-Btn $TabEnv 'Disable expand-on-boot' $c2 ($y0 + 5 * $dy) $w 'Stops the selected environment from growing its file to the full maximum size while it is booted, using the registry setting VirtualDiskExpandOnMount=4 (guide step 9). Not needed if you ticked the option when creating the base. Risk: if the physical drive fills up, that Windows crashes.' { Disable-EnvExpand; Update-All })
[void](New-Btn $TabEnv 'Lock / unlock' $c2 ($y0 + 6 * $dy) $w 'Lock = make the file read-only and remove it from the boot menu, so it cannot be changed. Do this for a base once environments are built on it. Unlock makes it writable again, which is only allowed when nothing is built on it.' { Switch-EnvLock; Update-All })

# ======================= TAB 4: BOOT MENU =======================
$BootList = New-Object System.Windows.Forms.ListView
$BootList.Location = New-Object System.Drawing.Point(10, 10); $BootList.Size = New-Object System.Drawing.Size(640, 372)
$BootList.View = 'Details'; $BootList.FullRowSelect = $true; $BootList.MultiSelect = $false; $BootList.HideSelection = $false; $BootList.GridLines = $true
[void]$BootList.Columns.Add('Boot menu name', 170); [void]$BootList.Columns.Add('Boots from', 230)
[void]$BootList.Columns.Add('Status', 90); [void]$BootList.Columns.Add('Id', 130)
$BootList.Anchor = 'Top, Bottom, Left, Right'
$BootList.Add_Resize({ $w = $this.ClientSize.Width - 390 - 4; $this.Columns[1].Width = [Math]::Max(120, $w) })
$TabBoot.Controls.Add($BootList); $script:BootList = $BootList
Add-Help $BootList 'Boot menu' 'All Windows entries in the boot menu (the default is shown in bold). "Boots from" shows the VHDX file, or the physical partition for a normal install.'

[void](New-Btn $TabBoot 'Refresh' $c1 ($y0 + 0 * $dy) $w 'Re-reads the boot menu.' { Update-BootList })
[void](New-Btn $TabBoot 'Set as default' $c1 ($y0 + 1 * $dy) $w 'Makes the selected entry start automatically when nobody picks from the boot menu.' {
    $b = Get-SelectedBoot; Assert-BootableEntry $b; Invoke-Bcd @('/default', $b.Id) | Out-Null; Write-Log "Default is now '$($b.Description)'."; Update-All })
[void](New-Btn $TabBoot 'Restart into this' $c1 ($y0 + 2 * $dy) $w 'Restarts the PC into the selected entry once. The default does not change. You are asked first.' {
    $b = Get-SelectedBoot; Assert-BootableEntry $b; Start-RestartInto $b.Id $b.Description })
[void](New-Btn $TabBoot 'Rename' $c1 ($y0 + 3 * $dy) $w 'Changes the name of the selected entry in the boot menu.' {
    $b = Get-SelectedBoot; $l = Read-Text 'New boot menu name:' 'Rename' $b.Description; if (-not $l) { return }
    Invoke-Bcd @('/set', $b.Id, 'description', $l) | Out-Null; Write-Log "Renamed to '$l'."; Update-All })
[void](New-Btn $TabBoot 'Delete entry' $c1 ($y0 + 4 * $dy) $w 'Removes the selected entry from the boot menu. Only the menu entry is removed: no files are deleted. You cannot delete the entry of the Windows you are running.' {
    $b = Get-SelectedBoot
    $cur = Get-BootEntries '{current}'; if ($cur.Count -and $cur[0].Id -eq $b.Id) { throw 'That is the Windows you are running right now; its entry cannot be deleted from here.' }
    if (-not (Confirm-Action "Remove '$($b.Description)' from the boot menu?`r`n(No files are deleted.)")) { return }
    Invoke-Bcd @('/delete', $b.Id) | Out-Null; Write-Log "Deleted entry '$($b.Description)'."; Update-All })

$lblTo = New-Lbl $TabBoot 'Boot menu wait (seconds):' $c2 ($y0 + 8) 170
$NumTimeout = New-Object System.Windows.Forms.NumericUpDown
$NumTimeout.Location = New-Object System.Drawing.Point($c2, ($y0 + 1 * $dy - 4)); $NumTimeout.Size = New-Object System.Drawing.Size(70, 24)
$NumTimeout.Minimum = 0; $NumTimeout.Maximum = 999; $NumTimeout.Value = 10
$TabBoot.Controls.Add($NumTimeout)
Add-Help $NumTimeout 'Boot menu wait' 'How many seconds the boot menu waits for you to choose before starting the default. 0 = skip the menu.'
[void](New-Btn $TabBoot 'Set wait' ($c2 + 78) ($y0 + 1 * $dy - 6) 90 'Applies the boot menu wait time on the left.' {
    Invoke-Bcd @('/timeout', [string][int]$NumTimeout.Value) | Out-Null; Write-Log "Boot menu now waits $([int]$NumTimeout.Value) seconds." } 28)
[void](New-Lbl $TabBoot "Every change to the boot menu is backed up automatically. Restore an earlier state on tab 5." $c2 ($y0 + 2 * $dy + 10) 168 70)

# ======================= TAB 5: BACKUP / RESTORE =======================
$BackupList = New-Object System.Windows.Forms.ListView
$BackupList.Location = New-Object System.Drawing.Point(10, 10); $BackupList.Size = New-Object System.Drawing.Size(640, 232)
$BackupList.View = 'Details'; $BackupList.FullRowSelect = $true; $BackupList.MultiSelect = $true; $BackupList.HideSelection = $false; $BackupList.GridLines = $true
[void]$BackupList.Columns.Add('Date / time', 150); [void]$BackupList.Columns.Add('Reason / action', 380); [void]$BackupList.Columns.Add('Size', 70)
$BackupList.Anchor = 'Top, Bottom, Left, Right'
$BackupList.Add_Resize({ $this.Columns[1].Width = [Math]::Max(120, $this.ClientSize.Width - 220 - 4) })
$TabBackup.Controls.Add($BackupList); $script:BackupList = $BackupList
Add-Help $BackupList 'Boot configuration backups' 'Every saved state of the boot menu, newest first. A backup is made automatically before each change made with this tool (add / remove / rename entries, default, wait time, restore), plus any you create by hand (blue). Select one to see what is in it and what restoring it would change.'

$BackupInfo = New-Object System.Windows.Forms.TextBox
$BackupInfo.Location = New-Object System.Drawing.Point(10, 250); $BackupInfo.Size = New-Object System.Drawing.Size(640, 132)
$BackupInfo.Multiline = $true; $BackupInfo.ReadOnly = $true; $BackupInfo.ScrollBars = 'Vertical'
$BackupInfo.Font = New-Object System.Drawing.Font('Consolas', 8.5); $BackupInfo.BackColor = [System.Drawing.Color]::White
$BackupInfo.Anchor = 'Bottom, Left, Right'
$TabBackup.Controls.Add($BackupInfo); $script:BackupInfo = $BackupInfo
$BackupList.Add_SelectedIndexChanged({
    try {
      $n = $script:BackupList.SelectedItems.Count
      if ($n -eq 1) { $script:BackupInfo.Text = Get-BackupInfo $script:BackupList.SelectedItems[0].Tag }
      elseif ($n -gt 1) { $script:BackupInfo.Text = "$n backups selected." }
      else { $script:BackupInfo.Text = '' }
    }
    catch { $script:BackupInfo.Text = "Could not read this backup: $($_.Exception.Message)" }
  })

[void](New-Btn $TabBackup 'Back up now' $c1 ($y0 + 0 * $dy) $w 'Saves the current boot menu configuration right now, with an optional note. Manual backups are never removed automatically.' {
    $note = Read-Text 'Optional short note for this backup (e.g. before-bios-update). Leave empty for none:' 'Back up now' ''
    $reason = 'manual'; $s = ConvertTo-Slug $note; if ($s) { $reason = "manual-$s" }
    Backup-Bcd -Reason $reason -Force; Update-BackupList })
[void](New-Btn $TabBackup 'Restore selected...' $c1 ($y0 + 1 * $dy) $w 'Replaces the whole boot menu with the selected backup: entries, default and wait time. You see exactly what changes first, and the current state is saved automatically so the restore can be undone. VHDX files are not touched.' { Restore-BcdBackup })
[void](New-Btn $TabBackup 'Delete selected' $c1 ($y0 + 2 * $dy) $w 'Deletes the selected backup file(s). Only the backup is removed.' {
    $sel = Get-SelectedBackups
    if (-not (Confirm-Action "Delete $($sel.Count) backup file(s)?")) { return }
    foreach ($b in $sel) { Remove-Item -LiteralPath $b.Path -Force; Write-Log "Deleted backup $($b.Name)" }
    Update-BackupList })
[void](New-Btn $TabBackup 'Open backups folder' $c1 ($y0 + 3 * $dy) $w 'Opens <VHD folder>\bcd-backups in File Explorer.' { Start-Process explorer.exe (Get-BackupDir) })
[void](New-Btn $TabBackup 'Refresh' $c1 ($y0 + 4 * $dy) $w 'Re-reads the backup list.' { Update-BackupList })

[void](New-Lbl $TabBackup 'Keep newest automatic backups:' $c2 ($y0 + 8) 168)
$NumKeep = New-Object System.Windows.Forms.NumericUpDown
$NumKeep.Location = New-Object System.Drawing.Point($c2, ($y0 + 1 * $dy - 4)); $NumKeep.Size = New-Object System.Drawing.Size(80, 24)
$NumKeep.Minimum = 10; $NumKeep.Maximum = 1000; $NumKeep.Value = $script:KeepBackups
$NumKeep.Add_ValueChanged({ $script:KeepBackups = [int]$this.Value })
$TabBackup.Controls.Add($NumKeep); $script:NumKeep = $NumKeep
Add-Help $NumKeep 'Backups to keep' 'How many automatic backups to keep. Older automatic ones are deleted when a new one is made. Backups you create with "Back up now" are never deleted automatically. Each backup is only a few tens of KB.'
[void](New-Lbl $TabBackup "A backup is made automatically before every change this tool makes to the boot menu, and before every restore." $c2 ($y0 + 2 * $dy + 10) 168 100)

# ---- startup / shutdown ----
$running = $null
try { $running = Get-RunningVhd } catch {}
if ($running) { $TxtFolder.Text = Split-Path $running -Parent } else { $TxtFolder.Text = 'C:\VHD' }

# button columns on the Environments / Boot menu tabs stick to the right edge
foreach ($tp in $TabEnv, $TabBoot, $TabBackup) {
  foreach ($c in @($tp.Controls)) { if ($c -isnot [System.Windows.Forms.ListView] -and $c -isnot [System.Windows.Forms.TextBox]) { $c.Anchor = 'Top, Right' } }
}
Restore-WindowState

$Form.Add_Shown({
    Invoke-Action 'Loading' {
      Write-Log "VHDX Boot Manager started. Booted from: $(if ($running) { $running } else { 'physical disk' })"
      Update-All
      Invoke-SystemCheck
    }
  })
$Form.Add_FormClosing({ Save-WindowState; Dismount-Iso })

[void]$Form.ShowDialog()