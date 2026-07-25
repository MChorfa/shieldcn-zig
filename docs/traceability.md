# shieldcn-zig Traceability Matrix

CKODEX / cortAIx Factory CSR control mapping for the shieldcn clean-room Zig reimplementation.

## Implemented Controls

| Control | Status | Evidence | Verifier |
|---------|--------|----------|----------|
| CFY-DSG-ZERO (Zero-trust default) | Implemented | Architecture: no implicit trust between server and providers; every upstream request validated | Self |
| CFY-NET-ING (Ingress closed by default) | Implemented | Server binds to 127.0.0.1 unless `BIND_HOST` explicitly set | Self |
| CFY-NET-EGR (Egress closed by default) | Implemented | `src/net/egress.zig` allowlist enforcement; unknown hosts return 403 | Self |
| NET-FIL-WHIT (Whitelist filtering) | Implemented | `ALLOWED_HOSTS` array in `src/net/egress.zig` | Self |
| IMP-COD-HARD (No hardcoded secrets) | Implemented | All secrets loaded from environment at startup; compile-time assertion via build step | Self |
| CFY-SEC-COD (Secret coding standards) | Implemented | No secret-like strings in source; `providerFetch` loads tokens from env only | Self |
| CFY-CRY-REST (Encryption at rest) | Partial | Designed for SQLCipher integration in `src/db/sqlite.zig` | Self |
| CFY-CRY-E2E (E2E encryption) | Implemented | All provider fetches enforce TLS via `std.http.Client`; no plaintext HTTP | Self |
| IAM-AUT-LEAS (Least privilege) | Implemented | GitHub token pool stores zero-scope read-only tokens | Self |
| INC-LOG-CONS (Log retention) | Designed | Structured JSON audit logging in `src/util/log.zig`; 12-month retention policy documented | Self |
| TST-BSL-SAST (SAST) | Designed | CI runs `zig fmt --check` and `zig build test` | Self |
| FPR-TRAC (Traceability) | Implemented | This document | Self |
| PRR-REL-SBOM (SBOM) | Designed | To be generated via `syft` at build time | Self |
| PRR-REL-SIGN (Signed artifacts) | Designed | Docker image to be signed with `cosign` | Self |

## SSDLC Stage Mapping

| Stage | Module | Control |
|-------|--------|---------|
| Design | `src/net/egress.zig` | CFY-NET-ING, CFY-NET-EGR, NET-FIL-WHIT |
| Design | `src/server/http.zig` | CFY-DSG-ZERO |
| Build | `src/providers/fetch.zig` | CFY-CRY-E2E, IAM-AUT-LEAS |
| Build | `src/crypto/vault.zig` (planned) | CFY-CRY-REST, CFY-SEC-COD |
| Build | `src/util/log.zig` (planned) | INC-LOG-CONS |
| Test | `build.zig` + CI | TST-BSL-SAST |
| Release | `Dockerfile` + `evidence/bundle.json` | PRR-REL-SBOM, PRR-REL-SIGN, FPR-TRAC |
