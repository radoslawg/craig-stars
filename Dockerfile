# syntax=docker/dockerfile:1.7
# =============================================================================
#  craig-stars – self-hosted production image
# =============================================================================
#  One container that serves the whole game:
#    * Caddy on :8080 serves the static SvelteKit frontend and proxies /api/*
#    * the craig-stars Go backend listens on 127.0.0.1:9000 inside the container
#    * game data (SQLite DB + config.yaml) lives in the /app/data volume
#
#  Build:  docker build -t craig-stars .
#  Run:    docker run -d -p 8080:8080 -v craig-stars-data:/app/data craig-stars
#  Login:  admin / admin  (change it after first login!)
# =============================================================================

ARG GO_VERSION=1.27.1
ARG NODE_VERSION=24
ARG ALPINE_VERSION=3.22

# -----------------------------------------------------------------------------
#  Ship & planet artwork (not stored in git; same zip `mage images` downloads)
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS images
ARG IMAGES_URL=https://craig-stars.net/images/images.zip
RUN apk add --no-cache curl unzip \
 && mkdir -p /out \
 && curl -fsSL --retry 3 "$IMAGES_URL" -o /tmp/images.zip \
 && unzip -q /tmp/images.zip -d /out \
 && test -d /out/images

# -----------------------------------------------------------------------------
#  WebAssembly module used by the frontend (architecture independent)
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS wasm
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    mkdir -p /out \
 && GOOS=js GOARCH=wasm CGO_ENABLED=0 \
    go build -buildvcs=false -ldflags="-s -w" -o /out/cs.wasm ./wasm/main.go \
 && cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" /out/wasm_exec.js

# -----------------------------------------------------------------------------
#  Frontend (SvelteKit static build)
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS frontend
ARG VERSION=0.0.0-docker
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 CI=true
WORKDIR /src/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --no-audit --no-fund
COPY frontend/ ./
COPY --from=wasm   /out/        ./src/lib/wasm/
COPY --from=images /out/images  ./static/images
# keep the frontend version in sync with the backend's X-App-Version header
RUN node -e "const f='package.json',p=require('./'+f);p.version=process.argv[1];require('fs').writeFileSync(f,JSON.stringify(p,null,'\t'))" "$VERSION" \
 && npm run build

# -----------------------------------------------------------------------------
#  Backend (Go + CGO sqlite, statically linked)
# -----------------------------------------------------------------------------
FROM golang:${GO_VERSION}-alpine AS backend
ARG VERSION=0.0.0-docker
ARG COMMIT=unknown
ARG BUILD_TIME=unknown
RUN apk add --no-cache gcc musl-dev
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 go build -buildvcs=false \
      -ldflags="-s -w -extldflags '-static' \
        -X 'github.com/sirgwain/craig-stars/version.Semver=${VERSION}' \
        -X 'github.com/sirgwain/craig-stars/version.Commit=${COMMIT}' \
        -X 'github.com/sirgwain/craig-stars/version.BuildTime=${BUILD_TIME}'" \
      -o /out/craig-stars ./main.go

# -----------------------------------------------------------------------------
#  Runtime
# -----------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}
ARG VERSION=0.0.0-docker
LABEL org.opencontainers.image.title="craig-stars" \
      org.opencontainers.image.description="Open-source, web based Stars! clone" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"

RUN apk add --no-cache caddy tini su-exec ca-certificates tzdata \
 && addgroup -S -g 1000 craig \
 && adduser  -S -u 1000 -G craig -h /app craig

COPY --from=backend  /out/craig-stars          /usr/local/bin/craig-stars
COPY --from=frontend /src/frontend/build       /srv
COPY docker/Caddyfile                          /etc/caddy/Caddyfile
COPY --chmod=0755 docker/entrypoint.sh         /usr/local/bin/entrypoint.sh

ENV PUID=1000 \
    PGID=1000 \
    CS_PUBLIC_URL=http://localhost:8080 \
    CS_SECURE_COOKIE=false \
    XDG_CONFIG_HOME=/tmp/caddy \
    XDG_DATA_HOME=/tmp/caddy

WORKDIR /app
VOLUME ["/app/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/api/ping || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
