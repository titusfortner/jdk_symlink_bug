#Requires -Version 5.1
<#
.SYNOPSIS
  Minimal, self-contained reproduction of a JVM EXCEPTION_ACCESS_VIOLATION on
  Windows when the CDS archive (classes.jsa) is a symbolic link rather than a
  regular file.

.DESCRIPTION
  Class Data Sharing memory-maps the default archive at startup
  (Windows: <jdk>\bin\server\classes.jsa). When that file is a Windows symbolic
  link pointing at a byte-identical real archive -- nothing else changed -- the
  JVM crashes with an access violation inside jvm.dll during archive mapping.
  Replacing the symlink with the real file fixes it; -Xshare:off also avoids it
  because the archive is never mapped.

  This was first hit under Bazel on Windows, whose runfiles tree materializes the
  JDK as symlinks (classes.jsa becomes a link back to the external cache). This
  script removes Bazel from the picture and isolates the single variable
  (regular file vs symlink) two independent ways:

    Test A -- explicit archive via -XX:SharedArchiveFile=<symlink>
              (most surgical: same java.exe, one flag value changes)
    Test B -- default archive: copy the JDK, then replace ONLY
              bin\server\classes.jsa with a symlink and run plain `java -version`
              (exactly the field condition: default archive, default/auto mode)

  A run is classified CRASH only when an hs_err_pid*.log (a real access
  violation) is written -- NOT merely on a nonzero exit. A clean
  "-Xshare:on cannot map archive" abort is reported as ABORT and never mistaken
  for the bug. hs_err logs and minidumps are collected for the maintainer.

.PARAMETER Jdk
  JDK home to test. Defaults to $env:JAVA_HOME.

.PARAMETER OutDir
  Directory for the JDK copy, hs_err logs, minidumps and results.
  Use a path without spaces.

.EXAMPLE
  pwsh ./repro.ps1
  pwsh ./repro.ps1 -Jdk "C:\jdk-25" -OutDir "C:\cds-repro"

.NOTES
  Creating symlinks requires Windows Developer Mode (Settings > For developers)
  or an elevated shell. The script verifies each link really is a SymbolicLink
  and aborts loudly otherwise, so a silent copy can never masquerade as a repro.
#>
[CmdletBinding()]
param(
  [string]$Jdk    = $env:JAVA_HOME,
  [string]$OutDir = (Join-Path (Get-Location).Path "cds-symlink-artifacts")
)

$ErrorActionPreference = 'Stop'

function Write-Section($text) {
  Write-Host ""
  Write-Host ("=" * 78)
  Write-Host $text
  Write-Host ("=" * 78)
}

function Get-FileFacts($path) {
  $item = Get-Item -LiteralPath $path -Force
  $sha  = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
  [pscustomobject]@{
    Path     = $item.FullName
    Kind     = if ($item.LinkType) { $item.LinkType } else { 'regular file' }
    Target   = $item.Target
    Length   = $item.Length
    Sha256   = $sha
  }
}

function New-FileSymlink($linkPath, $targetPath) {
  if (Test-Path -LiteralPath $linkPath) { Remove-Item -LiteralPath $linkPath -Force }
  $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath -ErrorAction Stop
  $item = Get-Item -LiteralPath $linkPath -Force
  if ($item.LinkType -ne 'SymbolicLink') {
    throw "Expected a SymbolicLink at $linkPath but got '$($item.LinkType)'. " +
          "Enable Windows Developer Mode or run elevated so real symlinks can be created."
  }
}

# Run `java <args> -version`, classify the outcome, collect crash artifacts.
function Invoke-JavaProbe {
  param(
    [string]   $Tag,
    [string]   $JavaExe,
    [string[]] $ExtraArgs,
    [string]   $Expect   # 'OK' | 'CRASH' | 'OK-or-CRASH'
  )

  $errFile = Join-Path $OutDir ("hs_err_{0}_pid%p.log" -f $Tag)
  $stdout  = Join-Path $OutDir ("{0}.out.txt" -f $Tag)
  $stderr  = Join-Path $OutDir ("{0}.err.txt" -f $Tag)

  $javaArgs = @(
    "-XX:ErrorFile=$errFile"
    "-XX:+CreateCoredumpOnCrash"
  ) + $ExtraArgs + @('-version')

  $proc = Start-Process -FilePath $JavaExe -ArgumentList $javaArgs `
    -WorkingDirectory $OutDir -NoNewWindow -PassThru -Wait `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  $exit = $proc.ExitCode

  $hsErr = Get-ChildItem -LiteralPath $OutDir -Filter ("hs_err_{0}_pid*.log" -f $Tag) `
            -ErrorAction SilentlyContinue | Select-Object -First 1
  $isAv  = $false
  $frame = ''
  if ($hsErr) {
    $text = Get-Content -LiteralPath $hsErr.FullName -Raw
    $isAv = $text -match 'EXCEPTION_ACCESS_VIOLATION'
    if ($text -match '(?m)^#\s+(C\s+\[jvm\.dll.*)$') { $frame = $Matches[1].Trim() }
  }

  $result =
    if     ($hsErr -and $isAv) { 'CRASH' }
    elseif ($exit -eq 0)       { 'OK' }
    else                       { 'ABORT' }   # nonzero exit, no access violation

  $matchedExpectation =
    switch ($Expect) {
      'OK'          { $result -eq 'OK' }
      'CRASH'       { $result -eq 'CRASH' }
      'OK-or-CRASH' { $result -in 'OK','CRASH' }
    }

  [pscustomobject]@{
    Tag      = $Tag
    Command  = "java $($ExtraArgs -join ' ') -version"
    Exit     = $exit
    Result   = $result
    Frame    = $frame
    HsErr    = if ($hsErr) { $hsErr.Name } else { '' }
    Expect   = $Expect
    AsExpected = $matchedExpectation
  }
}

# ---------------------------------------------------------------------------
# 0. Validate inputs
# ---------------------------------------------------------------------------
if (-not $Jdk) { throw "No JDK: set JAVA_HOME or pass -Jdk." }
$Jdk = (Resolve-Path -LiteralPath $Jdk).Path
$realJava = Join-Path $Jdk 'bin\java.exe'
if (-not (Test-Path $realJava)) { throw "java.exe not found under $Jdk" }

$realJsa = Join-Path $Jdk 'bin\server\classes.jsa'
if (-not (Test-Path $realJsa)) {
  $found = Get-ChildItem -Path $Jdk -Recurse -Filter classes.jsa -ErrorAction SilentlyContinue |
           Select-Object -First 1
  if ($found) { $realJsa = $found.FullName }
}
if (-not (Test-Path $realJsa)) {
  throw "This JDK ships no default CDS archive (classes.jsa) -- nothing to symlink. " +
        "Use a JDK that ships a default archive, or run `java -Xshare:dump` first."
}

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $OutDir

Write-Section "Environment"
& $realJava -version 2>&1 | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "JDK home : $Jdk"
Write-Host "Archive  : $realJsa"
$realFacts = Get-FileFacts $realJsa
Write-Host ("           {0,-12} {1,14:N0} bytes  sha256={2}" -f $realFacts.Kind, $realFacts.Length, $realFacts.Sha256)

$results = @()

# ---------------------------------------------------------------------------
# Test A -- explicit archive via -XX:SharedArchiveFile (surgical: one flag value)
# ---------------------------------------------------------------------------
Write-Section "Test A -- explicit -XX:SharedArchiveFile: real file vs symlink"

$linkJsa = Join-Path $OutDir 'classes.symlink.jsa'
New-FileSymlink $linkJsa $realJsa
$linkFacts = Get-FileFacts $linkJsa
Write-Host "Real archive : $($realFacts.Path)"
Write-Host ("               {0,-12} {1,14:N0} bytes  sha256={2}" -f $realFacts.Kind, $realFacts.Length, $realFacts.Sha256)
Write-Host "Symlink      : $($linkFacts.Path)  ->  $($linkFacts.Target)"
Write-Host ("               {0,-12} {1,14:N0} bytes  sha256={2}" -f $linkFacts.Kind, $linkFacts.Length, $linkFacts.Sha256)
Write-Host ""
Write-Host "Same bytes through both paths (sha256 match: $($realFacts.Sha256 -eq $linkFacts.Sha256)); only the file *kind* differs."

$results += Invoke-JavaProbe -Tag 'A1-real-on'      -JavaExe $realJava -Expect 'OK' `
  -ExtraArgs @('-Xshare:on',   "-XX:SharedArchiveFile=$realJsa")
$results += Invoke-JavaProbe -Tag 'A2-symlink-auto' -JavaExe $realJava -Expect 'CRASH' `
  -ExtraArgs @('-Xshare:auto', "-XX:SharedArchiveFile=$linkJsa")
$results += Invoke-JavaProbe -Tag 'A3-symlink-on'   -JavaExe $realJava -Expect 'OK-or-CRASH' `
  -ExtraArgs @('-Xshare:on',   "-XX:SharedArchiveFile=$linkJsa")

# ---------------------------------------------------------------------------
# Test B -- default archive, the exact field condition (Bazel runfiles shape)
#   Copy the whole JDK (real files), replace ONLY bin\server\classes.jsa with a
#   symlink, then run plain `java -version` (default/auto sharing).
# ---------------------------------------------------------------------------
Write-Section "Test B -- default archive: copy JDK, symlink ONLY bin\server\classes.jsa"

$jdkCopy = Join-Path $OutDir 'jdk-copy'
Write-Host "Copying $Jdk -> $jdkCopy ..."
Copy-Item -Recurse -Force -LiteralPath $Jdk -Destination $jdkCopy
$copyJava = Join-Path $jdkCopy 'bin\java.exe'
$relJsa   = $realJsa.Substring($Jdk.Length).TrimStart('\')   # archive path relative to JDK home
$copyJsa  = Join-Path $jdkCopy $relJsa

# B-control: copy is identical to the original (real-file archive) -> must work.
$results += Invoke-JavaProbe -Tag 'B1-copy-real' -JavaExe $copyJava -Expect 'OK' -ExtraArgs @()

# Now flip the single variable: classes.jsa becomes a symlink to the real archive.
New-FileSymlink $copyJsa $realJsa
$copyJsaFacts = Get-FileFacts $copyJsa
Write-Host "classes.jsa in copy is now: $($copyJsaFacts.Kind)  ->  $($copyJsaFacts.Target)"

$results += Invoke-JavaProbe -Tag 'B2-symlink-default' -JavaExe $copyJava -Expect 'CRASH'       -ExtraArgs @()
$results += Invoke-JavaProbe -Tag 'B3-symlink-on'      -JavaExe $copyJava -Expect 'OK-or-CRASH' -ExtraArgs @('-Xshare:on')
$results += Invoke-JavaProbe -Tag 'B4-symlink-off'     -JavaExe $copyJava -Expect 'OK'          -ExtraArgs @('-Xshare:off')

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Section "Results"
$results |
  Format-Table -AutoSize @{L='Tag';E={$_.Tag}},
                         @{L='Command';E={$_.Command}},
                         @{L='Exit';E={$_.Exit}},
                         @{L='Result';E={$_.Result}},
                         @{L='Frame';E={$_.Frame}} |
  Out-String | Write-Host

# Reproduced == the symlink crashed with a real access violation while the
# byte-identical real file and the -Xshare:off workaround both ran cleanly.
$aCrash = ($results | Where-Object Tag -eq 'A2-symlink-auto').Result -eq 'CRASH'
$aReal  = ($results | Where-Object Tag -eq 'A1-real-on').Result      -eq 'OK'
$bCrash = ($results | Where-Object Tag -eq 'B2-symlink-default').Result -eq 'CRASH'
$bReal  = ($results | Where-Object Tag -eq 'B1-copy-real').Result       -eq 'OK'
$bOff   = ($results | Where-Object Tag -eq 'B4-symlink-off').Result     -eq 'OK'

$reproduced = ($aReal -and $aCrash) -or ($bReal -and $bCrash -and $bOff)
$verdict = if ($reproduced) {
  "REPRODUCED -- symlinked classes.jsa crashes the JVM (access violation); byte-identical real file and -Xshare:off both run cleanly."
} elseif (($results | Where-Object Result -eq 'CRASH')) {
  "PARTIAL -- a crash was observed but not in the clean single-variable shape; inspect the table and hs_err logs."
} else {
  "NOT reproduced on this JDK/OS -- no access violation observed."
}

Write-Host "VERDICT: $verdict"
Write-Host ""
Write-Host "JDK     : $($realFacts.Path)"
Write-Host "Artifacts (hs_err logs + minidumps + console output): $OutDir"
Get-ChildItem -LiteralPath $OutDir -Filter 'hs_err_*.log' -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host "  hs_err  : $($_.Name)" }
Get-ChildItem -LiteralPath $OutDir -Filter '*.mdmp' -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Host "  minidump: $($_.Name) ($($_.Length) bytes)" }

# Machine-readable result for CI / attaching to a bug.
$report = [pscustomobject]@{
  jdk        = $realFacts.Path
  archive    = $realFacts
  symlink    = $linkFacts
  reproduced = $reproduced
  verdict    = $verdict
  runs       = $results
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir 'results.json')

# Step summary when running under GitHub Actions.
if ($env:GITHUB_STEP_SUMMARY) {
  $lines = @("### $verdict", "", "JDK: ``$($realFacts.Path)``", "", "| Tag | Command | Exit | Result | Frame |", "|---|---|---|---|---|")
  foreach ($r in $results) { $lines += "| $($r.Tag) | ``$($r.Command)`` | $($r.Exit) | **$($r.Result)** | $($r.Frame) |" }
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
}
