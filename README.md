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
it.

> First surfaced via Bazel's `rules_java`, whose runfiles tree materializes the
> whole JDK — including `lib\modules` — as a symlink tree. Bazel turned out to be
> incidental: a stock JDK with a single symlinked `lib\modules` reproduces it, so
> the Bazel scaffolding has been removed in favor of the minimal repro below.

## Minimal reproduction (Windows 10+, Developer Mode or admin)

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

That is the entire bug: hold the JDK byte-for-byte identical and the only
variable that breaks startup is `lib\modules` being a symlink vs a regular file.

## In CI

[`.github/workflows/repro.yml`](.github/workflows/repro.yml) is fully
self-contained (no separate script, no Bazel). Trigger it from the Actions tab
(`workflow_dispatch`). It runs the steps above on `windows-latest` across a
**Temurin** Java-version matrix (**11, 17, 21, 25**) and uploads each
`hs_err_*.log`.

The matrix answers *"is this a regression?"*: `lib\modules` has existed since
Java 9 (Project Jigsaw), so if every version crashes the bug is long-standing
rather than newly introduced. A cell is **green** when the crash reproduces
(this repo's purpose) and **red** if that version tolerates the symlink — only a
real `EXCEPTION_ACCESS_VIOLATION` hs_err counts as a crash.

## For a JDK maintainer

**[`BUG_REPORT.md`](BUG_REPORT.md)** — the writeup to file: summary, affected
configs, crash signature, exact repro, expected vs actual, and workaround. The
likely area to inspect is how HotSpot's Windows jimage open/`mmap` handles a
reparse point (e.g. taking the symlink's own size rather than the target's).
