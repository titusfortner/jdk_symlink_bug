# JVM fails to start (EXCEPTION_ACCESS_VIOLATION in jvm.dll) when the runtime module image `lib\modules` is a symbolic link (Windows)

## Summary

On Windows, if the JDK runtime module image `<jdk>\lib\modules` (the *jimage*) is
a **symbolic link** to a byte-identical real image, the JVM fails to start — even
for `java -version`:

- With class data sharing on (the default, or `-Xshare:on`): it crashes with
  `EXCEPTION_ACCESS_VIOLATION` (reading address `0x0`) inside `jvm.dll` during VM
  initialization, before any Java frames run. An `hs_err_pid*.log` is written.
- With `-Xshare:off`: it does **not** access-violate, but still fails to start:
  `Error occurred during initialization of VM` /
  `java.lang.NoClassDefFoundError: java.lang.Object` — i.e. the boot classes
  cannot be loaded from the symlinked module image.

Making `lib\modules` a regular file (everything else identical) fixes it. The
bytes reached through the link are identical to the real image; the only variable
that flips behavior is **regular file vs symlink**.

> This corrects an earlier diagnosis in this repo that blamed the CDS archive
> `bin\server\classes.jsa`. That was wrong: symlinking `classes.jsa` alone does
> **not** crash, and `-Xshare:off` is **not** a workaround. The trigger is
> `lib\modules`, and the failure happens with CDS disabled too — CDS only turns
> it from a clean init error into a hard null-pointer crash.

## Affected configuration

- **OS:** Windows (NTFS symbolic links; Developer Mode or elevated to create them).
- **JDK:** **vendor-independent** — reproduced on Eclipse Temurin, Microsoft Build
  of OpenJDK, **and** Azul Zulu, on **JDK 21 and 25** (e.g. Zulu 25.0.3+9). Not a
  Zulu-specific issue. Linux/macOS were not tested here.
- **Not path-depth dependent:** a deep (~200-char) launch path with a real-file
  JDK does not crash; a short path with a symlinked `lib\modules` does.
- **Trigger in the wild:** Bazel's `rules_java` materializes the JDK into a
  runfiles tree where **every** file — including `lib\modules` — is a symlink back
  to the external cache. A subprocess `java` launched from that tree therefore has
  a symlinked `lib\modules` and crashes. (A plain `java_test` does not, because
  Bazel's test wrapper launches `java` from a path where `lib\modules` is real.)

## Crash signature (CDS on)

```
# EXCEPTION_ACCESS_VIOLATION (0xc0000005) at pc=0x...,  jvm.dll+0xfd94d
# Java VM: OpenJDK 64-Bit Server VM (25.0.3+9-LTS, mixed mode, sharing, ... windows-amd64)
siginfo: EXCEPTION_ACCESS_VIOLATION (0xc0000005), reading address 0x0000000000000000

Native frames: (no Java frames yet — failure is during VM init)
V  [jvm.dll+0xfd94d]
V  [jvm.dll+0x3b4bbd]
...
C  [jli.dll+0x554d]
C  [ucrtbase.dll+0x37b0]
C  [KERNEL32.DLL+...]
```

The null read (`RAX=0, RCX=0`, reading `0x0`) during early VM init, together with
the `-Xshare:off` `NoClassDefFoundError: java.lang.Object`, points at the runtime
**reading/mapping the module image** through the symlink. We have not confirmed
the exact internal cause; a plausible area to inspect is how HotSpot's Windows
jimage open/`mmap` path obtains the image size/handle for a reparse point
(symbolic link) vs a regular file (e.g. taking the symlink's own size — `0` —
rather than the target's, yielding an empty mapping). The repro captures
`hs_err_pid*.log` + minidumps for the precise frames.

## Reproduction (no Bazel required)

`repro.ps1` builds JDK copies and toggles one variable at a time, classifying a
run as **CRASH** only when a real `hs_err` with `EXCEPTION_ACCESS_VIOLATION` is
written (a clean nonzero-exit abort is reported as **ABORT**, never as the bug).

```powershell
# Windows 10+, Developer Mode or elevated shell (so real symlinks can be made).
# JAVA_HOME points at any JDK (vendor-independent).
pwsh ./repro.ps1
```

### Evidence matrix (representative; identical conclusion on all vendors × 21/25)

Each row is a real-file JDK copy with exactly the named file(s) replaced by a
symlink, then `java -version`:

| Test | What is a symlink | Path | Result |
|---|---|---|---|
| B2 | `bin\server\classes.jsa` only | short | OK |
| C  | `bin\server\classes.jsa` only | deep (~200) | OK |
| F1 | `bin\java.exe` only | short | OK |
| F2 | `bin\server\jvm.dll` only | short | OK |
| F4 | `bin\server\jvm.dll` + `classes.jsa` | short | OK |
| F5 | entire `bin\` subtree | short | OK |
| **F3** | **`lib\modules` only** | short | **CRASH** (EXCEPTION_ACCESS_VIOLATION) |
| F6 | entire `lib\` subtree (contains `lib\modules`) | short | CRASH |
| D / E | full per-file symlink tree (Bazel shape) | short / deep | CRASH |
| **F7** | `lib\modules`, **`-Xshare:off`** | short | **ABORT** — `NoClassDefFoundError: java.lang.Object` |
| F8 | `lib\modules`, `-Xshare:on` | short | CRASH |

Conclusion: the single sufficient trigger is a symlinked `lib\modules`; nothing
else (including `classes.jsa`, `jvm.dll`, `java.exe`, the whole `bin\`, or path
depth) reproduces, and disabling CDS does not avoid the failure.

### Minimal manual version

```powershell
$real = $env:JAVA_HOME
$link = "C:\jdk-copy"
Copy-Item -Recurse -Force $real $link
$mod = "$link\lib\modules"
Remove-Item $mod
New-Item -ItemType SymbolicLink -Path $mod -Target "$real\lib\modules"

& "$link\bin\java.exe" -version             # EXCEPTION_ACCESS_VIOLATION, hs_err written
& "$link\bin\java.exe" -Xshare:off -version # NoClassDefFoundError: java.lang.Object (still fails)
```

## Expected vs actual

- **Expected:** a symlinked `lib\modules` should be read identically to the real
  file (it transparently resolves to byte-identical content), so the JVM should
  start normally. If symlinked module images are intentionally unsupported, it
  should fail cleanly — not access-violate.
- **Actual:** `EXCEPTION_ACCESS_VIOLATION` in `jvm.dll` during VM init (CDS on);
  `NoClassDefFoundError: java.lang.Object` (CDS off). The JVM never starts.

## Workaround

Make `lib\modules` a regular file (dereference the symlink). For Bazel users,
launch `java` from a JDK whose `lib\modules` is a real file rather than from the
runfiles symlink tree (e.g. use `JAVA_HOME` / a non-symlinked runtime for
subprocess JVMs). **`-Xshare:off` is not a workaround** — it only changes the
symptom.

## Artifacts to attach

From the `repro.ps1` output directory: `hs_err_pid*.log`, `*.mdmp`,
`results.json`, and the per-run `*.out.txt` / `*.err.txt` (the `F3`/`F7`/`F8`
files show the crash, the `-Xshare:off` `NoClassDefFoundError`, and the
`-Xshare:on` crash respectively). CI logs/artifacts are produced by the
`repro.yml` workflow in this repository across the vendor × version matrix.
