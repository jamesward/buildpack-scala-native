#!/usr/bin/env bash
# Optionally ships the AWS Emulator (https://github.com/aws/aws-emulator) in the slug next to the native binary.
#
# Opt in with a `.aws-emulator` file at the app's repository root. Its first non-comment line, if any, is the URL of
# the Debian package to install; without one the latest LTS package for the build machine's architecture is used.
# The `AWS_EMULATOR_PACKAGE_URL` config var overrides both.
#
# Result in the slug:
#   aws-emulator/bin/aws-emulator      the emulator executable (statically linked apart from libc)
#   aws-emulator/THIRD_PARTY_LICENSES
#   .profile.d/aws-emulator.sh         puts it on PATH and sets AWS_EMULATOR_BIN at dyno start
#
# The package is cached in CACHE_DIR and re-downloaded only when the server has a newer one; when the download fails
# a cached package is used with a warning.

_aws_emu_status() { echo "-----> $*"; }
_aws_emu_warn()   { echo " !     $*" >&2; }

# aws_emulator_package_url <app_dir>: prints the package URL to install, or nothing when the app has not opted in.
aws_emulator_package_url() {
  local app_dir=$1 marker="$1/.aws-emulator" line arch
  [[ -f $marker ]] || return 0
  if [[ -n ${AWS_EMULATOR_PACKAGE_URL:-} ]]; then
    echo "$AWS_EMULATOR_PACKAGE_URL"
    return 0
  fi
  line=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$marker" | grep -m1 . || true)
  if [[ -n $line ]]; then
    echo "$line"
    return 0
  fi
  case "$(uname -m)" in
    x86_64)        arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) _aws_emu_warn "unsupported architecture for the AWS Emulator: $(uname -m)"; return 1 ;;
  esac
  echo "https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest/aws-emulator_${arch}.deb"
}

# aws_emulator_install <app_dir> <slug_dir> <cache_dir>: installs the emulator into the slug when the app opted in.
aws_emulator_install() {
  local app_dir=$1 slug_dir=$2 cache_dir=$3 url cache deb tmp extract
  url=$(aws_emulator_package_url "$app_dir") || return 1
  [[ -n $url ]] || return 0

  cache="$cache_dir/aws-emulator"
  deb="$cache/aws-emulator.deb"
  mkdir -p "$cache"
  # A different URL invalidates the cached package.
  if [[ -f $cache/url && $(cat "$cache/url") != "$url" ]]; then rm -f "$deb"; fi

  _aws_emu_status "Downloading the AWS Emulator from $url"
  tmp="$cache/download.tmp"
  rm -f "$tmp"
  local -a since=()
  [[ -f $deb ]] && since=(-z "$deb")
  if curl -fsSL --retry 3 --retry-delay 5 -R "${since[@]}" -o "$tmp" "$url"; then
    if [[ -s $tmp ]]; then
      mv "$tmp" "$deb"
      echo "$url" > "$cache/url"
    else
      rm -f "$tmp"
      _aws_emu_status "Cached AWS Emulator package is current"
    fi
  elif [[ -f $deb ]]; then
    rm -f "$tmp"
    _aws_emu_warn "download failed; using the cached AWS Emulator package"
  else
    _aws_emu_warn "could not download the AWS Emulator package from $url"
    return 1
  fi

  extract=$(mktemp -d)
  if ! dpkg-deb -x "$deb" "$extract"; then
    rm -rf "$extract"
    _aws_emu_warn "could not extract $deb"
    return 1
  fi
  if [[ ! -x $extract/opt/aws-emulator/bin/aws-emulator ]]; then
    rm -rf "$extract"
    _aws_emu_warn "the package has no opt/aws-emulator/bin/aws-emulator"
    return 1
  fi

  rm -rf "$slug_dir/aws-emulator"
  cp -a "$extract/opt/aws-emulator" "$slug_dir/aws-emulator"
  rm -rf "$extract"

  mkdir -p "$slug_dir/.profile.d"
  cat > "$slug_dir/.profile.d/aws-emulator.sh" <<'EOF'
# Added by buildpack-scala-native: the AWS Emulator shipped in this slug.
export PATH="$HOME/aws-emulator/bin:$PATH"
export AWS_EMULATOR_BIN="${AWS_EMULATOR_BIN:-$HOME/aws-emulator/bin/aws-emulator}"
EOF

  _aws_emu_status "Installed $("$slug_dir/aws-emulator/bin/aws-emulator" -v 2>/dev/null | head -1 || echo "the AWS Emulator") at aws-emulator/bin/aws-emulator"
}
