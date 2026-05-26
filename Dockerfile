FROM alpine:3.23.4 AS runner

# CKV_DOCKER_2 — HEALTHCHECK required by default for Checkov
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD echo "Hello, World!" || exit 1

# CKV_DOCKER_3 — run as non-root
RUN addgroup -S testgroup && adduser -S testuser -G testgroup
USER testuser
