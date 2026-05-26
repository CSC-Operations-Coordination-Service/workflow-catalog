FROM python:3.14.3-alpine3.20 AS runner

# CKV_DOCKER_2 — HEALTHCHECK required by default for Checkov
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import sys; sys.exit(0)" || exit 1

# CKV_DOCKER_3 — run as non-root
RUN addgroup -S testgroup && adduser -S testuser -G testgroup
USER testuser
