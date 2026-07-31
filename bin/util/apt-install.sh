# bin/util/apt-install.sh
# Sourced by bin/compile and bin/test-compile.
#
# Installs the Scala Native *build* toolchain (clang/LLVM + native link libs)
# directly, so apps do NOT need to chain the heroku-community/apt buildpack or
# maintain an Aptfile. It reproduces that buildpack's proven non-root technique:
# download .debs (plus dependencies) into a cache with a private apt state dir,
# extract them with `dpkg -x` into a `.apt` prefix, and export the compiler /
# header / library search-path env vars so the subsequent `./sbt nativeLink`
# finds clang and the native headers/libs.
#
# Nothing installed here reaches the runtime slug on a deploy: bin/compile
# rewrites the slug down to just the native binary. The shared libraries the
# binary links (libssl, libz, libunwind, ...) are provided by the Heroku stack
# image at run time.
#
# Defines:
#   scala_native_apt_install <apt_root> <cache_dir> [profile_dir]
#     <apt_root>    where to extract packages (e.g. $BUILD_DIR/.apt)
#     <cache_dir>   persistent cache for downloaded .debs + apt state
#     [profile_dir] optional; if given, a .profile.d script is written there so
#                   a later runtime dyno (Heroku CI test dyno) also gets clang
#                   on PATH. Omit for deploy builds (binary-only slug).
#
# Packages installed = a sensible default toolchain, plus any extras the app
# lists in an optional `Aptfile` (same format as heroku-community/apt, minus
# the `:repo:`/`*.deb` line types) or in the SCALA_NATIVE_APT_PACKAGES env var.
# The default set can be replaced wholesale via SCALA_NATIVE_APT_DEFAULTS.

# shellcheck shell=bash

_sn_status() { echo "-----> $*"; }
_sn_warn()   { echo " !     $*" >&2; }

# Default build toolchain for a Scala Native (immix GC) app that may use TLS.
# clang/clang++ (compiler+linker driver), g++ (C++ stdlib headers), libunwind
# (exception unwinding), zlib (java.util.zip), OpenSSL (common TLS shim dep).
SCALA_NATIVE_APT_DEFAULT_PACKAGES="clang g++ libunwind-dev zlib1g-dev libssl-dev"

# scala_native_apt_packages [defaults]
#   Prints the resolved apt package list, one per line, de-duplicated in order:
#     <defaults> + <app SCALA_NATIVE_APP_DIR/Aptfile> + <SCALA_NATIVE_APT_PACKAGES>
#   Aptfile lines: `#` comments and blanks ignored; `:repo:`/`*.deb` line types
#   (from heroku-community/apt) are unsupported and skipped with a warning.
scala_native_apt_packages() {
  local defaults="${1:-$SCALA_NATIVE_APT_DEFAULT_PACKAGES}"
  local app_dir="${SCALA_NATIVE_APP_DIR:-}"
  local -a packages=()
  # shellcheck disable=SC2206
  packages+=($defaults)

  if [[ -n $app_dir && -f "$app_dir/Aptfile" ]]; then
    local line
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line%%#*}"
      line="$(echo "$line" | tr -d '[:space:]')"
      [[ -n $line ]] || continue
      case "$line" in
        :repo:*|*.deb) _sn_warn "Aptfile: ignoring unsupported line '$line'"; continue ;;
      esac
      packages+=("$line")
    done < "$app_dir/Aptfile"
  fi

  if [[ -n ${SCALA_NATIVE_APT_PACKAGES:-} ]]; then
    # shellcheck disable=SC2206
    packages+=(${SCALA_NATIVE_APT_PACKAGES})
  fi

  # De-duplicate, preserving first-seen order.
  local -a seen=()
  local p q dup
  for p in "${packages[@]}"; do
    dup=0
    for q in "${seen[@]}"; do [[ $q == "$p" ]] && { dup=1; break; }; done
    if [[ $dup -eq 0 ]]; then seen+=("$p"); printf '%s\n' "$p"; fi
  done
}

scala_native_apt_install() {
  local apt_root=${1:-}
  local cache_dir=${2:-}
  local profile_dir=${3:-}
  local app_dir="${SCALA_NATIVE_APP_DIR:-}"

  if [[ -z $apt_root || -z $cache_dir ]]; then
    _sn_warn "scala_native_apt_install: <apt_root> and <cache_dir> are required"
    return 1
  fi

  # If we can't (or needn't) drive apt, skip gracefully. This keeps the
  # buildpack usable in environments where the toolchain is already present
  # (e.g. a Nix shell, or a custom stack image) and on non-Debian systems.
  if [[ -n ${SCALA_NATIVE_SKIP_APT:-} ]]; then
    _sn_status "SCALA_NATIVE_SKIP_APT set — skipping apt toolchain install"
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    if command -v clang >/dev/null 2>&1; then
      _sn_status "apt-get not available but clang is on PATH — using existing toolchain"
      return 0
    fi
    _sn_warn "apt-get/dpkg not available and no clang on PATH; cannot provision the"
    _sn_warn "Scala Native toolchain. On Heroku this buildpack must run on an"
    _sn_warn "Ubuntu-based stack (heroku-24/heroku-26)."
    return 1
  fi

  # ---- assemble the package list --------------------------------------------
  local defaults="${SCALA_NATIVE_APT_DEFAULTS:-$SCALA_NATIVE_APT_DEFAULT_PACKAGES}"
  local -a pkgs=()
  # shellcheck disable=SC2207
  IFS=$'\n' read -r -d '' -a pkgs < <(scala_native_apt_packages "$defaults"; printf '\0')

  _sn_status "Provisioning Scala Native build toolchain via apt: ${pkgs[*]}"

  # ---- apt working dirs (cached across builds) ------------------------------
  local apt_cache="$cache_dir/apt/cache"
  local apt_state="$cache_dir/apt/state"
  local apt_srcs_dir="$cache_dir/apt/sources"
  local apt_srcparts="$apt_srcs_dir/sources.list.d"
  local apt_sources="$apt_srcs_dir/sources.list"
  local stack_file="$cache_dir/apt/STACK"
  local pkgs_file="$cache_dir/apt/Packages"

  local cached_stack=""
  [[ -f $stack_file ]] && cached_stack=$(cat "$stack_file")

  # Cache is valid only if BOTH the requested package set and the STACK are
  # unchanged; otherwise flush and re-seed the apt sources.
  if [[ -f $pkgs_file ]] && [[ "$(cat "$pkgs_file")" == "${pkgs[*]}" ]] \
     && [[ "$cached_stack" == "${STACK:-}" ]]; then
    _sn_status "Reusing cached apt download"
  else
    _sn_status "apt cache miss (packages or stack changed) — refreshing"
    rm -rf "$cache_dir/apt"
    mkdir -p "$apt_cache/archives/partial" "$apt_state/lists/partial" "$apt_srcparts"
    # Seed sources from the build image so we resolve against the stack's repos.
    if [[ -f /etc/apt/sources.list ]]; then
      cat /etc/apt/sources.list > "$apt_sources"
    else
      : > "$apt_sources"
    fi
    if [[ -d /etc/apt/sources.list.d ]]; then
      cp -R /etc/apt/sources.list.d/. "$apt_srcparts/" 2>/dev/null || true
    fi
  fi
  mkdir -p "$cache_dir/apt"
  echo "${STACK:-}"   > "$stack_file"
  echo "${pkgs[*]}"   > "$pkgs_file"

  local apt_version apt_force
  apt_version=$(apt-get -v | awk 'NR==1{print $2}')
  case "$apt_version" in
    0*|1.0*) apt_force=(--force-yes) ;;
    *)       apt_force=(--allow-downgrades --allow-remove-essential --allow-change-held-packages) ;;
  esac

  local -a apt_opts=(
    -o debug::nolocking=true
    -o "dir::cache=$apt_cache"
    -o "dir::state=$apt_state"
    -o "dir::etc::sourcelist=$apt_sources"
    -o "dir::etc::sourceparts=$apt_srcparts"
  )

  _sn_status "Updating apt package index"
  apt-get "${apt_opts[@]}" update 2>&1 | sed 's/^/       /'

  _sn_status "Downloading .debs (with dependencies)"
  apt-get "${apt_opts[@]}" -y "${apt_force[@]}" -d install --reinstall "${pkgs[@]}" 2>&1 | sed 's/^/       /'

  # ---- extract ---------------------------------------------------------------
  mkdir -p "$apt_root"
  local deb
  for deb in "$apt_cache/archives/"*.deb; do
    [[ -e $deb ]] || continue
    dpkg -x "$deb" "$apt_root/"
  done

  # ---- export env for the current build (so ./sbt nativeLink sees clang) ----
  export PATH="$apt_root/usr/bin:$PATH"
  export LD_LIBRARY_PATH="$apt_root/usr/lib/x86_64-linux-gnu:$apt_root/usr/lib:${LD_LIBRARY_PATH:-}"
  export LIBRARY_PATH="$apt_root/usr/lib/x86_64-linux-gnu:$apt_root/usr/lib:${LIBRARY_PATH:-}"
  local inc="$apt_root/usr/include:$apt_root/usr/include/x86_64-linux-gnu"
  export CPATH="$inc:${CPATH:-}"
  export C_INCLUDE_PATH="$inc:${C_INCLUDE_PATH:-}"
  export CPLUS_INCLUDE_PATH="$inc:${CPLUS_INCLUDE_PATH:-}"
  export PKG_CONFIG_PATH="$apt_root/usr/lib/x86_64-linux-gnu/pkgconfig:$apt_root/usr/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

  # Rewrite pkg-config prefixes to point inside .apt.
  find "$apt_root" -type f -ipath '*/pkgconfig/*.pc' -print0 2>/dev/null \
    | xargs -0 --no-run-if-empty -n1 sed -i -e "s!^prefix=\(.*\)\$!prefix=$apt_root\1!g" 2>/dev/null || true

  # ---- optional runtime profile script (for Heroku CI test dynos) -----------
  # A deploy build omits this (the slug is binary-only). bin/test-compile passes
  # a profile_dir so the toolchain is on PATH when bin/test runs `./sbt test`.
  if [[ -n $profile_dir ]]; then
    mkdir -p "$profile_dir"
    cat > "$profile_dir/000_scala-native-apt.sh" <<'PROFILE'
export PATH="$HOME/.apt/usr/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.apt/usr/lib/x86_64-linux-gnu:$HOME/.apt/usr/lib:${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="$HOME/.apt/usr/lib/x86_64-linux-gnu:$HOME/.apt/usr/lib:${LIBRARY_PATH:-}"
export CPATH="$HOME/.apt/usr/include:$HOME/.apt/usr/include/x86_64-linux-gnu:${CPATH:-}"
export C_INCLUDE_PATH="$CPATH"
export CPLUS_INCLUDE_PATH="$CPATH"
export PKG_CONFIG_PATH="$HOME/.apt/usr/lib/x86_64-linux-gnu/pkgconfig:$HOME/.apt/usr/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
PROFILE
  fi

  if command -v clang >/dev/null 2>&1; then
    _sn_status "Toolchain ready: $(command -v clang) ($(clang --version | head -1))"
  else
    _sn_warn "clang not found on PATH after apt install — the nativeLink build will likely fail"
  fi
}
