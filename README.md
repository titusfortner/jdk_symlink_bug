# JDK crash: symlinked `classes.jsa` (CDS archive)

`EXCEPTION_ACCESS_VIOLATION` in `jvm.dll` when the default CDS archive
(Windows: `bin\server\classes.jsa`) is a **symbolic link** instead of a regular
file. Disabling class data sharing (`-Xshare:off`) works around it.

First observed on **Azul Zulu** JDK 21/25 (Windows, via Bazel's `rules_java`
runfiles, which materialize the JDK as a symlink tree). This repo removes Bazel
from the picture and reproduces it with a plain JDK + one symlink.

> On Windows the server-VM CDS archive lives at `bin\server\classes.jsa`
> (on Linux/macOS it's `lib/server/classes.jsa`).

## For a JDK maintainer

- **[`BUG_REPORT.md`](BUG_REPORT.md)** — the writeup to file/forward: summary,
  affected configs, what the field minidump showed, exact repro steps, expected
  vs actual, workaround, and which artifacts to attach.
- **[`repro.ps1`](repro.ps1)** — a self-contained Windows repro (no Bazel). It
  isolates the single variable (regular file vs symlink) two ways and only
  reports `CRASH` when a real access violation (`hs_err`) is written — a clean
  `-Xshare:on` "cannot map archive" abort is reported separately and never
  mistaken for the bug.

## What the repro proves

At startup the JVM memory-maps the default CDS archive. If that one file is
swapped for a symlink pointing at a byte-identical real archive — nothing else
changed — `java -version` crashes. `-Xshare:off` avoids it because the archive
is never mapped. Same `java.exe`, same jar, same bytes (matching SHA-256); the
only variable is **regular file vs symlink**.

## Reproduce locally (Windows 10+, Developer Mode or admin)

```powershell
# JAVA_HOME points at a JDK that ships a default classes.jsa.
pwsh ./repro.ps1
# Artifacts (hs_err + minidump + results.json) land in .\cds-symlink-artifacts
```

Minimal manual version:

```powershell
$real = $env:JAVA_HOME
$link = "C:\jdk-copy"
Copy-Item -Recurse -Force $real $link
$jsa = "$link\bin\server\classes.jsa"
Remove-Item $jsa
New-Item -ItemType SymbolicLink -Path $jsa -Target "$real\bin\server\classes.jsa"

& "$link\bin\java.exe" -version             # EXCEPTION_ACCESS_VIOLATION, hs_err written
& "$link\bin\java.exe" -Xshare:off -version # succeeds
```

## Reproduce in CI

Run the **JDK classes.jsa symlink crash repro** workflow from the Actions tab
(`workflow_dispatch`). For each vendor×version (temurin/zulu/microsoft × 21/25)
on `windows-latest` it runs `repro.ps1` and uploads `hs_err_*.log`, `*.mdmp`,
`results.json`, and per-run console output as
`jdk-cds-symlink-<vendor>-<version>`. A trustworthy `REPRODUCED` verdict
requires the byte-identical real-file runs and the `-Xshare:off` workaround to
pass while the symlink runs crash.

JDKs that ship no default CDS archive cannot be tested (nothing to symlink); run
`java -Xshare:dump` first or pick a JDK that ships one.
