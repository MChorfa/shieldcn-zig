#!/usr/bin/env bash
# Air-gap build script — builds shieldcn with zero network access.
# Uses vendored dependencies from zig-pkg/ (committed to the repo).
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Building shieldcn in air-gap mode (no network)..."
zig build --system zig-pkg "$@"
echo "Build complete. Binary: zig-out/bin/shieldcn"
