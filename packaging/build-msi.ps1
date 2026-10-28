# build-msi.ps1 - Windows Installer package for Logonoff (no WiX).
#
# Same technique as Amalgame's install/windows/build-msi.ps1, whose COM
# plumbing (CallByName late binding, makecab cabinet, SummaryInformation
# through cscript) is reused here as-is:
#   - PowerShell + WindowsInstaller COM API + native makecab.exe only.
#
# What the package does:
#   - installs dist\ into %ProgramFiles%\Logonoff;
#   - stops and deletes any existing "Logonoff" service (the old C#
#     service, or one created by install.cmd), then installs the
#     service (LocalSystem, automatic start, "--service") and starts it
#     (restart-on-failure is set by the service itself at start-up);
#   - Start menu entry "Logonoff": an Internet shortcut to the web UI
#     (no program launched in the user's session: antivirus-friendly);
#   - major upgrade: a newer .msi replaces the installed one;
#   - uninstall stops and removes the service and the files.
#     C:\ProgramData\Logonoff (the database) is never touched.
#
# Usage (after build.cmd):
#   powershell -ExecutionPolicy Bypass -File packaging\build-msi.ps1
# Output: dist-msi\Logonoff-<version>.msi
#
# Silent install / uninstall (IT deployment):
#   msiexec /i Logonoff-<version>.msi /qn
#   msiexec /x Logonoff-<version>.msi /qn
#
# Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as
# ANSI, and the MSI database uses code page 1252 strings.

[CmdletBinding()]
param(
    [string] $Version     = "",
    [string] $StageDir    = "",
    [string] $OutputDir   = "",
    [string] $IconPath    = "",
    [string] $ManufacturerName = "Bastien MOUGET",
    [string] $ProductName      = "Logonoff",
    # Never change: it ties every version together for upgrades.
    [string] $UpgradeCode      = "{7B2E4C1A-5D3F-4E8B-9A6C-2F1D0E9B8A47}"
)

$ErrorActionPreference = "Stop"
trap {
    Write-Host ""
    Write-Host "build-msi.ps1 - ERROR" -ForegroundColor Red
    Write-Host "Message : $($_.Exception.Message)"
    if ($_.InvocationInfo) { Write-Host "Line    : $($_.InvocationInfo.ScriptLineNumber)  $($_.InvocationInfo.Line.Trim())" }
    $ex = $_.Exception.InnerException
    while ($ex) { Write-Host "  inner : $($ex.GetType().FullName): $($ex.Message)"; $ex = $ex.InnerException }
    exit 1
}

$ScriptRoot = Split-Path -Parent $PSCommandPath
$ProjectRoot = Split-Path -Parent $ScriptRoot
if (-not $StageDir)  { $StageDir  = Join-Path $ProjectRoot "dist" }
if (-not $OutputDir) { $OutputDir = Join-Path $ProjectRoot "dist-msi" }
if (-not $IconPath)  { $IconPath  = Join-Path $ScriptRoot "logonoff.ico" }

# MSI ProductVersion is major.minor.build (build <= 65535). The build
# number counts hours since 2026-01-01, so every rebuild is "newer" and
# upgrades the installed one (good for ~7 years).
if (-not $Version) {
    $hours = [int][Math]::Floor(((Get-Date) - [datetime]"2026-01-01").TotalHours)
    $Version = "0.1.$hours"
}

if (-not (Test-Path (Join-Path $StageDir "logonoff.exe"))) {
    throw "logonoff.exe not found in $StageDir - run build.cmd first (and check the antivirus did not quarantine it)"
}
$StageDir = (Resolve-Path $StageDir).Path
$AbsIcon = (Resolve-Path $IconPath).Path

$OutAbs = $OutputDir
$null = New-Item -ItemType Directory -Path $OutAbs -Force
$OutAbs = (Resolve-Path $OutAbs).Path
$MsiFinalPath = Join-Path $OutAbs "Logonoff-$Version.msi"
$stamp = (Get-Date -Format "yyyyMMddHHmmss") + "-" + $PID
$MsiPath = Join-Path $OutAbs "Logonoff-$Version.staging-$stamp.msi"
$CabPath = Join-Path $OutAbs "logonoff.cab"
$WorkDir = Join-Path $OutAbs "work"
$null = New-Item -ItemType Directory -Path $WorkDir -Force
if (Test-Path $CabPath) { Remove-Item $CabPath -Force }
Get-ChildItem -Path $OutAbs -Filter "Logonoff-*.staging-*.msi" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

Write-Host "-- build-msi.ps1 -----------------------------------"
Write-Host "  Product : $ProductName $Version"
Write-Host "  Stage   : $StageDir"
Write-Host ""

# ===================================================================
# Stage 1 - files
# ===================================================================

class StagedFile {
    [string] $SourcePath
    [string] $InstallDirId
    [string] $DestName
    [string] $FileKey
    [string] $ComponentId
    [string] $ComponentGuid
    [long]   $Size
}

function New-DeterministicGuid {
    param([string]$Seed)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $bytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Seed))
    $first16 = [byte[]]($bytes[0..15])
    $guid = [Guid]::new($first16)
    $sha1.Dispose()
    return "{$($guid.ToString().ToUpper())}"
}

function Get-DirectoryId {
    param([string]$RelPath)
    if ([string]::IsNullOrEmpty($RelPath)) { return "INSTALLLOCATION" }
    return "D_" + ($RelPath -replace "[\\/]", "_" -replace "[^A-Za-z0-9_]", "_")
}

$staged = [System.Collections.Generic.List[StagedFile]]::new()
$dirIds = [System.Collections.Generic.HashSet[string]]::new()
$dirIds.Add("INSTALLLOCATION") | Out-Null
$dirParents = @{ "INSTALLLOCATION" = "ProgramFiles64Folder" }
$dirNames   = @{ "INSTALLLOCATION" = "Logonoff" }

function Register-Directory {
    param([string]$RelPath)
    if ([string]::IsNullOrEmpty($RelPath)) { return "INSTALLLOCATION" }
    $segments = $RelPath -split "[\\/]"
    $accum = @()
    $parentId = "INSTALLLOCATION"
    foreach ($seg in $segments) {
        $accum += $seg
        $id = Get-DirectoryId ($accum -join "/")
        if (-not $dirIds.Contains($id)) {
            $dirIds.Add($id) | Out-Null
            $dirParents[$id] = $parentId
            $dirNames[$id] = $seg
        }
        $parentId = $id
    }
    return $parentId
}

$script:stagedCounter = 0
# Install scripts are for the manual route only; the MSI replaces them.
$skip = @("install.cmd", "uninstall.cmd")
foreach ($file in Get-ChildItem -Path $StageDir -Recurse -File) {
    if ($skip -contains $file.Name) { continue }
    $rel = $file.FullName.Substring($StageDir.Length).TrimStart("\", "/").Replace("\", "/")
    $relDir = Split-Path $rel -Parent
    if ($null -eq $relDir) { $relDir = "" }
    $relDir = $relDir.Replace("\", "/")
    $script:stagedCounter += 1
    $idx = $script:stagedCounter
    $sf = [StagedFile]::new()
    $sf.SourcePath    = $file.FullName
    $sf.InstallDirId  = Register-Directory -RelPath $relDir
    $sf.DestName      = $file.Name
    $sf.FileKey       = "F{0:D5}" -f $idx
    $sf.ComponentId   = "C{0:D5}" -f $idx
    $sf.ComponentGuid = New-DeterministicGuid "$UpgradeCode|$relDir/$($file.Name)"
    $sf.Size          = $file.Length
    $staged.Add($sf)
}
$exe = $staged | Where-Object { $_.DestName -eq "logonoff.exe" -and $_.InstallDirId -eq "INSTALLLOCATION" } | Select-Object -First 1
if (-not $exe) { throw "logonoff.exe not staged" }
Write-Host "  $($staged.Count) files, $($dirIds.Count) directories"

# ===================================================================
# Stage 2 - cabinet (makecab, native on every Windows)
# ===================================================================

$ddfPath = Join-Path $WorkDir "logonoff.ddf"
$ddf = [System.Collections.Generic.List[string]]::new()
$ddf.Add(".OPTION EXPLICIT")
$ddf.Add(".Set CabinetNameTemplate=`"logonoff.cab`"")
$ddf.Add(".Set DiskDirectory1=`"$OutAbs`"")
$ddf.Add(".Set DiskDirectoryTemplate=`"$OutAbs`"")
$ddf.Add(".Set CompressionType=MSZIP")
$ddf.Add(".Set Cabinet=ON")
$ddf.Add(".Set Compress=ON")
$ddf.Add(".Set MaxDiskSize=0")
$ddf.Add(".Set ReservePerCabinetSize=8")
foreach ($sf in $staged) { $ddf.Add("`"$($sf.SourcePath)`" $($sf.FileKey)") }
Set-Content -Path $ddfPath -Value $ddf -Encoding ASCII
$mkOut = & makecab.exe /f $ddfPath /L $WorkDir 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host $mkOut; throw "makecab exited $LASTEXITCODE" }
if (-not (Test-Path $CabPath)) { throw "cabinet not produced: $CabPath" }
Write-Host "  cabinet : $((Get-Item $CabPath).Length) bytes"

# ===================================================================
# Stage 3 - MSI database (WindowsInstaller COM, late-bound)
# ===================================================================

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($MsiPath, 3)

$vbLoaded = $false
foreach ($asmName in @("Microsoft.VisualBasic.Core", "Microsoft.VisualBasic")) {
    try { Add-Type -AssemblyName $asmName -ErrorAction Stop; $vbLoaded = $true; break } catch { }
}
if (-not $vbLoaded) { throw "Microsoft.VisualBasic not loadable (needed for COM late binding)" }

function Invoke-MSI {
    param([object]$Target, [string]$Method, [object[]]$MethodArgs = @())
    $iact = [Microsoft.VisualBasic.Interaction]
    $cType = [Microsoft.VisualBasic.CallType]::Method
    switch ($MethodArgs.Count) {
        0 { return $iact::CallByName($Target, $Method, $cType) }
        1 { return $iact::CallByName($Target, $Method, $cType, $MethodArgs[0]) }
        2 { return $iact::CallByName($Target, $Method, $cType, $MethodArgs[0], $MethodArgs[1]) }
        3 { return $iact::CallByName($Target, $Method, $cType, $MethodArgs[0], $MethodArgs[1], $MethodArgs[2]) }
    }
    throw "Invoke-MSI: too many args"
}

function Set-MsiProperty {
    param([object]$Target, [string]$Property, [object[]]$IndexAndValue)
    [void][Microsoft.VisualBasic.Interaction]::CallByName($Target, $Property,
        [Microsoft.VisualBasic.CallType]::Let, $IndexAndValue[0], $IndexAndValue[1])
}

function Insert-Row {
    param([string]$Table, [string[]]$Columns, [object[]]$Values)
    $cols = ($Columns | ForEach-Object { "``$_``" }) -join ", "
    $marks = (@("?") * $Columns.Count) -join ", "
    $view = Invoke-MSI $database "OpenView" @("INSERT INTO ``$Table`` ($cols) VALUES ($marks)")
    $record = Invoke-MSI $installer "CreateRecord" @($Values.Count)
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $v = $Values[$i]
        if ($null -eq $v) { continue }
        [int]$f = $i + 1
        if ($v -is [int] -or $v -is [long]) { Set-MsiProperty $record "IntegerData" @($f, [int]$v) }
        else { Set-MsiProperty $record "StringData" @($f, [string]$v) }
    }
    Invoke-MSI $view "Execute" @($record)
    Invoke-MSI $view "Close" @()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($record)
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
}

function Exec-Sql {
    param([string]$Sql)
    $view = Invoke-MSI $database "OpenView" @($Sql)
    Invoke-MSI $view "Execute" @($null)
    Invoke-MSI $view "Close" @()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
}

$schemas = @(
    "CREATE TABLE ``Property`` (``Property`` CHAR(72) NOT NULL, ``Value`` LONGCHAR NOT NULL LOCALIZABLE PRIMARY KEY ``Property``)",
    "CREATE TABLE ``Directory`` (``Directory`` CHAR(72) NOT NULL, ``Directory_Parent`` CHAR(72), ``DefaultDir`` CHAR(255) NOT NULL LOCALIZABLE PRIMARY KEY ``Directory``)",
    "CREATE TABLE ``Component`` (``Component`` CHAR(72) NOT NULL, ``ComponentId`` CHAR(38), ``Directory_`` CHAR(72) NOT NULL, ``Attributes`` SHORT NOT NULL, ``Condition`` CHAR(255), ``KeyPath`` CHAR(72) PRIMARY KEY ``Component``)",
    "CREATE TABLE ``Feature`` (``Feature`` CHAR(38) NOT NULL, ``Feature_Parent`` CHAR(38), ``Title`` CHAR(64) LOCALIZABLE, ``Description`` CHAR(255) LOCALIZABLE, ``Display`` SHORT, ``Level`` SHORT NOT NULL, ``Directory_`` CHAR(72), ``Attributes`` SHORT NOT NULL PRIMARY KEY ``Feature``)",
    "CREATE TABLE ``FeatureComponents`` (``Feature_`` CHAR(38) NOT NULL, ``Component_`` CHAR(72) NOT NULL PRIMARY KEY ``Feature_``, ``Component_``)",
    "CREATE TABLE ``File`` (``File`` CHAR(72) NOT NULL, ``Component_`` CHAR(72) NOT NULL, ``FileName`` CHAR(255) NOT NULL LOCALIZABLE, ``FileSize`` LONG NOT NULL, ``Version`` CHAR(72), ``Language`` CHAR(20), ``Attributes`` SHORT, ``Sequence`` SHORT NOT NULL PRIMARY KEY ``File``)",
    "CREATE TABLE ``Media`` (``DiskId`` SHORT NOT NULL, ``LastSequence`` SHORT NOT NULL, ``DiskPrompt`` CHAR(64) LOCALIZABLE, ``Cabinet`` CHAR(255), ``VolumeLabel`` CHAR(32), ``Source`` CHAR(72) PRIMARY KEY ``DiskId``)",
    "CREATE TABLE ``InstallExecuteSequence`` (``Action`` CHAR(72) NOT NULL, ``Condition`` CHAR(255), ``Sequence`` SHORT PRIMARY KEY ``Action``)",
    "CREATE TABLE ``InstallUISequence`` (``Action`` CHAR(72) NOT NULL, ``Condition`` CHAR(255), ``Sequence`` SHORT PRIMARY KEY ``Action``)",
    "CREATE TABLE ``Shortcut`` (``Shortcut`` CHAR(72) NOT NULL, ``Directory_`` CHAR(72) NOT NULL, ``Name`` CHAR(128) NOT NULL LOCALIZABLE, ``Component_`` CHAR(72) NOT NULL, ``Target`` CHAR(72) NOT NULL, ``Arguments`` CHAR(255), ``Description`` CHAR(255) LOCALIZABLE, ``Hotkey`` SHORT, ``Icon_`` CHAR(72), ``IconIndex`` SHORT, ``ShowCmd`` SHORT, ``WkDir`` CHAR(72) PRIMARY KEY ``Shortcut``)",
    "CREATE TABLE ``Icon`` (``Name`` CHAR(72) NOT NULL, ``Data`` OBJECT NOT NULL PRIMARY KEY ``Name``)",
    "CREATE TABLE ``Upgrade`` (``UpgradeCode`` CHAR(38) NOT NULL, ``VersionMin`` CHAR(20), ``VersionMax`` CHAR(20), ``Language`` CHAR(255), ``Attributes`` LONG NOT NULL, ``Remove`` CHAR(255), ``ActionProperty`` CHAR(72) NOT NULL PRIMARY KEY ``UpgradeCode``, ``VersionMin``, ``VersionMax``, ``Language``, ``Attributes``)",
    "CREATE TABLE ``IniFile`` (``IniFile`` CHAR(72) NOT NULL, ``FileName`` CHAR(255) NOT NULL LOCALIZABLE, ``DirProperty`` CHAR(72), ``Section`` CHAR(96) NOT NULL LOCALIZABLE, ``Key`` CHAR(128) NOT NULL LOCALIZABLE, ``Value`` CHAR(255) NOT NULL LOCALIZABLE, ``Action`` SHORT NOT NULL, ``Component_`` CHAR(72) NOT NULL PRIMARY KEY ``IniFile``)",
    "CREATE TABLE ``ServiceInstall`` (``ServiceInstall`` CHAR(72) NOT NULL, ``Name`` CHAR(255) NOT NULL, ``DisplayName`` CHAR(255) LOCALIZABLE, ``ServiceType`` LONG NOT NULL, ``StartType`` LONG NOT NULL, ``ErrorControl`` LONG NOT NULL, ``LoadOrderGroup`` CHAR(255), ``Dependencies`` CHAR(255), ``StartName`` CHAR(255), ``Password`` CHAR(255), ``Arguments`` CHAR(255), ``Component_`` CHAR(72) NOT NULL, ``Description`` CHAR(255) LOCALIZABLE PRIMARY KEY ``ServiceInstall``)",
    "CREATE TABLE ``ServiceControl`` (``ServiceControl`` CHAR(72) NOT NULL, ``Name`` CHAR(255) NOT NULL LOCALIZABLE, ``Event`` SHORT NOT NULL, ``Arguments`` CHAR(255) LOCALIZABLE, ``Wait`` SHORT, ``Component_`` CHAR(72) NOT NULL PRIMARY KEY ``ServiceControl``)"
)
foreach ($ddl in $schemas) { Exec-Sql $ddl }

# -- Properties ------------------------------------------------------
$properties = [ordered]@{
    "ProductCode"            = (New-DeterministicGuid "$UpgradeCode|$Version")
    "ProductName"            = $ProductName
    "ProductVersion"         = $Version
    "Manufacturer"           = $ManufacturerName
    "ProductLanguage"        = "1036"
    "UpgradeCode"            = $UpgradeCode
    "ALLUSERS"               = "1"
    "ARPPRODUCTICON"         = "logonoff.ico"
    "ARPURLINFOABOUT"        = "http://127.0.0.1:8765/"
    "ARPCOMMENTS"            = "Temps de presence et temps par projet (service + interface web locale)"
    "ARPNOMODIFY"            = "1"
    "ARPNOREPAIR"            = "1"
    "INSTALLLEVEL"           = "1"
    # Overwrite every file on upgrade, whatever its version or date
    # (unversioned www\ files would otherwise be kept if modified).
    "REINSTALLMODE"          = "amus"
    "SecureCustomProperties" = "OLDLOGONOFFFOUND;NEWERLOGONOFFFOUND"
}
foreach ($k in $properties.Keys) { Insert-Row "Property" @("Property", "Value") @($k, $properties[$k]) }

# -- Major upgrade ----------------------------------------------------
# Attributes: 256 = VersionMinInclusive; 2 = OnlyDetect (newer: block).
Insert-Row "Upgrade" @("UpgradeCode", "VersionMin", "VersionMax", "Language", "Attributes", "Remove", "ActionProperty") @(
    $UpgradeCode, "0.0.0", $Version, $null, [int]256, $null, "OLDLOGONOFFFOUND")
Insert-Row "Upgrade" @("UpgradeCode", "VersionMin", "VersionMax", "Language", "Attributes", "Remove", "ActionProperty") @(
    $UpgradeCode, $Version, $null, $null, [int]2, $null, "NEWERLOGONOFFFOUND")

# -- Directories ------------------------------------------------------
Insert-Row "Directory" @("Directory", "Directory_Parent", "DefaultDir") @("TARGETDIR", $null, "SourceDir")
Insert-Row "Directory" @("Directory", "Directory_Parent", "DefaultDir") @("ProgramFiles64Folder", "TARGETDIR", ".")
Insert-Row "Directory" @("Directory", "Directory_Parent", "DefaultDir") @("ProgramMenuFolder", "TARGETDIR", ".")
$emitted = @{ "TARGETDIR" = $true; "ProgramFiles64Folder" = $true; "ProgramMenuFolder" = $true }
$pending = @($dirIds | Where-Object { -not $emitted.ContainsKey($_) })
while ($pending.Count -gt 0) {
    $progress = $false
    foreach ($id in @($pending)) {
        if ($emitted.ContainsKey($dirParents[$id])) {
            Insert-Row "Directory" @("Directory", "Directory_Parent", "DefaultDir") @($id, $dirParents[$id], $dirNames[$id])
            $emitted[$id] = $true
            $progress = $true
        }
    }
    if (-not $progress) { throw "directory tree has an orphan: $($pending -join ',')" }
    $pending = @($dirIds | Where-Object { -not $emitted.ContainsKey($_) })
}

# -- Components / files -------------------------------------------------
$attr64 = 256
$sequence = 0
foreach ($sf in $staged) {
    $sequence += 1
    Insert-Row "Component" @("Component", "ComponentId", "Directory_", "Attributes", "Condition", "KeyPath") @(
        $sf.ComponentId, $sf.ComponentGuid, $sf.InstallDirId, [int]$attr64, $null, $sf.FileKey)
    Insert-Row "File" @("File", "Component_", "FileName", "FileSize", "Version", "Language", "Attributes", "Sequence") @(
        $sf.FileKey, $sf.ComponentId, $sf.DestName, [int]$sf.Size, $null, $null, [int]512, [int]$sequence)
    Insert-Row "FeatureComponents" @("Feature_", "Component_") @("Complete", $sf.ComponentId)
}
Insert-Row "Feature" @("Feature", "Feature_Parent", "Title", "Description", "Display", "Level", "Directory_", "Attributes") @(
    "Complete", $null, "Logonoff", "Service et interface", [int]0, [int]1, "INSTALLLOCATION", [int]0)
Insert-Row "Media" @("DiskId", "LastSequence", "DiskPrompt", "Cabinet", "VolumeLabel", "Source") @(
    [int]1, [int]$sequence, $null, "#logonoff.cab", $null, $null)

# -- Service ------------------------------------------------------------
# ServiceType 16 = own process; StartType 2 = automatic; ErrorControl 1.
# StartName NULL = LocalSystem (needed for session tokens).
Insert-Row "ServiceInstall" @("ServiceInstall", "Name", "DisplayName", "ServiceType", "StartType", "ErrorControl", "LoadOrderGroup", "Dependencies", "StartName", "Password", "Arguments", "Component_", "Description") @(
    "SvcLogonoff", "Logonoff", "Logonoff", [int]16, [int]2, [int]1, $null, $null, $null, $null, "--service", $exe.ComponentId,
    "Temps de presence (sessions Windows) et temps par projet. Interface : http://127.0.0.1:8765")
# Event bits: 1 start on install, 2 stop on install, 8 delete on install
# (removes a pre-existing "Logonoff" service: old C# one or install.cmd),
# 32 stop on uninstall, 128 delete on uninstall.
Insert-Row "ServiceControl" @("ServiceControl", "Name", "Event", "Arguments", "Wait", "Component_") @(
    "SvcCtlLogonoff", "Logonoff", [int](1 + 2 + 8 + 32 + 128), $null, [int]1, $exe.ComponentId)
# Restart-on-failure is NOT set here: the MsiServiceConfigFailureActions
# table + MsiConfigureServices failed with error 1939 on a real install
# and rolled everything back. The service configures it for itself at
# start-up (Service.SetRestartOnFailure).

# -- Icon + Start menu shortcut ----------------------------------------
$iconView = Invoke-MSI $database "OpenView" @("INSERT INTO ``Icon`` (``Name``, ``Data``) VALUES (?, ?)")
$iconRecord = Invoke-MSI $installer "CreateRecord" @(2)
Set-MsiProperty $iconRecord "StringData" @(1, "logonoff.ico")
Invoke-MSI $iconRecord "SetStream" @(2, $AbsIcon)
Invoke-MSI $iconView "Execute" @($iconRecord)
Invoke-MSI $iconView "Close" @()
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($iconRecord)
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($iconView)
# Start menu entry = an Internet shortcut (Logonoff.url) to the web UI,
# not a shortcut to logonoff.exe: antivirus products (Trend Apex One)
# block an unknown program launched in the user's session, while the
# browser is trusted. Written through the IniFile table.
$ini = @(
    @("Ini_Url",       "URL",       "http://127.0.0.1:8765/"),
    @("Ini_IconFile",  "IconFile",  "[INSTALLLOCATION]logonoff.ico"),
    @("Ini_IconIndex", "IconIndex", "0")
)
foreach ($r in $ini) {
    Insert-Row "IniFile" @("IniFile", "FileName", "DirProperty", "Section", "Key", "Value", "Action", "Component_") @(
        $r[0], "Logonoff.url", "ProgramMenuFolder", "InternetShortcut", $r[1], $r[2], [int]0, $exe.ComponentId)
}

# -- Sequences ------------------------------------------------------------
# RemoveExistingProducts right after InstallValidate: the old version
# (and its service) is removed before the new one is laid down.
$execSeq = @(
    @("FindRelatedProducts",     $null, 25),
    @("LaunchConditions",        $null, 100),
    @("ValidateProductID",       $null, 700),
    @("CostInitialize",          $null, 800),
    @("FileCost",                $null, 900),
    @("CostFinalize",            $null, 1000),
    @("InstallValidate",         $null, 1400),
    @("RemoveExistingProducts",  $null, 1450),
    @("InstallInitialize",       $null, 1500),
    @("ProcessComponents",       $null, 1600),
    @("UnpublishFeatures",       $null, 1800),
    @("StopServices",            $null, 1900),
    @("DeleteServices",          $null, 2000),
    @("RemoveShortcuts",         $null, 3200),
    @("RemoveIniValues",         $null, 3300),
    @("RemoveFiles",             $null, 3500),
    @("InstallFiles",            $null, 4000),
    @("CreateShortcuts",         $null, 4500),
    @("WriteIniValues",          $null, 5100),
    @("InstallServices",         $null, 5800),
    @("StartServices",           $null, 5900),
    @("RegisterUser",            $null, 6000),
    @("RegisterProduct",         $null, 6100),
    @("PublishFeatures",         $null, 6300),
    @("PublishProduct",          $null, 6400),
    @("InstallFinalize",         $null, 6600)
)
foreach ($a in $execSeq) { Insert-Row "InstallExecuteSequence" @("Action", "Condition", "Sequence") @($a[0], $a[1], [int]$a[2]) }
$uiSeq = @(
    @("FindRelatedProducts", $null, 25),
    @("LaunchConditions",    $null, 100),
    @("ValidateProductID",   $null, 700),
    @("CostInitialize",      $null, 800),
    @("FileCost",            $null, 900),
    @("CostFinalize",        $null, 1000),
    @("ExecuteAction",       $null, 1300)
)
foreach ($a in $uiSeq) { Insert-Row "InstallUISequence" @("Action", "Condition", "Sequence") @($a[0], $a[1], [int]$a[2]) }

# -- Embedded cabinet --------------------------------------------------
$streamView = Invoke-MSI $database "OpenView" @("INSERT INTO ``_Streams`` (``Name``, ``Data``) VALUES (?, ?)")
$streamRecord = Invoke-MSI $installer "CreateRecord" @(2)
Set-MsiProperty $streamRecord "StringData" @(1, "logonoff.cab")
Invoke-MSI $streamRecord "SetStream" @(2, $CabPath)
Invoke-MSI $streamView "Execute" @($streamRecord)
Invoke-MSI $streamView "Close" @()
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($streamRecord)
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($streamView)

Invoke-MSI $database "Commit" @()
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database)
$database = $null
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
$installer = $null
[System.GC]::Collect()
[System.GC]::WaitForPendingFinalizers()
[System.GC]::Collect()
Start-Sleep -Milliseconds 200

# -- SummaryInformation (through cscript: PowerShell's COM adapter
#    mishandles SummaryInfo.Property on some hosts) -------------------
$rev = [Guid]::NewGuid().ToString("B").ToUpper()
$vbs = @"
Option Explicit
Dim installer, db, si, attempt, lastErr
Set installer = CreateObject("WindowsInstaller.Installer")
attempt = 0
Do
    attempt = attempt + 1
    On Error Resume Next
    Set db = installer.OpenDatabase(WScript.Arguments(0), 1)
    lastErr = Err.Number
    On Error Goto 0
    If lastErr = 0 Then Exit Do
    If attempt >= 20 Then
        WScript.StdErr.WriteLine "[vbs] OpenDatabase failed (err=" & lastErr & ")"
        WScript.Quit 2
    End If
    WScript.Sleep 500
Loop
Set si = db.SummaryInformation(200)
si.Property(1)  = CLng(1252)
si.Property(2)  = "$ProductName Installer"
si.Property(3)  = "$ProductName $Version"
si.Property(4)  = "$ManufacturerName"
si.Property(5)  = "logonoff;temps;presence"
si.Property(6)  = "Logonoff - temps de presence et temps par projet"
si.Property(7)  = "x64;1036"
si.Property(9)  = "$rev"
si.Property(14) = CLng(200)
si.Property(15) = CLng(2)
si.Persist
db.Commit
WScript.Echo "[vbs] SummaryInformation written"
"@
$vbsPath = Join-Path $env:TEMP "logonoff-msi-si.vbs"
Set-Content -Path $vbsPath -Value $vbs -Encoding ASCII
& cscript.exe //nologo //T:30 $vbsPath $MsiPath
if ($LASTEXITCODE -ne 0) { throw "cscript exited $LASTEXITCODE - SummaryInformation not written" }
Remove-Item -Path $vbsPath -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
Remove-Item -Force $CabPath -ErrorAction SilentlyContinue
for ($try = 1; $try -le 20; $try++) {
    try {
        if (Test-Path $MsiFinalPath) { Remove-Item $MsiFinalPath -Force -ErrorAction Stop }
        Move-Item -Path $MsiPath -Destination $MsiFinalPath -Force -ErrorAction Stop
        break
    } catch {
        if ($try -eq 20) { $MsiFinalPath = $MsiPath; break }
        [System.GC]::Collect()
        Start-Sleep -Milliseconds 500
    }
}

Write-Host ""
Write-Host "OK : $MsiFinalPath ($((Get-Item $MsiFinalPath).Length) bytes)" -ForegroundColor Green
Write-Host "Installer : double-clic, ou  msiexec /i `"$MsiFinalPath`" /l*v install.log"
