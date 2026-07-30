# bin/util/sbt-env.sh
# Sourced by bin/compile, bin/test-compile, bin/test.
#
# Defines:
#   sbt_env_configure <cache-root>
#       Sets COURSIER_CACHE and SBT_OPTS so subsequent `./sbt` invocations
#       use <cache-root>/{coursier,ivy2,sbt}/... for resolution and the sbt
#       launcher boot dir. <cache-root> is created if missing.
#
# The choice of <cache-root> determines the lifetime of the cache:
#   * bin/compile:       CACHE_DIR        (persists between deploys)
#   * bin/test-compile:  BUILD_DIR/.heroku-sbt-cache (in the test slug, so
#                                                    bin/test can read it)
#   * bin/test:          BUILD_DIR/.heroku-sbt-cache (same dir, populated
#                                                    by test-compile)
#
# Scala Native note: this only caches the *JVM-side* sbt/Coursier/Ivy state
# (the sbt launcher, plugins, and resolved jars). The Scala Native toolchain's
# own working files live under the project's `target/` tree and are not part
# of this cache; a persistent `target/` between deploys is neither guaranteed
# nor relied upon.

# shellcheck shell=bash

sbt_env_configure() {
  local cache_root=${1:-}
  if [[ -z $cache_root ]]; then
    echo "sbt_env_configure: cache root path required" >&2
    return 1
  fi

  local coursier_cache="$cache_root/coursier/v1"
  local ivy_home="$cache_root/ivy2"
  local sbt_boot="$cache_root/sbt/boot"
  local sbt_global="$cache_root/sbt"

  mkdir -p "$coursier_cache" "$ivy_home" "$sbt_boot" "$sbt_global"

  export COURSIER_CACHE="$coursier_cache"
  export SBT_OPTS="${SBT_OPTS:-} -Dsbt.boot.directory=$sbt_boot -Dsbt.global.base=$sbt_global -Dsbt.ivy.home=$ivy_home -Divy.home=$ivy_home"
}
