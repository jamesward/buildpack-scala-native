#!/usr/bin/env bash
# Real end-to-end smoke test for the Scala Native buildpack.
#
# Unlike smoke-stub.sh, this runs an ACTUAL `./sbt nativeLink`, so it needs a
# full build toolchain on PATH:
#   * a JDK (to run sbt)
#   * sbt
#   * clang / LLVM (the Scala Native ahead-of-time toolchain)
#   * the native link deps for the immix GC build (libunwind, zlib, ...)
#
# It emulates a Heroku deploy: stage the fixture into a fresh BUILD_DIR, give
# it a CACHE_DIR, run bin/detect + bin/compile + bin/release, then assert the
# slug is a *binary-only* slug whose executable actually runs.
#
# If the toolchain is missing this script exits 0 with a SKIP notice, so it is
# safe to include in a suite that also runs on machines without clang. Set
# REQUIRE_TOOLCHAIN=1 to turn a missing toolchain into a hard failure.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
buildpack=$(cd "$here/.." && pwd)
fixture="$here/fixtures/hello-native"

require=${REQUIRE_TOOLCHAIN:-0}

skip() {
  echo "-----> SKIP: $*"
  if [[ $require == 1 ]]; then
    echo " !     REQUIRE_TOOLCHAIN=1 set — treating missing toolchain as failure" >&2
    exit 1
  fi
  exit 0
}

command -v sbt   >/dev/null 2>&1 || skip "no sbt on PATH"
command -v java  >/dev/null 2>&1 || skip "no java on PATH"
command -v clang >/dev/null 2>&1 || skip "no clang on PATH (Scala Native needs LLVM/clang)"

[[ -d $fixture ]] || { echo "fixture not found: $fixture" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
build="$work/build"
cache="$work/cache"
env_dir="$work/env"
mkdir -p "$build" "$cache" "$env_dir"

echo "-----> Staging fixture into $build"
tar -C "$fixture" -cf - --exclude='./target' --exclude='./.heroku-sbt-cache' . \
  | tar -C "$build" -xf -

echo
echo "-----> bin/detect"
detected=$("$buildpack/bin/detect" "$build")
echo "       reported: $detected"
[[ $detected == *"Scala Native"* ]] || { echo "FAIL: detect did not report Scala Native"; exit 1; }

echo
echo "-----> bin/compile (real ./sbt nativeLink — this downloads deps and links a binary)"
"$buildpack/bin/compile" "$build" "$cache" "$env_dir"

echo
echo "-----> Verifying slug layout"
ls -A "$build" | sed 's/^/        /'

[[ -f $build/bin/hello-native && -x $build/bin/hello-native ]] \
  || { echo "FAIL: bin/hello-native missing or not executable"; exit 1; }

# It should be a real native executable, not a script or a JVM launcher.
file_info=$(file "$build/bin/hello-native" 2>/dev/null || echo "")
echo "       file: $file_info"
echo "$file_info" | grep -Eq 'ELF|Mach-O|executable' \
  || { echo "FAIL: bin/hello-native is not a native executable"; exit 1; }

# The binary must actually run.
echo "-----> Running the produced binary"
out=$("$build/bin/hello-native" || true)
echo "       output: $out"
echo "$out" | grep -q 'hello-native starting' \
  || { echo "FAIL: binary did not produce expected output"; exit 1; }

# Binary-only slug: no source / JVM survived.
for forbidden in build.sbt sbt project src target .jdk; do
  [[ -e "$build/$forbidden" ]] \
    && { echo "FAIL: slug still contains '$forbidden' (should be binary-only)"; exit 1; }
done
echo "       source tree and toolchain correctly dropped — slug is binary-only"

echo
echo "-----> bin/release"
"$buildpack/bin/release" "$build" | sed 's/^/        /'

echo
echo "-----> OK (real end-to-end)"
