# build.ps1 - build Logonoff on Windows WITHOUT MSYS2.
#
# Uses the toolchain shipped by the Amalgame Windows installer
# (amalgame-<ver>.msi with the bundled gcc: winlibs gcc + static libgc +
# OpenSSL). Same recipe as build.sh: packages precompiled offline from
# .\packages, amc transpiles, gcc links, dist\ is staged.
#
# Usage (PowerShell or cmd):
#   powershell -ExecutionPolicy Bypass -File build.ps1
# or double-click build.cmd.
#
# Overrides: $env:AMC (path to amc.exe), $env:GCC_BIN (folder holding gcc.exe).
# "Continue", not "Stop": Windows PowerShell 5.1 turns any stderr line of a
# native program (gcc, amc) into a terminating error. Failures are caught
# through $LASTEXITCODE and output checks instead.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

function Log($m)  { Write-Host "-> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "!  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "x  $m" -ForegroundColor Red; exit 1 }

# -- amc + its install prefix ---------------------------
$amc = $env:AMC
if (-not $amc) {
    $c = Get-Command amc -ErrorAction SilentlyContinue
    if ($c) { $amc = $c.Source }
}
if (-not $amc -or -not (Test-Path $amc)) { Die "amc.exe introuvable (PATH ou `$env:AMC)" }
$prefix = Split-Path (Split-Path $amc -Parent) -Parent
$runtime = Join-Path $prefix "share\amalgame\runtime"
$libamalgame = Join-Path $prefix "share\amalgame\lib\libamalgame.a"
if (-not (Test-Path $runtime))     { Die "runtime amc introuvable : $runtime" }
if (-not (Test-Path $libamalgame)) { Die "libamalgame.a introuvable : $libamalgame" }

# -- gcc: $env:GCC_BIN, then the one bundled with amc, then PATH --
$gccBin = $env:GCC_BIN
if (-not $gccBin) {
    foreach ($cand in @((Join-Path $prefix "gcc\bin"), (Join-Path (Split-Path $amc -Parent) "..\gcc\bin"))) {
        if (Test-Path (Join-Path $cand "gcc.exe")) { $gccBin = (Resolve-Path $cand).Path; break }
    }
}
if (-not $gccBin) {
    $g = Get-Command gcc -ErrorAction SilentlyContinue
    if ($g) { $gccBin = Split-Path $g.Source -Parent }
}
if (-not $gccBin) { Die "gcc introuvable : reinstallez Amalgame avec l'option "gcc integre", ou definissez `$env:GCC_BIN" }
# amc shells out to gcc for package precompiles: it must be on PATH.
$env:PATH = "$gccBin;$(Split-Path $amc -Parent);$env:PATH"
$gcc = Join-Path $gccBin "gcc.exe"
Log "amc : $amc"
Log "gcc : $gcc"

if (-not (Test-Path "packages")) { Die "dossier packages\ manquant" }
$env:AMALGAME_PACKAGES_DIR = (Resolve-Path "packages").Path
New-Item -ItemType Directory -Force build | Out-Null
$plat = "windows-x86_64"

# Fingerprint of a package's sources (manifest, .am, headers).
function Get-SourceHash($pkgDir) {
    $files = @(Get-ChildItem (Join-Path $pkgDir "*") -File -Include amalgame.toml, *.am, *.h -ErrorAction SilentlyContinue) +
             @(Get-ChildItem (Join-Path $pkgDir "runtime") -File -Filter *.h -ErrorAction SilentlyContinue)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $ms = New-Object System.IO.MemoryStream
    foreach ($f in ($files | Sort-Object FullName)) {
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        $ms.Write($b, 0, $b.Length)
    }
    $h = ($sha.ComputeHash($ms.ToArray()) | ForEach-Object { $_.ToString("x2") }) -join ""
    $sha.Dispose()
    return $h
}

# -- packages (offline, dependency order) ---------------
$pkgs = @("crypto@v0.8.0", "async@v0.4.1", "tls@v0.3.6", "net-http@v0.30.0", "threading@v0.1.0",
          "database-sqlite@v0.4.0", "datetime@v0.3.0", "service@v0.3.0", "formats-xlsx@v0.1.0")
Log "Paquets ($plat, hors ligne depuis .\packages)"
foreach ($p in $pkgs) {
    $name, $tag = $p.Split("@")
    $dir = Get-ChildItem "packages\github.com\amalgame-lang\amalgame-$name" -Directory -Filter "$($tag)_*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dir) { Die "packages\ ne contient pas amalgame-$name $tag" }
    $stamp = Join-Path $dir.FullName "build\$plat\.logonoff-precompiled"
    # The stamp holds a fingerprint of the package sources: when they
    # change (a re-vendored, modified package), it is precompiled again.
    $hash = Get-SourceHash $dir.FullName
    # An old stamp may be empty (Get-Content then returns $null).
    $previous = ""
    if (Test-Path $stamp) { $previous = ([string](Get-Content $stamp -Raw)).Trim() }
    if ($previous -eq $hash) { continue }
    Remove-Item -Recurse -Force (Join-Path $dir.FullName "build\$plat") -ErrorAction SilentlyContinue
    $log = "build\pkg-$name.log"
    & $amc package add "github.com/amalgame-lang/amalgame-$name@$tag" *> $log
    if ($LASTEXITCODE -ne 0) { Die "amc package add $name@$tag (voir $log)" }
    # No stamp on a failed facade, so the next build retries it.
    if (Select-String -Path $log -Pattern "FAILED" -Quiet) {
        Warn "$name : facade non precompilee (voir $log)"
    } else {
        New-Item -ItemType Directory -Force (Split-Path $stamp) | Out-Null
        Set-Content -Path $stamp -Value $hash -Encoding ascii
    }
    Write-Host "   precompile $name $tag"
}

# -- transpile (dependency order: cgen is single-pass) --
$sources = @("src\platform.am", "src\store.am", "src\timecalc.am", "src\tracker.am", "src\web.am", "src\main.am")
Log "Transpilation"
& $amc @sources -o "build\logonoff"
if (-not (Test-Path "build\logonoff.c")) { Die "amc n'a pas produit build\logonoff.c" }

# -- includes, archives, system libs from amalgame.lock --
$includes = New-Object System.Collections.Generic.List[string]
$archives = New-Object System.Collections.Generic.List[string]
$libs = New-Object System.Collections.Generic.List[string]
$lock = Get-Content "amalgame.lock" -Raw
foreach ($block in ($lock -split "\[\[package\]\]" | Select-Object -Skip 1)) {
    $git = ([regex]::Match($block, 'git\s*=\s*"([^"]+)"')).Groups[1].Value
    $tag = ([regex]::Match($block, 'tag\s*=\s*"([^"]+)"')).Groups[1].Value
    $rev = ([regex]::Match($block, 'rev\s*=\s*"([^"]+)"')).Groups[1].Value
    if (-not $git) { continue }
    $pkgDir = Join-Path $env:AMALGAME_PACKAGES_DIR (($git -replace "/", "\") + "\$($tag)_$rev")
    if (-not (Test-Path $pkgDir)) { Warn "paquet absent : $pkgDir"; continue }
    if (Test-Path "$pkgDir\runtime") { $includes.Add("-I$pkgDir\runtime") }
    $bdir = "$pkgDir\build\$plat"
    $a = @(Get-ChildItem $bdir -Filter *.a -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($a.Count -eq 0) { $a = @(Get-ChildItem $bdir -Filter *.o -ErrorAction SilentlyContinue | Sort-Object Name) }
    foreach ($f in $a) { $archives.Add($f.FullName) }
    $manifest = Get-Content "$pkgDir\amalgame.toml" -Raw
    $m = [regex]::Match($manifest, '(?m)^libs\s*=\s*\[([^\]]*)\]')
    if ($m.Success) {
        foreach ($l in [regex]::Matches($m.Groups[1].Value, '"([^"]+)"')) {
            $flag = "-l" + $l.Groups[1].Value
            if (-not $libs.Contains($flag)) { $libs.Add($flag) }
        }
    }
}
# nghttp2 is optional (net-http stubs HTTP/2 out without its headers).
$gccRoot = Split-Path $gccBin -Parent
$hasNghttp2 = (Test-Path "$gccRoot\include\nghttp2\nghttp2.h") -or (Test-Path "$gccRoot\x86_64-w64-mingw32\include\nghttp2\nghttp2.h")
if (-not $hasNghttp2) { [void]$libs.Remove("-lnghttp2") }

$extra = New-Object System.Collections.Generic.List[string]
$windres = Join-Path $gccBin "windres.exe"
if ((Test-Path $windres) -and (Test-Path "packaging\logonoff.rc")) {
    & $windres --include-dir packaging packaging\logonoff.rc -O coff -o build\logonoff-res.o
    if ($LASTEXITCODE -eq 0) { $extra.Add("build\logonoff-res.o") }
}

Log "Edition de liens -> logonoff.exe"
$linkArgs = @("-O2", "-pthread", "-w", "-I$runtime") + $includes + @("build\logonoff.c") + $extra +
        @("-Wl,--start-group") + $archives + @($libamalgame, "-Wl,--end-group", "-lgc", "-lm") + $libs +
        @("-lws2_32", "-lbcrypt", "-lshell32", "-luser32", "-ladvapi32", "-o", "build\logonoff.exe")
& $gcc @linkArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "build\logonoff.exe")) { Die "echec de gcc" }

# -- dist\ : exe, www, scripts, DLLs found next to gcc --
Log "Preparation de dist\"
if (Test-Path dist) { Remove-Item -Recurse -Force dist }
New-Item -ItemType Directory dist | Out-Null
Copy-Item build\logonoff.exe dist\
Copy-Item -Recurse www dist\www
Copy-Item packaging\install.cmd, packaging\uninstall.cmd dist\
# A service doesn't see the user's PATH: ship the toolchain DLLs the exe
# (and those DLLs) import.
$objdump = Join-Path $gccBin "objdump.exe"
$queue = New-Object System.Collections.Generic.Queue[string]
$queue.Enqueue("dist\logonoff.exe")
while ($queue.Count -gt 0) {
    $f = $queue.Dequeue()
    foreach ($line in (& $objdump -p $f 2>$null | Select-String "DLL Name:")) {
        $dll = ($line -replace ".*DLL Name:\s*", "").Trim()
        $src = Join-Path $gccBin $dll
        if ((Test-Path $src) -and -not (Test-Path "dist\$dll")) {
            Copy-Item $src dist\
            $queue.Enqueue("dist\$dll")
        }
    }
}
Write-Host "OK : dist\logonoff.exe" -ForegroundColor Green
