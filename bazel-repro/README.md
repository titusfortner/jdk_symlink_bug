# Minimal Bazel reproduction

A ~5-file Bazel project that exercises the real path that first surfaced the
JDK crash: launching the `remotejdk_25` (Azul Zulu) JVM out of Bazel's
**symlinked runfiles tree** on Windows, where `bin\server\classes.jsa` is a
symlink. The JVM crashes (`EXCEPTION_ACCESS_VIOLATION` in `jvm.dll`) memory-
mapping that symlinked CDS archive during init.

The standalone [`../repro.ps1`](../repro.ps1) reproduces the symlink condition
without Bazel; this project confirms it through Bazel's actual machinery and
pins down the *minimal* trigger.

## Files

| File | Purpose |
|------|---------|
| `MODULE.bazel` | bzlmod; only dep is `rules_java` 9.6.1 (brings Zulu `remotejdk_25`) |
| `.bazelrc` | the trigger flags — omit any one and the bug is expected to vanish |
| `.bazelversion` | `7.6.2` (keeps `--legacy_external_runfiles` on by default) |
| `BUILD.bazel` | three experiment targets |
| `Main.java` | trivial `main()` |
| `run_java_version.sh` / `run_deploy_jar.sh` | subprocess-launch scripts |

## Conditions that must hold

- **Windows**, with **Developer Mode or admin** (so Bazel can create symlinks).
- Vendor **Zulu** — supplied automatically by `remotejdk_25` from `rules_java`.
- `--enable_runfiles`, `--windows_enable_symlinks`, `--legacy_external_runfiles`
  all on (set in `.bazelrc`). Drop any and Bazel stops producing the symlinked
  `classes.jsa`.

## Experiment order

Each target isolates one hypothesis. Whichever crashes **first** is the minimal
case to file; no need to add the later ingredients.

1. `//:empty_test` — pure `java_test`. Bazel's wrapper execs the runfiles JDK to
   run it. **Crash here ⇒ pure-Java repro.**
2. `//:subprocess_version` — `sh_test` spawning `java -version` from runfiles.
   **Crash here (but not 1) ⇒ trigger is "subprocess JVM from runfiles", not
   `java_test`.**
3. `//:subprocess_deploy` — `sh_test` spawning `java -jar tiny_deploy.jar`.
   **Crash here (but not 1–2) ⇒ the deploy-jar launch is part of the trigger.**

If none crash at this short path (`C:\…\bazel-repro`), the remaining hypothesis
is **path depth** — clone into a very deep directory and re-run (our field crash
was a ~200-char path).

## Run

In CI: trigger the **Bazel JDK classes.jsa symlink repro** workflow
(`workflow_dispatch`) on `windows-latest`. It runs all three targets, prints a
pass/fail summary, and uploads `hs_err_pid*.log`, minidumps, and Bazel test logs
as `bazel-jdk-symlink-repro`.

Locally (Windows, Developer Mode):

```powershell
cd bazel-repro
bazel test //:empty_test //:subprocess_version //:subprocess_deploy `
  --test_output=streamed --cache_test_results=no `
  "--test_env=JDK_JAVA_OPTIONS=-XX:ErrorFile=D:/hs_err_pid%p.log"
```

A target whose JVM hits the access violation fails (non-zero exit) and leaves an
`hs_err_pid*.log` containing `EXCEPTION_ACCESS_VIOLATION` in `jvm.dll`.
