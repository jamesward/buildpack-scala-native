#!/usr/bin/env bash
# Regression test for sbt 2.x output handling (no toolchain needed).
#
# sbt 2.x prints a `File`-typed task result (like `nativeLink`) as a *cached
# VirtualFile* reference rather than an absolute path:
#
#   [info] ${OUT}/native0.5/scala-3.8.4/cimdtest/cimdtest>sha256-<hash>/<size>
#
# and Scala Native under sbt 2 writes the binary to
# target/out/native<abi>/scala-<ver>/<proj>/<proj> (not target/scala-<ver>/).
# This reproduces exactly what the real Heroku build of `cimdapp` emitted, and
# asserts bin/compile still finds and ships the binary.
#
# It ALSO exercises the "default Procfile" path: no Procfile is committed, so
# the slug ships no Procfile and bin/release must default `web` to the binary.
set -euo pipefail

# The stub ./sbt fakes nativeLink; no real toolchain is needed here.
export SCALA_NATIVE_SKIP_APT=1

here=$(cd "$(dirname "$0")" && pwd)
buildpack=$(cd "$here/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
build="$work/build"; cache="$work/cache"; env_dir="$work/env"
sbt_log="$work/sbt-stub.log"
mkdir -p "$build/project" "$cache" "$env_dir"

# Minimal Scala Native project so bin/detect passes.
touch "$build/build.sbt"
echo 'addSbtPlugin("org.scala-native" % "sbt-scala-native" % "0.5.12")' > "$build/project/plugins.sbt"
echo 'sbt.version=2.0.4' > "$build/project/build.properties"
# NOTE: intentionally NO Procfile — verifies the default-web behaviour.

# The sbt 2.x layout: ${OUT} == $build/target/out
fake_bin="$build/target/out/native0.5/scala-3.8.4/cimdtest/cimdtest"

# Stub ./sbt emitting the EXACT sbt 2.x show notation (${OUT} + >sha256.../size).
# Single quotes keep ${OUT} literal, exactly as sbt prints it.
cat > "$build/sbt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$sbt_log"
case "\$*" in
  *"show"*"nativeLink"*)
    echo '[info] Build skipped: No changes detected in build configuration and class path contents since last build.'
    echo '[info] \${OUT}/native0.5/scala-3.8.4/cimdtest/cimdtest>sha256-e18d036e97c6fa67838c600a64b5fb53a1aab932a3b50baae0f345e6e9ac7bff/16261848'
    echo '[success] elapsed time: 0 s'
    ;;
  *nativeLink*)
    mkdir -p "$(dirname "$fake_bin")"
    # also drop object/IR files next to it that must NOT be mistaken for the binary
    mkdir -p "$(dirname "$fake_bin")/native"
    : > "$(dirname "$fake_bin")/native/foo.o"
    : > "$(dirname "$fake_bin")/native/foo.ll"
    printf '#!/bin/sh\necho cimdtest\n' > "$fake_bin"
    chmod +x "$fake_bin"
    echo '[success] elapsed time: 28 s'
    ;;
esac
exit 0
EOF
chmod +x "$build/sbt"

echo "-----> bin/detect"
detected=$("$buildpack/bin/detect" "$build")
[[ $detected == *"Scala Native"* ]] || { echo "FAIL: detect did not report Scala Native"; exit 1; }
echo "       $detected"

echo "-----> bin/compile"
"$buildpack/bin/compile" "$build" "$cache" "$env_dir"

echo "-----> Verifying"
[[ -f $build/bin/cimdtest && -x $build/bin/cimdtest ]] \
  || { echo "FAIL: sbt 2.x binary not found/shipped as bin/cimdtest"; exit 1; }
echo "       bin/cimdtest shipped (sbt 2.x \${OUT} path resolved)"

# No Procfile was committed → none should be in the slug (default-web path).
[[ ! -e $build/Procfile ]] || { echo "FAIL: unexpected Procfile in slug"; exit 1; }
echo "       no Procfile in slug (as expected)"

# Slug is binary-only.
got=$(ls -A "$build" | sort)
[[ $got == "bin" ]] || { echo "FAIL: slug root not binary-only: $got"; exit 1; }
echo "       slug root contains only bin/"

echo "-----> bin/release (must default web to the binary)"
rel=$("$buildpack/bin/release" "$build")
echo "$rel" | sed 's/^/        /'
echo "$rel" | grep -q 'web: bin/cimdtest' \
  || { echo "FAIL: release did not default web to bin/cimdtest"; exit 1; }

echo "-----> OK (sbt 2.x form + default Procfile)"
