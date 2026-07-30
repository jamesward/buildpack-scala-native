// Minimal Scala Native sample app used by the buildpack smoke tests.
// The Scala Native plugin (added in project/plugins.sbt) provides the
// `nativeLink` task that ahead-of-time compiles this app to a native binary.
scalaVersion := "3.3.4"

// `name` drives the produced binary name: target/scala-3.3.4/<name>-out
name := "hello-native"

enablePlugins(ScalaNativePlugin)

// Keep the build lean and predictable for CI images.
import scala.scalanative.build._
nativeConfig ~= { c =>
  c.withLTO(LTO.none)
    .withMode(Mode.debug)
    .withGC(GC.immix)
}

// A native test framework so `./sbt test` (used by bin/test) has something to
// run. munit publishes a Scala Native artifact (note the %%% cross-suffix).
libraryDependencies += "org.scalameta" %%% "munit" % "1.0.2" % Test
