#!/usr/bin/env bash
# Regenerate all sample badges in docs/badges/ from a running shieldcn server.
# Usage: ./tools/regen_badges.sh [port] (default port 5364)
set -euo pipefail

PORT="${1:-5364}"
BASE="http://localhost:${PORT}"
OUT="docs/badges"
mkdir -p "$OUT"

fetch() {
  local url="$1"
  local file="$2"
  curl -sf "${BASE}${url}" -o "${OUT}/${file}" && echo "  ✓ ${file}" || echo "  ✗ ${file} (FAILED)"
}

echo "Regenerating sample badges from ${BASE}..."

# --- Static badges ---
fetch "/badge/build-passing-green.svg" "build-passing-green.svg"
fetch "/badge/build-passing-green.json" "build-passing-green.json"
fetch "/badge/license-MIT-orange.svg" "license-MIT-orange.svg"
fetch "/badge/coverage-92%25-blue.svg" "coverage-92%25-blue.svg"
fetch "/badge/version-1.0.0-blueviolet.svg" "version-1.0.0-blueviolet.svg"

# --- Feature badges (static with custom color) ---
fetch "/badge/pure%20zig-v0.16.0-18181b.svg" "pure-zig.svg"
fetch "/badge/airgap-ready-18181b.svg" "airgap-ready.svg"
fetch "/badge/offline-18181b.svg" "offline-mode.svg"
fetch "/badge/SLSA-Level%203-18181b.svg" "slsa-level-3.svg"
fetch "/badge/multi--arch-amd64%20%7C%20aarch64-18181b.svg" "multi-arch.svg"
fetch "/badge/dagger-powered-18181b.svg" "dagger-powered.svg"
fetch "/badge/ckodex-compliant-18181b.svg" "ckodex-compliant.svg"
fetch "/badge/sigstore-signed-18181b.svg" "sigstore-signed.svg"

# --- GitHub provider badges (live data) ---
fetch "/github/stars/MChorfa/shieldcn-zig.svg" "github-stars.svg"
fetch "/github/forks/MChorfa/shieldcn-zig.svg" "github-forks.svg"
fetch "/github/issues/MChorfa/shieldcn-zig.svg" "github-issues.svg"
fetch "/github/contributors/MChorfa/shieldcn-zig.svg" "github-contributors.svg"
fetch "/github/license/MChorfa/shieldcn-zig.svg" "license-MIT-orange.svg"

# --- Variants ---
fetch "/badge/build-passing-green.svg?variant=default" "var-default.svg"
fetch "/badge/build-passing-green.svg?variant=secondary" "var-secondary.svg"
fetch "/badge/build-passing-green.svg?variant=outline" "var-outline.svg"
fetch "/badge/build-passing-green.svg?variant=ghost" "var-ghost.svg"
fetch "/badge/build-passing-green.svg?variant=destructive" "var-destructive.svg"
fetch "/badge/build-passing-green.svg?variant=branded" "var-branded.svg"

# --- Colors ---
fetch "/badge/build-passing-green.svg" "color-green.svg"
fetch "/badge/build-failing-red.svg" "color-red.svg"
fetch "/badge/build-pending-yellow.svg" "color-yellow.svg"
fetch "/badge/coverage-92%25-blue.svg" "color-blue.svg"
fetch "/badge/version-1.0.0-blueviolet.svg" "color-blueviolet.svg"
fetch "/badge/license-MIT-orange.svg" "color-orange.svg"

# --- Custom colors ---
fetch "/badge/build-passing-green.svg?color=%23ff00ff" "custom-color.svg"
fetch "/badge/build-passing-green.svg?labelColor=%230000ff" "custom-label-color.svg"
fetch "/badge/build-passing-green.svg?valueColor=%23ffffff" "custom-value-color.svg"
fetch "/badge/build-passing-green.svg?label=CI" "custom-label.svg"

# --- Sizes ---
fetch "/badge/build-passing-green.svg?size=xs" "size-xs.svg"
fetch "/badge/build-passing-green.svg?size=sm" "size-sm.svg"
fetch "/badge/build-passing-green.svg?size=default" "size-default.svg"
fetch "/badge/build-passing-green.svg?size=lg" "size-lg.svg"

# --- Modes / Themes ---
fetch "/badge/build-passing-green.svg?mode=dark" "mode-dark.svg"
fetch "/badge/build-passing-green.svg?mode=light" "mode-light.svg"
fetch "/badge/build-passing-green.svg?theme=dark" "theme-dark.svg"
fetch "/badge/build-passing-green.svg?theme=light" "theme-light.svg"
fetch "/badge/build-passing-green.svg?theme=high-contrast" "theme-high-contrast.svg"

# --- Fonts ---
fetch "/badge/build-passing-green.svg?font=inter" "font-inter.svg"
fetch "/badge/build-passing-green.svg?font=geist" "font-geist.svg"
fetch "/badge/build-passing-green.svg?font=geist-mono" "font-geist-mono.svg"

# --- Layout options ---
fetch "/badge/build-passing-green.svg?split=true" "split.svg"
fetch "/badge/build-passing-green.svg?statusDot=true" "status-dot.svg"
fetch "/badge/build-passing-green.svg?gradient=blue" "gradient.svg"

# --- WCAG 3.0 ---
fetch "/badge/build-passing-green.svg?wcag=3" "wcag3-green.svg"
fetch "/badge/build-failing-red.svg?wcag=3" "wcag3-red.svg"
fetch "/badge/build-pending-yellow.svg?wcag=3" "wcag3-yellow.svg"
fetch "/badge/coverage-92%25-blue.svg?wcag=3" "wcag3-blue.svg"
fetch "/badge/version-1.0.0-blueviolet.svg?wcag=3" "wcag3-purple.svg"
fetch "/badge/license-MIT-orange.svg?wcag=3" "wcag3-orange.svg"
fetch "/badge/build-passing-gray.svg?wcag=3" "wcag3-gray.svg"

# --- Group badges ---
fetch "/group/build-passing-green%7Ccoverage-92%25-blue.svg" "group-2.svg"
fetch "/group/build-passing-green%7Ccoverage-92%25-blue%7Clicense-MIT-orange.svg" "group-3.svg"

# --- JSON sample ---
fetch "/badge/build-passing-green.json" "json-sample.json"

# --- Health ---
fetch "/health.json" "health.json"

echo "Done."
