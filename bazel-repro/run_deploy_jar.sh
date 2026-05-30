#!/usr/bin/env bash
# Like run_java_version.sh, but launches a fat deploy jar from the runfiles tree
# (`java -jar tiny_deploy.jar`) instead of `java -version`. Tests whether the
# deploy-jar launch is part of the trigger.
set -uo pipefail

echo "=== environment ==="
echo "PWD=$(pwd)"
echo "RUNFILES_DIR=${RUNFILES_DIR:-<unset>}"
echo "TEST_SRCDIR=${TEST_SRCDIR:-<unset>}"

find_one() {
    local root="$1"; shift
    [ -n "$root" ] && [ -d "$root" ] || return 0
    find "$root" "$@" 2>/dev/null | head -n 1
}

java=""
jar=""
for root in "${RUNFILES_DIR:-}" "${TEST_SRCDIR:-}" "$(pwd)"; do
    [ -z "$java" ] && java="$(find_one "$root" \( -name 'java.exe' -o -name 'java' \) -path '*bin*')"
    [ -z "$jar" ] && jar="$(find_one "$root" -name 'tiny_deploy.jar')"
done

if [ -z "$java" ]; then
    echo "FATAL: could not locate a java launcher in the runfiles tree" >&2
    exit 3
fi
if [ -z "$jar" ]; then
    echo "FATAL: could not locate tiny_deploy.jar in the runfiles tree" >&2
    exit 3
fi

echo "=== runfiles JDK + deploy jar ==="
echo "java: $java"
echo "jar:  $jar"
jsa="$(dirname "$java")/server/classes.jsa"
echo "--- classes.jsa (is it a symlink?) ---"
ls -l "$jsa" 2>/dev/null || echo "(no $jsa)"

echo "=== launching subprocess: java -jar tiny_deploy.jar ==="
"$java" -jar "$jar"
rc=$?
echo "java -jar exit code: $rc"
exit $rc
