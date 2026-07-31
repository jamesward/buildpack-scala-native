#!/usr/bin/env bash
# Stub-based smoke test for the Scala Native buildpack.
#
# Verifies bin/detect + bin/compile + bin/release turn a Scala Native project
# into a *binary-only* slug — WITHOUT needing a real LLVM/clang toolchain.
# A stub `./sbt` stands in for a real Scala Native build: it fakes the
# `nativeLink` task by writing a placeholder executable to the exact path
# scala-native uses (target/scala-<ver>/<name>-out) and makes
# `show Compile / nativeLink` print that path.
#
# What we assert:
#   * detect reports Scala Native
#   * the slug contains bin/hello-native (executable) and the Procfile
#   * the slug contains NOTHING ELSE from the source tree (no build.sbt, src/,
#     project/, target/, ./sbt) and no JVM (.jdk)
#   * bin/release picks bin/hello-native as the default web process
set -euo pipefail

# The stub ./sbt fakes nativeLink; no real toolchain is needed here.
export SCALA_NATIVE_SKIP_APT=1

here=$(cd "$(dirname "$0")" && pwd)
buildpack=$(cd "$here/.." && pwd)
fixture="$here/fixtures/hello-native"

[[ -d $fixture ]] || { echo "fixture not found: $fixture" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
build="$work/build"
cache="$work/cache"
env_dir="$work/env"
sbt_log="$work/sbt-stub.log"
mkdir -p "$build" "$cache" "$env_dir"

echo "-----> Staging fixture into $build"
tar -C "$fixture" -cf - --exclude='./target' --exclude='./.heroku-sbt-cache' . \
  | tar -C "$build" -xf -

# The path scala-native would produce the binary at.
fake_bin="$build/target/scala-3.3.4/hello-native-out"

# Replace the thin ./sbt wrapper with a stub that needs no toolchain.
cat > "$build/sbt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$sbt_log"
case "\$*" in
  *"show"*"nativeLink"*)
    # \`nativeLink\` is a File task; \`show\` prints the absolute path.
    echo "[info] $fake_bin"
    echo "[success] Total time: 0 s"
    ;;
  *nativeLink*)
    # The link task: produce a placeholder native executable on disk.
    mkdir -p "$(dirname "$fake_bin")"
    printf '#!/bin/sh\necho hello-native\n' > "$fake_bin"
    chmod +x "$fake_bin"
    echo "[success] Total time: 1 s"
    ;;
esac
exit 0
EOF
chmod +x "$build/sbt"

# Plant a heroku/jvm-style build-time JDK contribution; it must NOT survive
# into the runtime slug (a native binary needs no JVM).
mkdir -p "$build/.jdk/bin"
printf '#!/bin/sh\necho fake-java\n' > "$build/.jdk/bin/java"
chmod +x "$build/.jdk/bin/java"

echo
echo "-----> bin/detect"
detected=$("$buildpack/bin/detect" "$build")
echo "       reported: $detected"
[[ $detected == *"Scala Native"* ]] || { echo "FAIL: detect did not report Scala Native"; exit 1; }

echo
echo "-----> bin/compile"
"$buildpack/bin/compile" "$build" "$cache" "$env_dir"

echo
echo "-----> Verifying slug layout"
echo "Slug root:"
ls -A "$build" | sed 's/^/        /'

# The binary must be present and executable.
[[ -f $build/bin/hello-native && -x $build/bin/hello-native ]] \
  || { echo "FAIL: bin/hello-native missing or not executable"; exit 1; }
echo "       bin/hello-native present and executable"

# The Procfile must be preserved.
[[ -f $build/Procfile ]] || { echo "FAIL: Procfile not preserved"; exit 1; }
echo "       Procfile preserved: $(cat "$build/Procfile")"

# The slug must NOT contain any source / build tooling.
for forbidden in build.sbt sbt project src target .jdk .heroku-sbt-cache; do
  [[ -e "$build/$forbidden" ]] \
    && { echo "FAIL: slug still contains '$forbidden' (should be binary-only)"; exit 1; }
done
echo "       source tree, ./sbt, target/, and .jdk all correctly dropped"

# Slug root should contain exactly: bin/ and Procfile (order-independent).
got=$(ls -A "$build" | sort)
expected=$(printf '%s\n' bin Procfile | sort)
[[ $got == "$expected" ]] \
  || { echo "FAIL: slug root has unexpected entries:"; printf '  %s\n' "$got"; exit 1; }
echo "       slug root contains only bin/ and Procfile"

echo
echo "-----> bin/release"
release_out=$("$buildpack/bin/release" "$build")
echo "$release_out" | sed 's/^/        /'
echo "$release_out" | grep -q 'web: bin/hello-native' \
  || { echo "FAIL: release did not default web to bin/hello-native"; exit 1; }

echo
echo "-----> stub sbt invocations:"
nl -ba "$sbt_log" | sed 's/^/        /'

echo
echo "-----> OK"
