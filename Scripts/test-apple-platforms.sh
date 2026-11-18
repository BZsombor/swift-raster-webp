#!/usr/bin/env bash
#
# Runs the tests on an iOS Simulator and builds for the remaining Apple platforms.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Xcode names the package scheme differently depending on the package's products.
scheme="$(xcodebuild -list 2>/dev/null | sed -nE 's/^[[:space:]]+(swift-raster-webp(-Package)?)$/\1/p' | tail -1)"
readonly scheme

device="$(xcrun simctl list devices available | grep -m1 'iPhone' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
readonly device

xcodebuild test -quiet -scheme "${scheme}" -destination "platform=iOS Simulator,id=${device}"

for platform in tvOS watchOS visionOS; do
    xcodebuild build -quiet -scheme "${scheme}" -destination "generic/platform=${platform}"
done
