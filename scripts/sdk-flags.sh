#!/bin/bash
# Prints the extra flags every `swift build` / `swift test` / `swift run`
# in this repo must carry. Usage: swift build $(./scripts/sdk-flags.sh)
#
# Xcode 27's toolchain stamps the Mach-O LC_BUILD_VERSION "sdk" field
# with the DEPLOYMENT target (13.0) instead of the SDK it compiled
# against — the compiler still gets `-target-sdk-version 27.0`, the
# linker doesn't. macOS reads that field for its linked-on-or-after
# checks, and a binary marked "sdk 13.0" is treated as a pre-Liquid-Glass
# app: on macOS 26 and 27 its toolbar renders in the compatibility look
# (bare items on the bar, no capsules, no grouping). Verified 2026-09-22
# on macOS 27.0 against the shipped 0.44.2 (built by the 26.6 tools:
# "sdk 26.5", capsules) and a fresh build ("sdk 13.0", flat), and a
# deployment-target-13 probe flipped between the two looks on this flag
# alone. Passing the platform version to the linker explicitly restores
# the real SDK version; ld neither warns nor duplicates it.
#
# The deployment target here must match Package.swift's platforms and
# make-app.sh's --minimum-deployment-target. `xcrun --show-sdk-version`
# honors SDKROOT, so a pinned SDK stamps its own version.
set -euo pipefail
DEPLOYMENT_TARGET=13.0
sdk_version=$(xcrun --show-sdk-version 2>/dev/null) || {
  echo "sdk-flags: xcrun could not report an SDK version; building without the platform stamp" >&2
  exit 0
}
echo "-Xlinker -platform_version -Xlinker macos -Xlinker ${DEPLOYMENT_TARGET} -Xlinker ${sdk_version}"
