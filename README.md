# JDK crash: symlinked `lib\modules` (Windows)

On Windows, when the JDK runtime module image `lib\modules` (the *jimage*) is a
**symbolic link** instead of a regular file, `java` fails to start — even
`java -version`:

This surfaced in real-world use with **[Bazel](https://bazel.build/)**, which
relies heavily on symlinks on Windows — see [Origin](#origin) below.

## Reproduce

#### GitHub Actions
Error and logs: https://github.com/titusfortner/jdk_symlink_bug/actions/workflows/bug.yml

#### Locally:

Windows 10+ with Developer Mode or an elevated shell (so real symlinks can be
created):

```powershell
$real = $env:JAVA_HOME
$link = "C:\jdk-copy"
Copy-Item -Recurse -Force $real $link
$mod = "$link\lib\modules"
Remove-Item $mod
New-Item -ItemType SymbolicLink -Path $mod -Target "$real\lib\modules"

& "$link\bin\java.exe" -version             # EXCEPTION_ACCESS_VIOLATION, hs_err written
& "$link\bin\java.exe" -Xshare:off -version # still fails: NoClassDefFoundError: java.lang.Object
```

The only variable that breaks startup is `lib\modules` being a symlink vs a
regular file; the bytes reached through the link are identical.

## In CI

[`.github/workflows/repro.yml`](.github/workflows/repro.yml) runs the steps above
on `windows-latest` (`workflow_dispatch`) and uploads the `hs_err_*.log`. This is
a JDK-level issue: `lib\modules` has existed since Java 9 (Project Jigsaw) and the
crash reproduces on any build that ships a default CDS archive (JDK 12+).

**What counts as a reproduction.** The `java -version` step is *expected to
fail* — that failure is the bug, so a reproducing run is **red**. The JVM writes
an `hs_err` crash log (uploaded as an artifact) whose problematic frame is
`jvm.dll` with `EXCEPTION_ACCESS_VIOLATION`. The crash happens under
`java -version`, which runs no application code, so the fault is in JVM startup
itself.

## Origin

This bug surfaced while working with Bazel, which
leans heavily on symlinks — especially on Windows, where its `rules_java`
materializes the JDK as a **symlink tree** rather than copying files. That means
`lib\modules` ends up as a symbolic link, which is exactly the condition that
triggers the crash. So while the reproduction above is reduced to plain
PowerShell, the failure shows up naturally in any Bazel build that runs a
symlinked JDK on Windows.

