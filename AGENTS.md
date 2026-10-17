# AGENTS.md: buildpack-scala-native

Classic Heroku buildpack (bash) for Scala Native apps: runs `./sbt nativeLink` and ships the single native binary as the slug. Used in production by `cimdapp` (cimd.now), chained after `heroku/jvm`.

## Skills

Follow the `zen-of-projects` Skill (its "Heroku Buildpack Projects" section); this file records only project facts and exceptions. For design and testing strategy, follow `zen-of-james`. There's no Skills dependency (bash has no SkillsJars): `.factory/MAINTENANCE.md` reads the Skills from a clone of https://github.com/jamesward/skills.

## MCP

None.

## Build & test

Full validation (CI runs the same):

```bash
shellcheck -x --severity=warning bin/detect bin/compile bin/release bin/test bin/test-compile bin/util/*.sh
./test/smoke-stub.sh && ./test/smoke-sbt2-stub.sh && ./test/smoke-subproject.sh && ./test/apt-install-unit.sh
```

`./test/smoke.sh` is the real end-to-end test: it needs a JDK, sbt and the LLVM/clang toolchain, and skips when they're missing. It isn't in CI.

## Production

Every push to `main` is what `cimdapp` builds with on its next deploy. Changes under `bin/` need a human (`needs-human`); CI, test and doc changes follow the normal merge policy.

## Maintenance routine

`.factory/MAINTENANCE.md` (weekly), following the `zen-of-projects` Skill.
