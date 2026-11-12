#!/usr/bin/env bash
# Builds a stub aws-emulator Debian package with the real package's layout and prints its path.
set -euo pipefail
dir=$1
root="$dir/root"
mkdir -p "$root/DEBIAN" "$root/opt/aws-emulator/bin"
cat > "$root/DEBIAN/control" <<'CONTROL'
Package: aws-emulator
Version: 0.0.0-stub
Architecture: all
Maintainer: test <test@example.com>
Description: stub AWS Emulator for buildpack tests
CONTROL
printf '#!/bin/sh\necho "aws-emulator 0.0.0-stub"\n' > "$root/opt/aws-emulator/bin/aws-emulator"
chmod +x "$root/opt/aws-emulator/bin/aws-emulator"
echo "stub licenses" > "$root/opt/aws-emulator/THIRD_PARTY_LICENSES"
dpkg-deb --build --root-owner-group "$root" "$dir/aws-emulator.deb" >/dev/null
echo "$dir/aws-emulator.deb"
