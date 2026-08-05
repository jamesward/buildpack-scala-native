# buildpack-scala-native

A [classic Heroku buildpack](https://devcenter.heroku.com/articles/buildpack-api)
for [**Scala Native**](https://scala-native.org) apps built with sbt and the
[`sbt-scala-native`](https://github.com/scala-native/scala-native) plugin.

It runs `./sbt nativeLink` to **ahead-of-time compile the app to a native
executable**, then turns that single binary into the slug. The JVM (and the
LLVM/clang toolchain) are needed **only at build time** — the resulting slug
is a self-contained native binary that starts in milliseconds with no JVM at
runtime.

This is the sibling of [buildpack-scala](../buildpack-scala) (which packages a
JVM app via `sbt-native-packager`'s `stage`). The key differences are
summarized [below](#how-it-differs-from-the-jvm-buildpack-scala-buildpack).

## Requirements

- The app has a project-local `./sbt` wrapper at the repository root.
- The app enables the Scala Native plugin. Concretely, `project/plugins.sbt`
  contains:

  ```scala
  addSbtPlugin("org.scala-native" % "sbt-scala-native" % "0.5.8")
  ```

  and the target project calls `enablePlugins(ScalaNativePlugin)` in its
  `build.sbt`. The `nativeLink` task this provides is what the buildpack runs.
- A **JDK** is on `PATH` during the build (to run sbt). Chain
  [heroku/jvm](https://github.com/heroku/heroku-buildpack-jvm-common) before
  this buildpack.
- The **Scala Native build toolchain** (clang/LLVM + native link libs) is
  installed **by this buildpack itself** — you do *not* need the
  `heroku-community/apt` buildpack or an `Aptfile`. Before running
  `./sbt nativeLink`, `bin/compile` downloads and extracts a default toolchain
  via apt (into a throwaway `.apt` prefix that never reaches the slug):

  ```
  clang  g++  libunwind-dev  zlib1g-dev  libssl-dev  liburing-dev
  ```

  (`clang`/`g++` for the compiler + C++ headers, `libunwind` for exception
  unwinding, `zlib` for `java.util.zip`, `libssl-dev` for apps that link OpenSSL
  (e.g. `kyo-http`'s TLS shim), `liburing-dev` for apps that link io_uring
  (e.g. `kyo-net`'s io_uring shim). The default *immix* GC needs no `libgc`.)

  - Need **extra** native packages (e.g. a different GC's `libgc-dev`, a DB
    client lib, ...)? List them in an optional `Aptfile` at your repo root
    (plain package names, one per line — the `:repo:`/`*.deb` line types of
    heroku-community/apt are not supported) **or** set the
    `SCALA_NATIVE_APT_PACKAGES` config var (space-separated). These are added
    on top of the defaults.
  - Need to **replace** the default set entirely? Set `SCALA_NATIVE_APT_DEFAULTS`.
  - Toolchain already on the image (custom stack, or a base with clang)? Set
    `SCALA_NATIVE_SKIP_APT=1` to skip the apt step. (The step is also skipped
    automatically when `apt-get` is unavailable but `clang` is already on
    `PATH`.)

  So the buildpack chain is just:

  ```sh
  heroku buildpacks:add heroku/jvm
  heroku buildpacks:add https://github.com/jamesward/buildpack-scala-native
  ```

  Or, equivalently, in `app.json` (used by Heroku Button, Review Apps, and
  `heroku create --manifest`):

  ```json
  {
    "buildpacks": [
      { "url": "heroku/jvm" },
      { "url": "https://github.com/jamesward/buildpack-scala-native" }
    ]
  }
  ```

  Order matters: the JDK must be on `PATH` before `./sbt nativeLink` runs, so
  this buildpack must come **after** heroku/jvm.

  The shared libraries the finished binary links at run time (e.g. `libssl`,
  `libz`, `libunwind`) are provided by the Heroku stack image — nothing from
  the build-time `.apt` needs to ship in the slug.

## What the slug looks like

`bin/compile` replaces the build directory with **just the native binary and
your `Procfile`** — nothing else. The source tree, `./sbt`, `project/`,
`target/`, and any build-time JDK (`.jdk/` from heroku/jvm) are intentionally
dropped, because a Scala Native binary needs none of them at runtime:

```
.                      <-- slug root
├── bin/
│   └── <app-name>     # the native executable produced by `nativeLink`
└── Procfile           # preserved from your repo (if any)
```

The binary is placed at `bin/<app-name>` (any `-out` suffix scala-native adds
is stripped for a cleaner process name). Dropping everything else keeps the
slug tiny and makes the "no JVM at runtime" guarantee explicit.

## Procfile

Paths in your `Procfile` are relative to the slug root. For an app whose
`name := "hello-native"`, the binary lands at `bin/hello-native`, so:

```
web: bin/hello-native
```

If you omit the `Procfile`, the buildpack's `bin/release` step defaults the
`web` process to the executable it placed under `bin/`.

For **multi-project builds** (`SBT_PROJECT` set, see below) the `Procfile`
should live in the targeted subproject's directory; the buildpack reads it
from there and ships it at the slug root, falling back to a repo-root
`Procfile` if the subproject has none.

## How the binary path is derived

`bin/compile` runs sbt twice, in two separate invocations:

1. `./sbt nativeLink` — the Scala Native task that ahead-of-time compiles and
   links the app into a native executable. Its location depends on the sbt
   major version:
   - **sbt 1.x:** `target/scala-<version>/<name>` (older plugin releases used
     a `-out` suffix: `<name>-out`).
   - **sbt 2.x:** `target/out/native<abi>/scala-<version>/<proj>/<proj>`.
2. `./sbt 'show Compile / nativeLink'` — `nativeLink` is a `File`-typed task,
   so `show` prints its path. The printed form also differs by sbt version:
   - **sbt 1.x** prints an absolute path, e.g. `/app/target/scala-3.3.4/hello`.
   - **sbt 2.x** prints a *cached VirtualFile* reference, e.g.
     `${OUT}/native0.5/scala-3.8.4/hello/hello>sha256-<hash>/<size>`, where
     `${OUT}` is the build output dir (`<BUILD_DIR>/target/out`) and the
     trailing `>sha256-.../<size>` is a content hash, not part of the path.

The compile script understands both printed forms (resolving `${OUT}` against
`target/out`). If parsing ever fails, it falls back to scanning `target/` for
the freshly linked executable — covering both layouts and ignoring jars, object
/ IR files, and the intermediate `native/` and `classes/` dirs.

Two cold sbt boots (rather than a custom injected task) keeps the buildpack
robust across sbt/plugin versions — `nativeLink` and `show` are stable,
first-class commands.

## Multi-project builds (`SBT_PROJECT`)

If your repo is a multi-project sbt build and a non-root subproject is the one
whose `nativeLink` should drive the slug, set the `SBT_PROJECT` config var to
its sbt project ID:

```sh
heroku config:set SBT_PROJECT=cli
```

`bin/compile` will then issue:

1. `./sbt cli/nativeLink`
2. `./sbt 'show cli / Compile / nativeLink'`
3. `./sbt 'show cli / baseDirectory'`

instead of the unscoped versions. When `SBT_PROJECT` is unset the buildpack
uses sbt's current (root) project (and skips the third invocation — the
repo-root `Procfile` is used directly).

The third invocation locates the subproject's `Procfile`: its base directory
is asked of sbt rather than guessed from `SBT_PROJECT`, because a project's ID
need not match its directory name. The value must be a valid sbt project ID
(alphanumerics + underscores — no hyphens or dots).

## Caching

The following Coursier / Ivy / sbt directories are persisted in `CACHE_DIR`
between builds, so subsequent deploys do not re-download dependencies:

- `coursier/v1/` (Coursier cache, used by sbt for resolution)
- `ivy2/`        (Ivy home)
- `sbt/boot/`    (sbt launcher boot dir)
- `sbt/`         (sbt global base)

Note this caches only the **JVM-side** sbt state. The Scala Native toolchain's
own intermediate objects live under the project's `target/` tree and are not
part of this cache.

## Heroku CI

This buildpack supports the [Heroku CI testpack
API](https://devcenter.heroku.com/articles/testpack-api) via
`bin/test-compile` and `bin/test`. `bin/test-compile` runs `./sbt Test/compile`
(seeding an in-slug cache at `BUILD_DIR/.heroku-sbt-cache`), and `bin/test`
runs `./sbt test` — which, for a Scala Native project, compiles the tests to a
native test binary and runs it. Its exit code is the test result. `bin/test-compile`
installs the clang toolchain the same way `bin/compile` does (into `.apt`, kept
in the test slug with a `.profile.d` script so the parallel test dynos running
`bin/test` also have `clang` on `PATH`) — so no `heroku-community/apt` buildpack
is needed here either.

```json
{
  "environments": {
    "test": {
      "buildpacks": [
        { "url": "heroku/jvm" },
        { "url": "https://github.com/jamesward/buildpack-scala-native" }
      ]
    }
  }
}
```

## How it differs from the JVM buildpack-scala buildpack

| | buildpack-scala (JVM) | buildpack-scala-native (this one) |
|---|---|---|
| sbt task | `stage` (sbt-native-packager) | `nativeLink` (sbt-scala-native) |
| path query | `show Universal / stagingDirectory` | `show Compile / nativeLink` |
| build needs | JDK | JDK **+ clang/LLVM + native libs** |
| runtime needs | JDK (`.jdk/` preserved) | **nothing** — bare native binary |
| slug contents | `bin/`, `lib/*.jar`, `.jdk/`, Procfile | **only** `bin/<name>` + Procfile |
| detect signal | `build.sbt` + `./sbt` | `build.sbt` + `./sbt` + `sbt-scala-native` plugin |

## Local tests

Four test scripts live in `test/`:

- `test/smoke-stub.sh` — end-to-end `detect` → `compile` → `release` using a
  **stub** `./sbt` (fakes `nativeLink`, sbt 1.x-style absolute path). Runs
  anywhere; **needs no clang**. Asserts the slug is binary-only.
- `test/smoke-sbt2-stub.sh` — same flow but the stub reproduces sbt 2.x's
  `${OUT}/…>sha256-…/<size>` output and `target/out/native…` layout (the exact
  form the real Heroku build emits). Also checks the **default-Procfile** path.
  Needs no clang.
- `test/smoke-subproject.sh` — verifies `SBT_PROJECT` scoping with a stub
  `./sbt`. Needs no clang.
- `test/smoke.sh` — a **real** build: runs an actual `./sbt nativeLink`,
  asserts the produced binary is a native executable that runs, and that the
  slug is binary-only. It **SKIPs** (exit 0) if `sbt`/`java`/`clang` aren't on
  `PATH`; set `REQUIRE_TOOLCHAIN=1` to make a missing toolchain a hard failure.

```sh
./test/smoke-stub.sh
./test/smoke-sbt2-stub.sh
./test/smoke-subproject.sh

# real build — provide the toolchain however you like, e.g. via nix:
nix-shell -p sbt clang llvm boehmgc libunwind zlib which \
  --run 'REQUIRE_TOOLCHAIN=1 ./test/smoke.sh'
```

The `test/fixtures/hello-native` directory is a minimal Scala Native sample
(sbt 2.0.4, Scala 3.3.4, sbt-scala-native 0.5.12) used by the real build.

## Layout

```
buildpack-scala-native/
├── README.md
├── bin/
│   ├── detect        # succeed if build.sbt + ./sbt + scala-native plugin present
│   ├── compile       # ./sbt nativeLink, then rewrite BUILD_DIR as a binary-only slug
│   ├── release       # emit default_process_types from bin/<exec>
│   ├── test-compile  # ./sbt Test/compile, leave source tree intact for tests
│   ├── test          # ./sbt test (exit code = test result)
│   └── util/
│       ├── sbt-env.sh     # shared cache + SBT_OPTS setup
│       └── apt-install.sh # installs the clang/LLVM + native-lib toolchain
└── test/
    ├── smoke.sh             # real end-to-end build (needs clang/LLVM+sbt)
    ├── smoke-stub.sh        # end-to-end with a stub sbt (no toolchain needed)
    ├── smoke-sbt2-stub.sh   # sbt 2.x ${OUT} output + default-Procfile (stub sbt)
    ├── smoke-subproject.sh  # verifies SBT_PROJECT scoping (stub sbt)
    ├── apt-install-unit.sh  # unit tests for the apt toolchain installer
    └── fixtures/
        └── hello-native/    # minimal Scala Native sample app
```
