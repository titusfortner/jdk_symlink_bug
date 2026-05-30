# JVM crash (EXCEPTION_ACCESS_VIOLATION in jvm.dll) when the default CDS archive `classes.jsa` is a symbolic link

## Summary

On Windows, if the default CDS archive (`<jdk>\bin\server\classes.jsa`) is a
**symbolic link** to a byte-identical real archive, the JVM crashes with an
`EXCEPTION_ACCESS_VIOLATION` inside `jvm.dll` while memory-mapping the archive at
startup — even for `java -version`. Making the file a regular copy (everything
else identical) fixes it. `-Xshare:off` works around it because the archive is
never mapped.

The bytes reached through the link are identical to the real archive (same
SHA-256). The only variable that flips behavior is **regular file vs symlink**.

## Affected configuration

- **OS:** Windows (NTFS symbolic links).
- **JDK:** observed on Azul Zulu 21 and 25; the repro runs a vendor/version
  matrix (Temurin / Zulu / Microsoft × 21 / 25) to establish whether it is
  OpenJDK-wide or vendor-specific. Linux/macOS were not affected in our tests.
- **Trigger in the wild:** Bazel's `rules_java` materializes the JDK into a
  runfiles tree, where `classes.jsa` becomes a symlink back to the external
  cache. That is how this was first hit; the repro below removes Bazel entirely.

## What we observed in the field minidump

- The CDS archive open/read **succeeds** — reads through the symlink return the
  correct bytes (matching SHA-256).
- The Windows `MapViewOfFile` step on the symlinked archive returns "success"
  but with a **null base pointer / zero-length mapping**, which is then
  dereferenced → access violation. The crashing frame is in `jvm.dll` during CDS
  region mapping.
- With `-Xshare:off` (no mapping) or with a regular-file archive, startup is
  clean ("mixed mode, sharing").

We have not confirmed the exact internal cause; a plausible area to inspect is
how the Windows CDS mapping path obtains the archive's size/handle for a reparse
point (symbolic link) vs a regular file. The repro captures `hs_err_pid*.log` +
minidump for the precise frames.

## Reproduction (no Bazel required)

`repro.ps1` isolates the single variable two independent ways and only reports a
**CRASH** when a real access violation (`hs_err` with
`EXCEPTION_ACCESS_VIOLATION`) is written — a clean `-Xshare:on` "cannot map
archive" abort is reported separately and never counted as the bug.

```powershell
# Windows 10+, Developer Mode or elevated shell (so real symlinks can be made).
# JAVA_HOME points at a JDK that ships a default classes.jsa.
pwsh ./repro.ps1
```

It performs:

**Test A — surgical, one flag value changes**

| Run | Command | Expected |
|---|---|---|
| A1 | `java -Xshare:on   -XX:SharedArchiveFile=<real-file> -version` | OK |
| A2 | `java -Xshare:auto -XX:SharedArchiveFile=<symlink>   -version` | **CRASH** |
| A3 | `java -Xshare:on   -XX:SharedArchiveFile=<symlink>   -version` | crash or clean abort |

**Test B — exact field condition (default archive, default/auto mode)**

Copy the whole JDK (real files), then replace **only**
`bin\server\classes.jsa` with a symlink to the real archive:

| Run | Command (in the copy) | Expected |
|---|---|---|
| B1 | `java -version` (control: archive is a real file) | OK |
| B2 | `java -version` (archive is now a symlink) | **CRASH** |
| B3 | `java -Xshare:on  -version` | crash or clean abort |
| B4 | `java -Xshare:off -version` | OK (workaround) |

A `REPRODUCED` verdict requires the byte-identical real-file runs (A1/B1) and the
`-Xshare:off` workaround (B4) to pass while the symlink runs (A2/B2) crash — i.e.
the symlink is provably the only cause.

### Minimal manual version

```powershell
$real = $env:JAVA_HOME
$link = "C:\jdk-copy"
Copy-Item -Recurse -Force $real $link
$jsa = "$link\bin\server\classes.jsa"
Remove-Item $jsa
New-Item -ItemType SymbolicLink -Path $jsa -Target "$real\bin\server\classes.jsa"

& "$link\bin\java.exe" -version            # EXCEPTION_ACCESS_VIOLATION, hs_err written
& "$link\bin\java.exe" -Xshare:off -version # succeeds
```

## Expected vs actual

- **Expected:** a symlinked archive should map identically to the real file, or —
  if symlinked archives are intentionally unsupported — fail cleanly the way a
  corrupt/mismatched archive does (disable CDS and continue, or a clean fatal
  error under `-Xshare:on`). It should **not** access-violate.
- **Actual:** access violation in `jvm.dll` during archive mapping.

## Workaround

`-Xshare:off` (disables CDS). For Bazel users, dereferencing the JDK so
`classes.jsa` is a real file also avoids it.

## Artifacts to attach

From the `repro.ps1` output directory: `hs_err_pid*.log`, `*.mdmp`,
`results.json`, and the per-run `*.out.txt` / `*.err.txt`. CI logs/artifacts are
produced by the `repro.yml` workflow in this repository.
