# JDK fails to start: symlinked `lib\modules` (runtime module image)

On Windows, when the JDK runtime module image `lib\modules` (the *jimage*) is a
**symbolic link** instead of a regular file, `java` fails to start — even
`java -version`:

- **default / `-Xshare:on`:** `EXCEPTION_ACCESS_VIOLATION` (null read) in
  `jvm.dll` during VM init, `hs_err` written.
- **`-Xshare:off`:** no crash, but still dies —
  `Error occurred during initialization of VM` /
  `java.lang.NoClassDefFoundError: java.lang.Object`.

So `-Xshare:off` is **not** a workaround; class data sharing only changes the
*symptom*. Making `lib\modules` a regular file (everything else identical) fixes
it. Reproduced on **Temurin, Microsoft, and Azul Zulu**, JDK **21 and 25**.

> **This corrects an earlier diagnosis** (kept in git history) that blamed the
> CDS archive `bin\server\classes.jsa`. Symlinking `classes.jsa` alone does
> **not** crash; the trigger is `lib\modules`, and it is vendor-independent.
> First hit via Bazel's `rules_java` runfiles, which materialize the whole JDK —
> including `lib\modules` — as a symlink tree.

## For a JDK maintainer

- **[`BUG_REPORT.md`](BUG_REPORT.md)** — the writeup to file/forward: summary,
  affected configs, crash signature, the single-variable evidence matrix, exact
  repro steps, expected vs actual, workaround, and which artifacts to attach.
- **[`repro.ps1`](repro.ps1)** — a self-contained Windows repro (no Bazel). It
  copies a JDK and toggles **one file at a time** to a symlink, reporting `CRASH`
  only when a real access violation (`hs_err`) is written. It proves a symlinked
  `lib\modules` is the single sufficient trigger — while `classes.jsa`, `jvm.dll`,
  `java.exe`, the whole `bin\` subtree, and path depth are all harmless — and
  that `-Xshare:off` does not avoid it.
- **[`bazel-repro/`](bazel-repro/)** — a ~5-file Bazel project that reproduces
  the crash through Bazel's real runfiles machinery (CI confirmed: a subprocess
  JVM from the runfiles symlink tree dies with `EXCEPTION_ACCESS_VIOLATION`,
  while a plain `java_test` does not).

## What the repro proves

Holding everything else byte-identical, the **only** variable that breaks startup
is `lib\modules` being a symlink vs a regular file. With CDS on it null-derefs in
`jvm.dll`; with CDS off the boot classes can't be loaded
(`NoClassDefFoundError: java.lang.Object`). The likely area to inspect is how
HotSpot's Windows jimage open/`mmap` handles a reparse point (e.g. taking the
symlink's own size rather than the target's). Symlinking `classes.jsa` — the
file the original report blamed — does not reproduce.

## Reproduce locally (Windows 10+, Developer Mode or admin)

```powershell
# JAVA_HOME points at any JDK (vendor-independent).
pwsh ./repro.ps1
# Artifacts (hs_err + minidump + results.json) land in .\cds-symlink-artifacts
```

Minimal manual version:

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

## Reproduce in CI

Run the **JDK classes.jsa symlink crash repro** workflow from the Actions tab
(`workflow_dispatch`). For each vendor×version (temurin/zulu/microsoft × 21/25)
on `windows-latest` it runs `repro.ps1` and uploads `hs_err_*.log`, `*.mdmp`,
`results.json`, and per-run console output as
`jdk-cds-symlink-<vendor>-<version>`. The step summary reports the **root cause**,
the **trigger file** (`lib\modules`), and the workaround characterization. All
vendor×version cells reproduce.
