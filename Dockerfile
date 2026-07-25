# ── Stage 1: Builder ──────────────────────────────────────────────
FROM alpine:3.20 AS builder
RUN apk add --no-cache zig build-base freetype-dev sqlite-dev

WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

# ── Stage 2: Hardened runtime ───────────────────────────────────
FROM scratch
COPY --from=builder /src/zig-out/bin/shieldcn /shieldcn
COPY --from=builder /src/fonts /fonts

# No shell, no package manager, non-root
USER 65534:65534
EXPOSE 5335

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/shieldcn", "health"]

ENTRYPOINT ["/shieldcn"]
CMD ["serve", "--host", "0.0.0.0", "--port", "5335"]
