# shieldcn-zig

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/header/graph.svg?title=shieldcn-zig&subtitle=Pure-Zig+badge+engine&logo=zig&theme=zinc&mode=dark" />
    <img alt="shieldcn-zig" src="https://shieldcn.dev/header/graph.svg?title=shieldcn-zig&subtitle=Pure-Zig+badge+engine&logo=zig&theme=zinc&mode=light" />
  </picture>
</p>

<p align="center">
  <a href="https://github.com/MChorfa/shieldcn-zig/stargazers"><img src="https://shieldcn.dev/github/stars/MChorfa/shieldcn-zig.svg?variant=secondary" alt="GitHub stars" /></a>
  <a href="https://github.com/MChorfa/shieldcn-zig/network/members"><img src="https://shieldcn.dev/github/forks/MChorfa/shieldcn-zig.svg?variant=secondary" alt="GitHub forks" /></a>
  <a href="https://github.com/MChorfa/shieldcn-zig/blob/main/LICENSE"><img src="https://shieldcn.dev/github/license/MChorfa/shieldcn-zig.svg?variant=secondary" alt="License" /></a>
  <a href="https://github.com/MChorfa/shieldcn-zig/actions/workflows/dagger.yaml"><img src="https://shieldcn.dev/github/ci/MChorfa/shieldcn-zig.svg?workflow=Dagger%20CI&branch=main&variant=secondary" alt="CI status" /></a>
  <a href="https://github.com/MChorfa/shieldcn-zig/commits/main"><img src="https://shieldcn.dev/github/last-commit/MChorfa/shieldcn-zig.svg?variant=secondary" alt="Last commit" /></a>
  <a href="https://github.com/MChorfa/shieldcn-zig/issues"><img src="https://shieldcn.dev/github/issues/MChorfa/shieldcn-zig.svg?variant=secondary" alt="Issues" /></a>
  <a href="https://github.com/MChorfa/shieldcn-zig/graphs/contributors"><img src="https://shieldcn.dev/github/contributors/MChorfa/shieldcn-zig.svg?variant=secondary" alt="Contributors" /></a>
</p>

<p align="center">
  <img src="https://shieldcn.dev/badge/pure%20zig-v0.16.0-18181b.svg?logo=zig&variant=secondary" alt="Pure Zig" />
  <img src="https://shieldcn.dev/badge/airgap-ready-18181b.svg?variant=secondary" alt="Airgap ready" />
  <img src="https://shieldcn.dev/badge/offline-18181b.svg?variant=secondary&logo=offline" alt="Offline mode" />
  <img src="https://shieldcn.dev/badge/SLSA-Level%203-18181b.svg?variant=secondary" alt="SLSA Level 3" />
  <img src="https://shieldcn.dev/badge/multi--arch-amd64%20%7C%20aarch64-18181b.svg?variant=secondary" alt="Multi-arch" />
  <img src="https://shieldcn.dev/badge/dagger-powered-18181b.svg?logo=dagger&variant=secondary" alt="Dagger powered" />
  <img src="https://shieldcn.dev/badge/sigstore-signed-18181b.svg?variant=secondary" alt="Sigstore signed" />
</p>

<p align="center"><strong>A clean-room, pure-Zig badge engine</strong> with SVG, PNG, and JSON output, six visual variants, and multi-provider support. Built for self-hosting and governed CI/CD.</p>

> **Note on compatibility.** This is an independent Zig reimplementation of the [shieldcn](https://github.com/jal-co/shieldcn) route surface. The HTTP routes (`/badge`, `/npm`, `/github`, `/gitlab`, `/group`, `/memo`) and query parameters (`variant`, `size`, `mode`, `theme`, `font`, `split`, `logo`, …) follow the shieldcn contract. The SVG output is structurally equivalent to shieldcn: text is vectorized as `<path>` glyphs (font-independent), the default surface is single-surface with shadcn tokens (`#fafafa`, `#18181b`, `fill-opacity=".7"`), and auto-icons are wired per provider/topic. The source font is SF Pro (vs Inter upstream), so glyph shapes differ slightly. See [Compatibility](#compatibility) below for details. The badges above are served by the upstream `shieldcn.dev` service so the README renders correctly everywhere.

## Table of Contents

- [Features](#features)
- [Quickstart](#quickstart)
- [Usage](#usage)
- [Providers](#providers)
- [Dagger CI/CD](#dagger-cicd)
- [Architecture](#architecture)
- [Security & Compliance](#security--compliance)
- [Compatibility](#compatibility)
- [License](#license)

## Features

| Feature | Status | Notes |
| ------- | ------ | ----- |
| Core SVG rendering (6 variants) | Done | default, secondary, outline, ghost, destructive, branded |
| Text measurement + layout | Done | heuristic and width-tabled |
| Theme resolution (dark / light) | Done | plus high-contrast, enterprise, custom |
| HTTP server + router | Done | POSIX sockets, single-threaded event loop |
| Query parameter parsing | Done | full `?key=value` set for every badge |
| Static badge provider | Done | `/badge/label-message-color.svg` |
| npm provider | Done | version, downloads, license |
| GitLab provider | Done | stars, forks, issues, merge-requests, pipeline |
| GitHub provider | Done | stars, forks, issues, pulls, release, commits, contributors |
| Egress allowlist | Done | `src/net/egress.zig` |
| Per-provider backoff | Done | `src/cache/backoff.zig` |
| In-memory LRU cache | Done | `src/cache/lru.zig` |
| GitHub token pool + memo store | Done | `src/db/*` |
| Memo badges (GET + PUT) | Done | `/memo/:key` |
| Dagger CI/CD integration | Done | `ci/main.zig` module |
| Airgap-ready CI/CD | Done | pinned images, vendored dependencies, offline Zig build |
| Multi-arch builds | Done | amd64, aarch64 |
| OCI image | Done | melange + apko |
| Sigstore signing | Done | keyless with GitHub OIDC |
| Structured audit logging | Done | JSON lines to stderr |
| PNG rasterization | Done | pure-Zig, `zigimg` |
| Badge groups | Done | <code>/group/a&#124;b&#124;c.svg</code> |

## Quickstart

```bash
# Build and test
zig build
zig build test

# Run the server
zig build run -- serve
zig build run -- serve --host 0.0.0.0 --port 5335
```

### Air-gap / offline mode

The project is fully air-gap ready:

- **Offline build**: Dependencies are vendored in `zig-pkg/`. Build with zero network access:
  ```bash
  ./tools/build-offline.sh        # or: zig build --system zig-pkg
  ```
- **Offline runtime**: Start the server with `--offline` to disable all network providers (GitHub, GitLab, npm). Static badges, memo badges, and badge groups remain fully functional:
  ```bash
  zig build run -- serve --offline --port 5335
  ```
  Network provider routes return an `offline` value badge instead of attempting egress.

## Usage

### Static badges

```bash
curl http://localhost:5335/badge/build-passing-green.svg
curl http://localhost:5335/badge/build-passing-green.png
curl http://localhost:5335/badge/build-passing-green.json
```

### Live providers

```bash
# npm (version, downloads, license)
curl http://localhost:5335/npm/react.svg?variant=branded
curl http://localhost:5335/npm/downloads/react.svg
curl http://localhost:5335/npm/license/react.svg

# GitHub
curl http://localhost:5335/github/stars/ziglang/zig.svg
curl http://localhost:5335/github/forks/ziglang/zig.svg

# GitLab
curl http://localhost:5335/gitlab/stars/rust-lang/rust.svg
```

### Badge groups

Stack multiple static badges vertically in a single SVG:

```bash
curl "http://localhost:5335/group/build-passing-green|coverage-92%25-blue.svg"
```

### Query parameters

| Param | Values | Default |
| ----- | ------ | ------- |
| `variant` | default, secondary, outline, ghost, destructive, branded | `default` |
| `size` | xs, sm, default, lg | `sm` |
| `mode` | dark, light | `dark` |
| `theme` | dark, light, high-contrast, enterprise, custom | `dark` |
| `font` | inter, geist, geist-mono | `inter` |
| `color` | named or `#hex` | from path |
| `split` | true, false | auto when color present |
| `statusDot` | true, false | `false` |
| `gradient` | color name | none |

## Providers

| Provider | Path | Metrics | Network |
| ---------- | ---- | ------- | ------- |
| `badge` | `/badge/label-message-color.svg` | static | No |
| `npm` | `/npm/:metric/:package.svg` | version, downloads, license | Yes |
| `github` | `/github/:metric/:owner/:repo.svg` | stars, forks, issues, pulls, release, commits, contributors | Yes |
| `gitlab` | `/gitlab/:metric/:owner/:repo.svg` | stars, forks, issues, merge-requests, pipeline | Yes |
| `memo` | `/memo/:key.svg` (GET), `/memo/:key` (PUT) | user-defined | No |
| `group` | <code>/group/spec&#124;spec&#124;...svg</code> | stacked static badges | No |

## Dagger CI/CD

This project ships a Dagger module in `ci/main.zig` using the Dagger Zig SDK.
It is airgap-ready: the module uses pinned base/runtime images and the Zig package cache is vendored in `zig-pkg/` so builds run offline with `zig build --system zig-pkg` once the images are mirrored.

```bash
# Install Dagger CLI
curl -L https://dl.dagger.io/dagger/install.sh | DAGGER_VERSION=0.21.7 sh

# Run CI locally
dagger call lint --arg0=.
dagger call test --arg0=.
dagger call build --arg0=. export --path=./build-amd64
dagger call build-aarch-64 --arg0=. export --path=./build-aarch64
dagger call container --arg0=. --arg1=amd64 export --path=./shieldcn-amd64.tar

# Publish an OCI image
dagger call container --arg0=. --arg1=amd64 publish ghcr.io/mchorfa/shieldcn-zig:latest
```

| Function | CLI name | Output | Description |
| ---------- | -------- | ------ | ----------- |
| `build` | `build` | `Directory` | `zig-out` for `x86_64-linux-musl` |
| `buildAarch64` | `build-aarch-64` | `Directory` | `zig-out` for `aarch64-linux-musl` |
| `test` | `test` | `String` | `zig build check` |
| `lint` | `lint` | `String` | alias for `test` (CI symmetry) |
| `container(arch)` | `container --arch=<amd64|aarch64>` | `Container` | runnable Alpine image |

## Architecture

```
src/
  core/        shared types, errors, size presets
  render/      SVG builder, themes, tokens, measurement, PNG rasterizer, group composer
  icons/       embedded developer-icons resolver
  providers/   fetch layer, npm, static, github, gitlab
  server/      HTTP server, router, params, provider registry
  cache/       LRU, backoff
  net/         egress allowlist
  db/          token pool, memo store
  util/        hex colors, number formatting, structured audit logging
```

The server now dispatches providers through a registry (`src/server/providers.zig`). Each provider returns owned `BadgeData`; the HTTP layer resolves themes and renders without holding provider-specific logic. This keeps the handler small and makes adding a new provider a single entry in the registry.

## Security & Compliance

- **Egress allowlist**: `src/net/egress.zig` — only known API hosts permitted.
- **No hardcoded secrets**: `src/providers/fetch.zig` loads tokens from the environment.
- **TLS enforcement**: all provider fetches use `std.http.Client` with redirect handling.
- **Backoff + circuit breaker**: `src/cache/backoff.zig`.
- **Structured audit logging**: `src/util/audit.zig` emits JSON lines to stderr.
- **SLSA Level 3**: Dagger CI + Sigstore signing.
- **SBOM generation**: apko + cosign attest.

## Compatibility

This is an independent pure-Zig reimplementation of the [shieldcn](https://github.com/jal-co/shieldcn) route surface — not a port of the upstream TypeScript codebase. The goal is route-and-parameter compatibility, not pixel-identical SVG output.

**Compatible (matches upstream contract):**

| Surface | Status |
| --- | --- |
| Routes — `/badge`, `/npm`, `/github`, `/gitlab`, `/group`, `/memo` | Match |
| Query params — `variant`, `size`, `mode`, `theme`, `font`, `split`, `logo`, `color`, `labelColor`, `gradient`, `statusDot`, `wcag` | Match |
| Variants — `default`, `secondary`, `outline`, `ghost`, `destructive`, `branded` | Match |
| Output formats — `.svg`, `.png`, `.json` | Match |
| GitHub route styles — `/github/{topic}/{owner}/{repo}` and `/github/{owner}/{repo}/{topic}` | Match |
| Text rendering — vectorized `<path>` glyphs (font-independent) | Match |
| Default surface — single rounded `<path>`, `split=true` opt-in | Match |
| SVG root structure — no `role`/`aria-label`/`<title>`, no `clipPath` in single-surface mode | Match |
| Color palette — shadcn tokens (`#fafafa`, `#18181b`, `fill-opacity=".7"`) | Match |
| Badge height — `32` | Match |
| Corner geometry — single rounded `<path d="M6 0H…A6 6 0 0 1…">` | Match |
| `viewBox` attribute | Match |
| Auto-icons — star on `/github/stars`, fork on `/github/forks`, etc. | Match |
| WCAG 3.0 mode — `?wcag=3` switches to APCA-compliant shade-800 colors | Extension |

**Remaining differences (not pixel-identical):**

| Aspect | Upstream shieldcn | This engine |
| --- | --- | --- |
| Font | Inter (vectorized via Satori) | SF Pro (vectorized via embedded glyph table from `tools/extract_glyphs.py`) |
| Glyph shapes | Inter glyph outlines | SF Pro glyph outlines — same vectorization approach, different source font |
| Path structure | Single `<path>` per text string (Satori bakes glyphs together) | One `<path>` per glyph inside a shared `<g>` (visually equivalent, more DOM nodes) |
| Badge width | ~116px for "build passing" | ~113px (SF Pro is slightly narrower than Inter) |
| Icon set | `developer-icons` (full set) | `developer-icons` (embedded) + inline Octicon-style paths for GitHub metrics |

The README badges above are served by the upstream `shieldcn.dev` service so they render correctly on GitHub. The local engine now produces structurally equivalent output — same SVG root structure (no `role`/`aria-label`/`<title>`), same colors (`#16a34a`, `#2563eb`, `#dc2626`, …), same opacity format (`fill-opacity=".7"`), same text color rule (white on colored backgrounds), same geometry (single rounded `<path>`, no `clipPath` in single-surface mode, height=32, radius=6), same `viewBox`, same font metrics (font_size=14, pad_x=16, baseline≈21.3), and same auto-icons. The only visible difference is the source font (SF Pro vs Inter), which produces slightly different glyph shapes and a 3px width difference.

## WCAG 3.0 Compliance

Badges support an optional `?wcag=3` query parameter that switches to **APCA-compliant** background colors. The default mode uses tailwind shade-600 colors (matching upstream shieldcn); WCAG 3.0 mode uses darker shade-800 colors that meet the APCA |Lc| >= 60 threshold for non-body text / UI labels.

### Usage

```
<!-- Default (upstream-compatible, shade-600) -->
<img src="https://shieldcn.dev/badge/build-passing-green.svg" />

<!-- WCAG 3.0 compliant (shade-800, APCA |Lc| >= 60) -->
<img src="https://shieldcn.dev/badge/build-passing-green.svg?wcag=3" />
```

### APCA Contrast Values

| Color | Default (shade-600) | \|Lc\| | Pass? | WCAG 3.0 (shade-800) | \|Lc\| | Pass? |
| --- | --- | --- | --- | --- | --- | --- |
| green | `#16a34a` | 42.8 | FAIL | `#166534` | 63.9 | YES |
| blue | `#2563eb` | 55.9 | FAIL | `#1e40af` | 68.5 | YES |
| red | `#dc2626` | 54.1 | FAIL | `#991b1b` | 67.4 | YES |
| orange | `#ea580c` | 45.3 | FAIL | `#9a3412` | 64.5 | YES |
| yellow | `#d97706` | 41.7 | FAIL | `#92400e` | 63.8 | YES |
| purple | `#9333ea` | 57.0 | FAIL | `#6b21a8` | 68.5 | YES |
| gray | `#6b7280` | 54.2 | FAIL | `#1f2937` | 79.4 | YES |

**APCA thresholds (WCAG 3.0 draft):**

| \|Lc\| | Context |
| --- | --- |
| >= 90 | Excellent — best for small text |
| >= 75 | Preferred for body text |
| >= 65 | Large text (18pt+ / 24px+ bold) |
| >= 60 | Minimum for non-body text / UI labels |
| >= 50 | UI components minimum |
| >= 15 | Non-text (decorative only) |

Badge text is 14px (small text), so the appropriate target is **|Lc| >= 60** (non-body text / UI labels). All shade-800 colors meet this threshold with white text (`#fff`).

### Implementation

- `?wcag=3` resolves named colors to shade-800 hex values (e.g. `green` → `#166534` instead of `#16a34a`)
- Text foreground is selected via APCA contrast comparison (picks white or dark based on which has higher |Lc|)
- The APCA W3 formula is implemented in `src/util/contrast.zig` with proper soft-clamp and noise floor
- All 7 standard colors pass the |Lc| >= 60 threshold in WCAG 3.0 mode
- Default mode (no `?wcag=` param) remains upstream-compatible with shade-600 colors

## License

MIT
