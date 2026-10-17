#!/usr/bin/env bash
# The stub smoke test with ./sbta (https://github.com/jamesward/sbta) as the project's only
# launcher instead of ./sbt: detect, compile and the slug checks must all work with it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
LAUNCHER=sbta exec "$here/smoke-stub.sh"
