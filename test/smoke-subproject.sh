#!/usr/bin/env bash
# Verify bin/compile honours SBT_PROJECT for multi-project Scala Native builds:
# every sbt invocation is scoped to "<project>/...", the produced binary comes
# from that subproject, and the subproject's own Procfile is shipped. Uses a
# stub ./sbt so no real multi-project build (or toolchain) is required.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
buildpack=$(cd "$here/.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
build="$work/build"
cache="$work/cache"
env_dir="$work/env"
log="$work/sbt-stub.log"

# scala-native writes the subproject binary under <subproject>/target/...
fake_bin="$build/cli/target/scala-3.3.4/cli-app-out"
fake_base="$build/cli"
mkdir -p "$build/project" "$cache" "$env_dir" "$fake_base"

# Minimal project so bin/detect succeeds (build.sbt + ./sbt + scala-native plugin)
touch "$build/build.sbt"
echo 'addSbtPlugin("org.scala-native" % "sbt-scala-native" % "0.5.8")' > "$build/project/plugins.sbt"

# The subproject ships its own Procfile; a repo-root one must be ignored.
echo -n "web: bin/cli-app" > "$fake_base/Procfile"
echo -n "web: bin/should-not-be-used" > "$build/Procfile"

# Stub ./sbt: record args, fake the scoped nativeLink + show + baseDirectory.
cat > "$build/sbt" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *baseDirectory*)
    echo "[info] $fake_base"
    ;;
  *"show"*"nativeLink"*)
    echo "[info] $fake_bin"
    ;;
  *nativeLink*)
    mkdir -p "$(dirname "$fake_bin")"
    printf '#!/bin/sh\necho cli-app\n' > "$fake_bin"
    chmod +x "$fake_bin"
    ;;
esac
exit 0
EOF
chmod +x "$build/sbt"

# Pass SBT_PROJECT through Heroku-style ENV_DIR (one file per config var)
echo -n "cli" > "$env_dir/SBT_PROJECT"

"$buildpack/bin/compile" "$build" "$cache" "$env_dir" >/dev/null 2>&1 \
  || { echo "FAIL: bin/compile exited non-zero"; exit 1; }

echo "sbt invocations recorded:"
nl -ba "$log" | sed 's/^/  /'
echo

grep -qx 'cli/nativeLink' "$log" \
  || { echo "FAIL: did not see 'cli/nativeLink' in sbt args"; exit 1; }

grep -q 'show cli / Compile / nativeLink' "$log" \
  || { echo "FAIL: did not see scoped nativeLink show command"; exit 1; }

grep -q 'show cli / baseDirectory' "$log" \
  || { echo "FAIL: did not see scoped baseDirectory query"; exit 1; }

# The binary (named after the produced file, -out stripped) must be shipped.
[[ -f $build/bin/cli-app && -x $build/bin/cli-app ]] \
  || { echo "FAIL: slug missing executable bin/cli-app"; exit 1; }

# The subproject's Procfile must win.
[[ -f $build/Procfile ]] || { echo "FAIL: no Procfile in slug"; exit 1; }
got=$(cat "$build/Procfile")
[[ $got == "web: bin/cli-app" ]] \
  || { echo "FAIL: slug Procfile is '$got', expected the subproject's 'web: bin/cli-app'"; exit 1; }

# Binary-only: no source survived.
for forbidden in build.sbt sbt project cli target; do
  [[ -e "$build/$forbidden" ]] \
    && { echo "FAIL: slug still contains '$forbidden' (should be binary-only)"; exit 1; }
done

echo "OK: bin/compile scoped every sbt call to SBT_PROJECT=cli"
echo "OK: shipped the subproject's binary (bin/cli-app) and its Procfile, source dropped"
