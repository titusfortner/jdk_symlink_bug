# JDK crash: symlinked `classes.jsa` (CDS archive)

`EXCEPTION_ACCESS_VIOLATION` in `jvm.dll` when the default CDS archive
(Windows: `bin\server\classes.jsa`) is a **symbolic link** instead of a regular
file. Disabling class data sharing (`-Xshare:off`) works around it.

Originally observed on **Azul Zulu** JDK 21/25 (Windows, via Bazel's
`rules_java` runfiles). This repo runs the repro across vendors
(`temurin`, `zulu`, `microsoft`) and versions (17/21/25) to pin down whether it
is an OpenJDK-wide bug or vendor-specific.

> Note: on Windows the server-VM CDS archive lives at `bin\server\classes.jsa`
> (on Linux/macOS it's `lib/server/classes.jsa`).

## What the repro proves

At startup the JVM memory-maps the default CDS archive `lib/server/classes.jsa`.
If that single file is swapped for a symlink pointing at a byte-identical real
archive — nothing else changed — `java -version` crashes. `-Xshare:off` avoids
it because CDS never opens the archive. One variable: regular file vs symlink.

## Reproduce in CI

Run the **JDK classes.jsa symlink crash repro** workflow from the Actions tab
(`workflow_dispatch`). For each vendor×version in the matrix (temurin/zulu/
microsoft × 17/21/25) on a `windows-latest` runner it:

1. Installs the JDK.
2. Copies it, then replaces *only* the copy's `bin\server\classes.jsa` with a
   symlink pointing back at the original.
3. Runs `java -Xshare:on -version` → expected to crash, writing
   `hs_err_pid*.log` and a `*.mdmp`.
4. Runs `java -Xshare:off -version` → expected to succeed.
5. Uploads the `hs_err` log and minidump as `jdk-crash-<vendor>-<version>`.
6. Prints a verdict (REPRODUCED / NOT reproduced / N/A) to the job summary.

JDKs that ship no default CDS archive report **N/A** — there is no
`classes.jsa` to symlink.

## Reproduce locally (Windows 10+, developer mode or admin)

```powershell
# Setup: have a JDK at C:\jdk-real
$real = "C:\jdk-real"

# Make a parallel JDK directory, replace ONLY classes.jsa with a symlink
$link = "C:\jdk-link"
Copy-Item -Recurse $real $link
$linkJsa = "$link\bin\server\classes.jsa"
Remove-Item $linkJsa
New-Item -ItemType SymbolicLink -Path $linkJsa -Target "$real\bin\server\classes.jsa"

# Crashes: EXCEPTION_ACCESS_VIOLATION in jvm.dll, hs_err written.
& "$link\bin\java.exe" -Xshare:on -version

# Workaround: succeeds.
& "$link\bin\java.exe" -Xshare:off -version
```

Attach the resulting `hs_err_pid*.log` and `*.mdmp` to the bug report.
