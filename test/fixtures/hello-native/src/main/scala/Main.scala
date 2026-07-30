// A tiny Scala Native program. When run on Heroku it reads the PORT the
// platform assigns and prints a banner; a real web app would open a socket
// on that port. Kept minimal so the smoke test's `nativeLink` is fast.
@main def run(): Unit =
  val port = Option(System.getenv("PORT")).getOrElse("8080")
  println(s"hello-native starting (would bind port $port)")
