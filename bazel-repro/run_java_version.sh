#!/usr/bin/env bash
# Locate the JDK that Bazel materialized into this test's runfiles tree and
# spawn `java -version` as a subprocess. On Windows with symlinked runfiles the
# located java.exe resolves bin\server\classes.jsa through a symlink, which is
# the condition under test.
set -uo pipefail

echo "=== environment ==="
echo "PWD=$(pwd)"
echo "RUNFILES_DIR=${RUNFILES_DIR:-<unset>}"
echo "TEST_SRCDIR=${TEST_SRCDIR:-<unset>}"

# Search every plausible runfiles root for a java launcher under a bin/ dir.
# Do not use -type f: in the runfiles tree java.exe is itself a symlink.
find_java() {
    local root="$1"
    [ -n "$root" ] && [ -d "$root" ] || return 0
    find "$root" \( -name 'java.exe' -o -name 'java' \) -path '*bin*' 2>/dev/null | head -n 1
}

java=""
for root in "${RUNFILES_DIR:-}" "${TEST_SRCDIR:-}" "$(pwd)"; do
    java="$(find_java "$root")"
    [ -n "$java" ] && break
done

if [ -z "$java" ]; then
    echo "FATAL: could not locate a java launcher in the runfiles tree" >&2
    exit 3
fi

echo "=== runfiles JDK ==="
echo "java: $java"
jsa="$(dirname "$java")/server/classes.jsa"
echo "--- classes.jsa (is it a symlink?) ---"
ls -l "$jsa" 2>/dev/null || echo "(no $jsa)"

echo "=== launching subprocess: java -version ==="
"$java" -version
rc=$?
echo "java -version exit code: $rc"
exit $rc
