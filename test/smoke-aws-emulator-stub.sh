#!/usr/bin/env bash
# The stub smoke test for an app with a `.aws-emulator` file: the slug also holds the emulator and its .profile.d script.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
AWS_EMULATOR_STUB_DEB=$("$here/make-aws-emulator-deb.sh" "$work") "$here/smoke-stub.sh"
