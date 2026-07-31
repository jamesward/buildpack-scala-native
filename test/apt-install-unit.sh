#!/usr/bin/env bash
# Unit tests for bin/util/apt-install.sh that need no apt/dpkg/clang.
# Covers package-list assembly (defaults + Aptfile + env, de-duplicated) and
# the guard paths of scala_native_apt_install (skip flag, clang-present, and
# the hard-fail when neither apt nor clang is available).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
buildpack=$(cd "$here/.." && pwd)
# shellcheck source=../bin/util/apt-install.sh
. "$buildpack/bin/util/apt-install.sh"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
check() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "  ok: $1"; pass=$((pass+1)); else
    echo "  FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; fail=$((fail+1)); fi
}

echo "== package assembly =="

# 1) defaults only
unset SCALA_NATIVE_APP_DIR SCALA_NATIVE_APT_PACKAGES 2>/dev/null || true
got=$(scala_native_apt_packages | tr '\n' ' ' | sed 's/ $//')
check "defaults" "clang g++ libunwind-dev zlib1g-dev libssl-dev" "$got"

# 2) Aptfile adds a package, dedups an existing one, ignores comments/:repo:/.deb
app="$work/app"; mkdir -p "$app"
cat > "$app/Aptfile" <<'EOF'
# extra native deps
libgc-dev
clang            # duplicate of a default -> deduped
:repo:deb http://example/ubuntu foo main
http://example/pkg.deb
EOF
got=$(SCALA_NATIVE_APP_DIR="$app" scala_native_apt_packages 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
check "Aptfile extras + dedup + ignore repo/.deb" \
  "clang g++ libunwind-dev zlib1g-dev libssl-dev libgc-dev" "$got"

# 3) env var extras appended
got=$(SCALA_NATIVE_APT_PACKAGES="cmake libpq-dev" scala_native_apt_packages | tr '\n' ' ' | sed 's/ $//')
check "env var extras" \
  "clang g++ libunwind-dev zlib1g-dev libssl-dev cmake libpq-dev" "$got"

# 4) defaults override
got=$(scala_native_apt_packages "clang libunwind-dev" | tr '\n' ' ' | sed 's/ $//')
check "explicit defaults arg" "clang libunwind-dev" "$got"

echo "== install guards =="

# 5) skip flag short-circuits
out=$(SCALA_NATIVE_SKIP_APT=1 scala_native_apt_install "$work/a" "$work/c" 2>&1); rc=$?
check "skip flag returns 0" "0" "$rc"
echo "$out" | grep -q "skipping apt" && echo "  ok: skip message" || { echo "  FAIL: no skip message"; fail=$((fail+1)); }

# 6) no apt-get but clang present -> use existing toolchain (rc 0)
fakebin="$work/fakebin"; mkdir -p "$fakebin"
printf '#!/bin/sh\necho "clang version 99"\n' > "$fakebin/clang"; chmod +x "$fakebin/clang"
if command -v apt-get >/dev/null 2>&1; then
  echo "  skip: apt-get present on this host, can't exercise the no-apt path"
else
  out=$(PATH="$fakebin:$PATH" scala_native_apt_install "$work/a" "$work/c" 2>&1); rc=$?
  check "no apt + clang present returns 0" "0" "$rc"
  echo "$out" | grep -q "using existing toolchain" && echo "  ok: existing-toolchain message" \
    || { echo "  FAIL: wrong message"; fail=$((fail+1)); }

  # 7) no apt + no clang -> hard fail (rc 1). Clear PATH inside a subshell; the
  # sourced functions remain in scope and use only shell builtins (command -v).
  set +e
  out=$( PATH="/nonexistent-xyz"; hash -r 2>/dev/null; \
         scala_native_apt_install "$work/a" "$work/c" 2>&1 )
  rc=$?
  set -e
  check "no apt + no clang returns non-zero" "1" "$rc"
fi

echo
echo "results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
echo "OK"
