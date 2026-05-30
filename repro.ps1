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

  If the minimal Test B does not crash on its own, Tests C/D/E add the two ways
  Bazel's runfiles tree differs from a plain copy, one variable at a time, to
  pin down the root cause:

    Test C -- DEPTH: the same real-file copy but launched from a deep (~200
              char) path, like Bazel's runfiles location near MAX_PATH.
    Test D -- TREE: a full per-file symlink mirror of the JDK at a short path,
              so java.exe/jvm.dll/classes.jsa are ALL symlinks (Bazel's shape).
    Test E -- DEPTH + TREE: the full symlink mirror at a deep path -- the
              faithful standalone reproduction of Bazel's runfiles JDK.

  The Attribution block then reports which ingredient (depth, the symlink tree,
  or only their combination) flips a working JDK into a crashing one.

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

# Create a directory whose full path is at least $TargetLen characters by
# nesting short segments under $Base. Used to launch java from a deep path like
# Bazel's runfiles tree (~200 chars), to test the path-depth hypothesis.
function New-DeepDir($Base, $TargetLen) {
  $p = $Base
  $guard = 0
  while ($p.Length -lt $TargetLen -and $guard -lt 400) {
    $p = Join-Path $p 'd'
    $guard++
  }
  $null = New-Item -ItemType Directory -Force -Path $p -ErrorAction Stop
  return $p
}

# Mirror an entire JDK as Bazel's runfiles tree does: recreate the directory
# structure with real directories, but make every *file* a symbolic link back to
# the corresponding real file under $Src (absolute target, like Bazel's links
# into the external cache). So java.exe, jvm.dll AND classes.jsa all become
# symlinks. Files whose mirrored path would exceed Windows' 260-char limit are
# skipped (deep legal/doc files the JVM never reads at startup).
function New-SymlinkTree($Src, $Dst) {
  $created = 0; $skipped = 0
  $null = New-Item -ItemType Directory -Force -Path $Dst -ErrorAction Stop
  Get-ChildItem -LiteralPath $Src -Recurse -Force | ForEach-Object {
    $rel      = $_.FullName.Substring($Src.Length).TrimStart('\')
    $linkPath = Join-Path $Dst $rel
    try {
      if ($_.PSIsContainer) {
        $null = New-Item -ItemType Directory -Force -Path $linkPath -ErrorAction Stop
      } else {
        $parent = Split-Path $linkPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
          $null = New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop
        }
        $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $_.FullName -ErrorAction Stop
        $created++
      }
    } catch { $skipped++ }
  }
  [pscustomobject]@{ Created = $created; Skipped = $skipped }
}

# robocopy is long-path aware, so it can copy a JDK into a deep (>260 internal)
# destination that Copy-Item would choke on (and is fine for short dests too).
# Exit codes 0-7 mean success.
function Copy-Jdk($Src, $Dst) {
  $p = Start-Process robocopy `
    -ArgumentList @("`"$Src`"", "`"$Dst`"", '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1') `
    -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ge 8) { throw "robocopy failed copying $Src -> $Dst (exit $($p.ExitCode))" }
}

# Replace every file under <copy>\<SubRel> with a symlink to the corresponding
# real file under $Jdk (e.g. symlink all of bin\ or all of lib\). Returns the
# number of files linked.
function New-SubtreeSymlinks($CopyRoot, $SubRel) {
  $n = 0
  Get-ChildItem -LiteralPath (Join-Path $Jdk $SubRel) -Recurse -Force -File | ForEach-Object {
    $rel = $_.FullName.Substring($Jdk.Length).TrimStart('\')
    try { New-FileSymlink (Join-Path $CopyRoot $rel) $_.FullName; $n++ } catch {}
  }
  $n
}

# Copy the real file back over a symlink, so a shared copy can be reused to test
# one component at a time.
function Restore-RealFile($CopyRoot, $Rel) {
  $dst = Join-Path $CopyRoot $Rel
  if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
  Copy-Item -LiteralPath (Join-Path $Jdk $Rel) -Destination $dst -Force
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
# Tests C/D/E -- root-cause attribution: which Bazel-only ingredient flips it?
#
# Test B is the minimal symlink condition at a SHORT path with a REAL-file JDK
# copy (only classes.jsa is a link). Bazel's runfiles tree differs two ways:
#   * the JDK is launched from a DEEP path (~200 chars, near MAX_PATH)
#   * the launcher itself is a symlink -- java.exe, jvm.dll AND classes.jsa are
#     all per-file links into the external cache (a full SYMLINK TREE)
# These three tests toggle those two variables one at a time around B:
#   C  deep path,  real-file copy (only classes.jsa linked)  -> isolates DEPTH
#   D  short path, full symlink tree                         -> isolates the TREE
#   E  deep path,  full symlink tree                         -> faithful Bazel mirror
# They are exploratory (Expect = OK-or-CRASH); the Attribution block below reads
# which crashed to conclude the trigger. Aim ~200 chars so <deep>\bin\java.exe
# matches the field/Bazel depth while essential JDK files stay under MAX_PATH.
# ---------------------------------------------------------------------------
$deepTarget = 200 - ('\bin\java.exe'.Length)   # so <deep>\bin\java.exe ~= 200

# Test C -- deep path, real-file copy, only classes.jsa is a symlink.
Write-Section "Test C -- DEPTH: real-file JDK copy at a deep path, classes.jsa symlinked"
$deepReal = New-DeepDir (Join-Path $OutDir 'C-deep-real') $deepTarget
Write-Host "Deep copy root ($($deepReal.Length) chars): $deepReal"
Copy-Jdk $Jdk $deepReal
$deepRealJava = Join-Path $deepReal 'bin\java.exe'
$deepRealJsa  = Join-Path $deepReal $relJsa
New-FileSymlink $deepRealJsa $realJsa
Write-Host "java.exe path is $($deepRealJava.Length) chars; classes.jsa is now: $((Get-FileFacts $deepRealJsa).Kind)"
$results += Invoke-JavaProbe -Tag 'C-deep-real-symlink' -JavaExe $deepRealJava -Expect 'OK-or-CRASH' -ExtraArgs @()

# Test D -- short path, full per-file symlink tree (Bazel runfiles shape).
Write-Section "Test D -- TREE: full per-file symlink mirror of the JDK at a short path"
$treeShort = Join-Path $OutDir 'D-tree-short'
$dStats = New-SymlinkTree $Jdk $treeShort
$treeShortJava = Join-Path $treeShort 'bin\java.exe'
Write-Host "Symlinked $($dStats.Created) files ($($dStats.Skipped) skipped over MAX_PATH)."
Write-Host "java.exe is now: $((Get-FileFacts $treeShortJava).Kind); classes.jsa is now: $((Get-FileFacts (Join-Path $treeShort $relJsa)).Kind)"
$results += Invoke-JavaProbe -Tag 'D-tree-short' -JavaExe $treeShortJava -Expect 'OK-or-CRASH' -ExtraArgs @()

# Test E -- deep path AND full symlink tree: the faithful standalone Bazel mirror.
Write-Section "Test E -- DEPTH + TREE: full symlink mirror at a deep path (Bazel mirror)"
$treeDeep = New-DeepDir (Join-Path $OutDir 'E-deep-tree') $deepTarget
$eStats = New-SymlinkTree $Jdk $treeDeep
$treeDeepJava = Join-Path $treeDeep 'bin\java.exe'
Write-Host "Deep tree root ($($treeDeep.Length) chars): $treeDeep"
Write-Host "Symlinked $($eStats.Created) files ($($eStats.Skipped) skipped over MAX_PATH); java.exe path is $($treeDeepJava.Length) chars."
$results += Invoke-JavaProbe -Tag 'E-deep-tree' -JavaExe $treeDeepJava -Expect 'OK-or-CRASH' -ExtraArgs @()

# ---------------------------------------------------------------------------
# Test F -- localize WHICH symlinked file in the tree is the trigger. Tests D/E
# proved the symlink TREE crashes where a lone classes.jsa symlink (B) does not;
# these isolate the responsible component by symlinking one thing at a time on
# an otherwise real-file copy at a short path (everything else, including a real
# classes.jsa unless named, stays a regular file):
#   F1 java.exe        only        F4 jvm.dll + classes.jsa
#   F2 jvm.dll         only        F5 entire bin\  subtree
#   F3 lib\modules     only        F6 entire lib\  subtree
# F1-F4 share one copy (restoring the real file between probes); F5/F6 get their
# own copies. Whichever minimal set crashes is the precise trigger to file.
# ---------------------------------------------------------------------------
$jvmRel = 'bin\server\jvm.dll'
$modRel = 'lib\modules'
$exeRel = 'bin\java.exe'

Write-Section "Test F -- localize the trigger file (single components symlinked)"
$fBase = Join-Path $OutDir 'F-base'
Copy-Jdk $Jdk $fBase
$fJava = Join-Path $fBase 'bin\java.exe'

# F1: only java.exe is a symlink.
New-FileSymlink (Join-Path $fBase $exeRel) (Join-Path $Jdk $exeRel)
$results += Invoke-JavaProbe -Tag 'F1-symlink-java-exe' -JavaExe $fJava -Expect 'OK-or-CRASH' -ExtraArgs @()
Restore-RealFile $fBase $exeRel

# F2: only jvm.dll is a symlink.
New-FileSymlink (Join-Path $fBase $jvmRel) (Join-Path $Jdk $jvmRel)
$results += Invoke-JavaProbe -Tag 'F2-symlink-jvm-dll' -JavaExe $fJava -Expect 'OK-or-CRASH' -ExtraArgs @()
Restore-RealFile $fBase $jvmRel

# F3: only lib\modules (the JDK module image) is a symlink.
New-FileSymlink (Join-Path $fBase $modRel) (Join-Path $Jdk $modRel)
$results += Invoke-JavaProbe -Tag 'F3-symlink-lib-modules' -JavaExe $fJava -Expect 'OK-or-CRASH' -ExtraArgs @()
Restore-RealFile $fBase $modRel

# F4: jvm.dll AND classes.jsa are symlinks (the two CDS-mapping participants).
New-FileSymlink (Join-Path $fBase $jvmRel) (Join-Path $Jdk $jvmRel)
New-FileSymlink (Join-Path $fBase $relJsa) $realJsa
$results += Invoke-JavaProbe -Tag 'F4-symlink-jvm+jsa' -JavaExe $fJava -Expect 'OK-or-CRASH' -ExtraArgs @()
Restore-RealFile $fBase $jvmRel
Restore-RealFile $fBase $relJsa

# F5: every file under bin\ is a symlink (rest of the JDK real).
$f5 = Join-Path $OutDir 'F5-bin-tree'
Copy-Jdk $Jdk $f5
$n5 = New-SubtreeSymlinks $f5 'bin'
Write-Host "F5: symlinked $n5 files under bin\."
$results += Invoke-JavaProbe -Tag 'F5-bin-tree' -JavaExe (Join-Path $f5 'bin\java.exe') -Expect 'OK-or-CRASH' -ExtraArgs @()

# F6: every file under lib\ is a symlink (rest of the JDK real).
$f6 = Join-Path $OutDir 'F6-lib-tree'
Copy-Jdk $Jdk $f6
$n6 = New-SubtreeSymlinks $f6 'lib'
Write-Host "F6: symlinked $n6 files under lib\."
$results += Invoke-JavaProbe -Tag 'F6-lib-tree' -JavaExe (Join-Path $f6 'bin\java.exe') -Expect 'OK-or-CRASH' -ExtraArgs @()

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

# Per-test crash flags (CRASH == a real access-violation hs_err was written).
function Crashed($tag) { (($results | Where-Object Tag -eq $tag).Result) -eq 'CRASH' }
$aCrash = Crashed 'A2-symlink-auto'
$aReal  = ($results | Where-Object Tag -eq 'A1-real-on').Result    -eq 'OK'
$bCrash = Crashed 'B2-symlink-default'  # short, real copy, classes.jsa symlink
$bReal  = ($results | Where-Object Tag -eq 'B1-copy-real').Result  -eq 'OK'
$bOff   = ($results | Where-Object Tag -eq 'B4-symlink-off').Result -eq 'OK'
$bBase  = $bCrash
$cDeep  = Crashed 'C-deep-real-symlink' # + depth
$dTree  = Crashed 'D-tree-short'        # + symlink tree
$eBoth  = Crashed 'E-deep-tree'         # + depth + tree

# Minimal repro: a single symlinked classes.jsa crashes (clean single-variable
# shape) with the real file and -Xshare:off both clean. Variant repro: the bug
# only shows once the Bazel-shape ingredients (depth and/or the symlink tree)
# are added -- still a genuine access-violation reproduction, just not minimal.
$reproducedMinimal = ($aReal -and $aCrash) -or ($bReal -and $bCrash -and $bOff)
$reproducedVariant = $cDeep -or $dTree -or $eBoth
$reproduced = $reproducedMinimal -or $reproducedVariant
$verdict = if ($reproducedMinimal) {
  "REPRODUCED (minimal) -- a single symlinked classes.jsa crashes the JVM (access violation); byte-identical real file and -Xshare:off both run cleanly."
} elseif ($reproducedVariant) {
  "REPRODUCED (Bazel-shape) -- the minimal single-symlink case did not crash, but a Bazel-shape variant did; see ROOT CAUSE below."
} elseif (($results | Where-Object Result -eq 'CRASH')) {
  "PARTIAL -- a crash was observed but not in a clean shape; inspect the table and hs_err logs."
} else {
  "NOT reproduced on this JDK/OS -- no access violation observed, even by the faithful Bazel mirror (E)."
}

Write-Host "VERDICT: $verdict"

# ---------------------------------------------------------------------------
# Attribution -- compare B/C/D/E to name which Bazel-only ingredient is the
# trigger. The differences from baseline B tell us whether depth, the symlink
# tree, or only their combination flips a working JDK into a crashing one.
# ---------------------------------------------------------------------------
$attribution = `
  if     ($bBase) { "Baseline already crashes -- a single symlinked classes.jsa at a short path is sufficient; depth and the symlink tree are not required." }
  elseif ($cDeep -and $dTree) { "Either ingredient alone reproduces -- both DEPTH (C) and the SYMLINK TREE (D) independently flip the JDK into a crash." }
  elseif ($cDeep) { "DEPTH is the trigger -- a deep launch path (C) crashes where the identical short-path copy (B) does not; the symlink tree is not required." }
  elseif ($dTree) { "The SYMLINK TREE is the trigger -- symlinking the launcher/runtime (D), not just classes.jsa, crashes where B does not; depth is not required." }
  elseif ($eBoth) { "Only DEPTH + TREE together reproduce (E) -- neither ingredient alone (C, D) is enough; the combination is required." }
  else            { "Not reproduced even by the faithful Bazel mirror (E) -- the trigger involves a factor these tests do not capture." }

Write-Section "Attribution (B baseline vs C depth vs D tree vs E both)"
$results |
  Where-Object Tag -in 'B2-symlink-default','C-deep-real-symlink','D-tree-short','E-deep-tree' |
  Format-Table -AutoSize @{L='Tag';E={$_.Tag}}, @{L='Result';E={$_.Result}}, @{L='Frame';E={$_.Frame}} |
  Out-String | Write-Host
Write-Host "ROOT CAUSE: $attribution"

# Finer attribution -- which symlinked file in the tree is the trigger.
$fExe = Crashed 'F1-symlink-java-exe'
$fJvm = Crashed 'F2-symlink-jvm-dll'
$fMod = Crashed 'F3-symlink-lib-modules'
$fJj  = Crashed 'F4-symlink-jvm+jsa'
$fBin = Crashed 'F5-bin-tree'
$fLib = Crashed 'F6-lib-tree'

$singles = @()
if ($fExe) { $singles += 'java.exe' }
if ($fJvm) { $singles += 'jvm.dll' }
if ($fMod) { $singles += 'lib\modules' }

$triggerFile = `
  if     ($singles.Count -gt 0) { "A single symlinked file is sufficient: $($singles -join ', '). (Symlinking just that file, with the rest of the JDK on real files, crashes.)" }
  elseif ($fJj)  { "Neither jvm.dll nor classes.jsa alone, but symlinking BOTH jvm.dll AND classes.jsa together triggers it." }
  elseif ($fBin -and $fLib) { "No single file; symlinking either the whole bin\\ or the whole lib\\ subtree triggers it." }
  elseif ($fBin) { "No single file; symlinking the whole bin\\ subtree triggers it (lib\\ alone does not)." }
  elseif ($fLib) { "No single file; symlinking the whole lib\\ subtree triggers it (bin\\ alone does not)." }
  else           { "No tested subset reproduced -- the trigger needs more of the image symlinked than F covers (the full tree D/E still crashes)." }

Write-Section "Trigger-file localization (single components symlinked)"
$results |
  Where-Object Tag -in 'F1-symlink-java-exe','F2-symlink-jvm-dll','F3-symlink-lib-modules','F4-symlink-jvm+jsa','F5-bin-tree','F6-lib-tree' |
  Format-Table -AutoSize @{L='Tag';E={$_.Tag}}, @{L='Result';E={$_.Result}}, @{L='Frame';E={$_.Frame}} |
  Out-String | Write-Host
Write-Host "TRIGGER FILE: $triggerFile"

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
  attribution = $attribution
  triggerFile = $triggerFile
  runs       = $results
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir 'results.json')

# Step summary when running under GitHub Actions.
if ($env:GITHUB_STEP_SUMMARY) {
  $lines = @("### $verdict", "", "**Root cause:** $attribution", "", "**Trigger file:** $triggerFile", "", "JDK: ``$($realFacts.Path)``", "", "| Tag | Command | Exit | Result | Frame |", "|---|---|---|---|---|")
  foreach ($r in $results) { $lines += "| $($r.Tag) | ``$($r.Command)`` | $($r.Exit) | **$($r.Result)** | $($r.Frame) |" }
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
}
