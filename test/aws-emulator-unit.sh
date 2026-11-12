#!/usr/bin/env bash
# Unit tests for bin/util/aws-emulator.sh with a stub Debian package (no network): opt-in detection, URL selection,
# installation into the slug, the .profile.d script, and the cached-package fallback.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
buildpack=$(cd "$here/.." && pwd)
# shellcheck source=../bin/util/aws-emulator.sh
. "$buildpack/bin/util/aws-emulator.sh"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
pass=0; fail=0
check() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "  ok: $1"; pass=$((pass+1)); else
    echo "  FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; fail=$((fail+1)); fi
}

deb=$("$here/make-aws-emulator-deb.sh" "$work/pkg")
unset AWS_EMULATOR_PACKAGE_URL

echo "== package URL =="
app="$work/app"; mkdir -p "$app"
check "no marker: not installed" "" "$(aws_emulator_package_url "$app")"
touch "$app/.aws-emulator"
case "$(uname -m)" in x86_64) arch=amd64 ;; *) arch=arm64 ;; esac
check "empty marker: latest LTS" \
  "https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_${arch}.deb" "$(aws_emulator_package_url "$app")"
printf '# pinned\n  https://example.com/aws-emulator.deb  \n' > "$app/.aws-emulator"
check "marker names the package" "https://example.com/aws-emulator.deb" "$(aws_emulator_package_url "$app")"
check "config var wins" "file:///x.deb" "$(AWS_EMULATOR_PACKAGE_URL=file:///x.deb aws_emulator_package_url "$app")"

echo "== install =="
echo "file://$deb" > "$app/.aws-emulator"
slug="$work/slug"; cache="$work/cache"; mkdir -p "$slug" "$cache"
aws_emulator_install "$app" "$slug" "$cache" >/dev/null
check "binary installed" "aws-emulator 0.0.0-stub" "$("$slug/aws-emulator/bin/aws-emulator" -v)"
check "licenses installed" "yes" "$([[ -f $slug/aws-emulator/THIRD_PARTY_LICENSES ]] && echo yes || echo no)"
got=$(HOME="$slug" AWS_EMULATOR_BIN='' bash -c 'unset AWS_EMULATOR_BIN; . "$HOME/.profile.d/aws-emulator.sh"; echo "$AWS_EMULATOR_BIN"; command -v aws-emulator')
check "profile.d sets AWS_EMULATOR_BIN and PATH" "$slug/aws-emulator/bin/aws-emulator
$slug/aws-emulator/bin/aws-emulator" "$got"
got=$(HOME="$slug" AWS_EMULATOR_BIN=/custom bash -c '. "$HOME/.profile.d/aws-emulator.sh"; echo "$AWS_EMULATOR_BIN"')
check "profile.d keeps an AWS_EMULATOR_BIN override" "/custom" "$got"

echo "== cache =="
rm -f "$deb"
slug2="$work/slug2"; mkdir -p "$slug2"
aws_emulator_install "$app" "$slug2" "$cache" >/dev/null 2>"$work/err"
check "cached package used when the download fails" "aws-emulator 0.0.0-stub" "$("$slug2/aws-emulator/bin/aws-emulator" -v)"
grep -q "using the cached" "$work/err" && { echo "  ok: warned about the cache"; pass=$((pass+1)); } || { echo "  FAIL: no cache warning"; fail=$((fail+1)); }
rm -rf "$cache"
if aws_emulator_install "$app" "$work/slug3" "$cache" >/dev/null 2>&1; then
  echo "  FAIL: install without package or cache succeeded"; fail=$((fail+1))
else
  echo "  ok: fails without a package or cache"; pass=$((pass+1))
fi

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
