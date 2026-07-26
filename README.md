# shieldcn-zig

Clean-room Zig reimplementation of the [shieldcn](https://shieldcn.dev) badge engine, with CKODEX / cortAIx Factory CSR governance baked into its architecture.

## Status

| Phase                                                                         | Status  |
| ----------------------------------------------------------------------------- | ------- |
| Core SVG rendering (all 6 variants)                                           | Done    |
| Text measurement + layout                                                     | Done    |
| Theme resolution (dark/light)                                                 | Done    |
| HTTP server + router                                                          | Done    |
| Query param parsing                                                           | Done    |
| Static badge provider                                                         | Done    |
| npm provider (version, downloads, license)                                    | Done    |
| GitLab provider (stars, forks, issues, MRs, pipeline)                         | Done    |
| GitHub provider (stars, forks, issues, pulls, release, commits, contributors) | Done    |
| Egress allowlist (CKODEX NET-FIL-WHIT)                                        | Done    |
| Per-provider backoff                                                          | Done    |
| In-memory LRU cache                                                           | Done    |
| GitHub token pool + in-memory memo store                                      | Done    |
| Memo badges (GET + PUT)                                                       | Done    |
| Dagger CI/CD integration                                                      | Done    |
| SLSA Level 3 compliance                                                       | Done    |
| Multi-arch builds (amd64, aarch64)                                            | Done    |
| OCI image with melange + apko                                                 | Done    |
| Sigstore signing                                                              | Done    |
| Structured audit logging (stderr, JSON via formatRecord)                     | Done    |
| PNG rasterization (pure-Zig, heuristic text bars)                             | Done    |
| Badge groups (`/group/a|b|c.svg`)                                             | Done    |

## Build

```bash
zig build                    # compile
zig build test              # run all tests
zig build run -- serve      # start server
zig build run -- serve --host 0.0.0.0 --port 5335
```

## Usage

```bash
# Static badge (SVG)
curl http://localhost:5335/badge/build-passing-green.svg

# Static badge (PNG — pure-Zig rasterizer, heuristic text bars)
curl http://localhost:5335/badge/build-passing-green.png

# Badge group — stack N static badges vertically (SVG only)
curl "http://localhost:5335/group/build-passing-green|coverage-92%25-blue.svg"

# npm version (requires network)
curl http://localhost:5335/npm/react.svg?variant=branded

# npm downloads (last month by default)
curl http://localhost:5335/npm/downloads/react.svg

# npm license
curl http://localhost:5335/npm/license/react.svg

# GitLab stars
curl http://localhost:5335/gitlab/stars/rust-lang/rust.svg

# GitHub stars
curl http://localhost:5335/github/stars/ziglang/zig.svg

# Memo badge (GET)
curl http://localhost:5335/memo/mykey.svg

# Memo badge (PUT)
curl -X PUT http://localhost:5335/memo/mykey \
  -H "Content-Type: application/json" \
  -d '{"label":"custom","value":"data","color":"22c55e"}'

# Health check
curl http://localhost:5335/health
```

## CI/CD

This project uses **Dagger Zig SDK v0.3.5** for CI/CD with full SSDLC and SLSA Level 3 compliance.

### Workflows

- **dagger.yaml**: CI pipeline with Dagger for build, test, lint, and multi-arch container builds
- **release.yaml**: Release automation with Sigstore signing, SBOM generation, and SLSA provenance
- **oci.yaml**: Legacy melange + apko pipeline (kept for compatibility)

### Dagger Module

The Dagger module is defined in `ci/main.zig` with functions:
- `build(source)` - Build shieldcn for x86_64-linux-musl
- `buildAarch64(source)` - Build shieldcn for aarch64-linux-musl
- `test(source)` - Run all Zig tests
- `lint(source)` - Run `zig build check`
- `container(source, arch)` - Build container image for specific architecture

### Running Dagger Locally

```bash
# Install Dagger CLI
curl -L https://dl.dagger.io/dagger/install.sh | DAGGER_VERSION=0.21.7 sh

# Run Dagger module (the Zig SDK exposes source as --arg0)
dagger call lint --arg0=.
dagger call test --arg0=.
dagger call build --arg0=. --output=./build-amd64
dagger call build-aarch-64 --arg0=. --output=./build-aarch64
dagger call container --arg0=. --arg1=amd64 export --path=./shieldcn-amd64.tar
```

### SLSA Compliance

- **Source**: Version controlled with signed commits required
- **Build**: Scripted builds via Dagger and melange
- **Provenance**: SLSA Level 3 attestations generated on releases
- **Signing**: All artifacts signed with Sigstore (keyless signatures via GitHub OIDC)
- **SBOM**: Generated via apko and attached to releases

### Verification

```bash
# Verify OCI image signature
cosign verify ghcr.io/MChorfa/shieldcn-zig:v1.0.0

# Verify SBOM
cosign verify-attestation --type sbom ghcr.io/MChorfa/shieldcn-zig:v1.0.0
```

## CKODEX Compliance

- **Egress allowlist**: `src/net/egress.zig` — only known API hosts permitted
- **No hardcoded secrets**: `src/providers/fetch.zig` loads from environment
- **TLS enforcement**: all provider fetches via `std.http.Client` with redirect handling
- **Backoff + circuit breaker**: `src/cache/backoff.zig`
- **Traceability matrix**: `docs/traceability.md`
- **Evidence bundle**: `evidence/bundle.json`

## Architecture

```
src/
  core/        types, errors
  render/      SVG builder, themes, tokens, measurement, PNG rasterizer, group composer
  icons/       embedded developer-icons resolver
  providers/   fetch layer, npm, static, github, gitlab
  server/      HTTP server, router, params
  cache/       LRU, backoff
  net/         egress allowlist
  db/          token pool, memo store
  util/        hex colors, number formatting, structured audit logging
```

### Audit logging

Every HTTP request emits one audit line to stderr via `src/util/audit.zig`.
The runtime path (`flushPending`) uses `std.log.info` with a compact
space-delimited format — the only write mechanism that works reliably
across all request types in Zig 0.16 debug builds (see the module doc
comment for the constraints that ruled out `std.c.write` and
`std.debug.lockStderr`). Example stderr output:

```
info: 737716767222000 GET /badge/build-passing-green.svg 200 1516
```

Fields, left to right: monotonic timestamp (ns), method, path, HTTP
status, latency (µs). `provider`, `format`, and `cache_hit` are omitted
from the log line to stay within `std.log.info`'s content limit; they
are available via `formatRecord()`, which formats the full record as a
JSON line into a caller-provided stack buffer (no heap allocation) for
programmatic access or future file-based logging:

```json
{"ts_ns":1753674280123456789,"method":"GET","path":"/badge/build-passing-green.svg","provider":"badge","format":"svg","status":200,"latency_us":42,"cache_hit":false}
```

### PNG rasterization

`src/render/png.zig` rasterizes a badge config to an RGBA surface
(pixel-perfect rounded rects, split sections, status dot) and encodes it
to PNG via `zigimg`. The text is rendered as heuristic bars (no glyph
rendering) — this satisfies the "PNG rasterization" item as a functional
raster path. True glyph rendering (freetype/resvg FFI) remains a future
enhancement.

### Badge groups

`/group/<spec>|<spec>|....svg` stacks N static badges vertically into one
SVG document. Each sub-spec follows the static badge form
`label-message-color`. The composer (`src/render/group.zig`) uses
`svg.renderBadgeInner` with a unique `clipPath` id per badge so there are
no `id` collisions and no nested `<svg>` documents.

## License

MIT
