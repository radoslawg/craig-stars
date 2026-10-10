#!/bin/sh
# craig-stars container entrypoint
#  - creates /app/data/config/config.yaml on first start (random secrets)
#  - starts the Go backend on 127.0.0.1:9000 and Caddy on :8080
#  - exits (so Docker can restart it) if either process dies
set -eu

DATA_DIR=/app/data
CONFIG_FILE="$DATA_DIR/config/config.yaml"

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
CS_PUBLIC_URL="${CS_PUBLIC_URL:-http://localhost:8080}"
CS_SECURE_COOKIE="${CS_SECURE_COOKIE:-false}"

rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40; }

mkdir -p "$DATA_DIR/config" /tmp/caddy /tmp/craig-stars

if [ ! -f "$CONFIG_FILE" ]; then
	echo "entrypoint: creating $CONFIG_FILE"
	cat >"$CONFIG_FILE" <<EOF
# craig-stars server config (generated on first start, safe to edit)
# Auth.URL and Auth.SecureCookie are overridden on every start by the
# CS_PUBLIC_URL and CS_SECURE_COOKIE container environment variables.
database:
  filename: data/data.db
  readconnectionparams: "?_txlock=deferred"
  writeconnectionparams: "?_txlock=immediate&_busy_timeout=1200"
auth:
  secret: $(rand)
  url: "$CS_PUBLIC_URL"
  disablexsrf: true
  securecookie: $CS_SECURE_COOKIE
discord:
  enabled: false
  cookieduration: 168h
game:
  invitelinksalt: $(rand)
EOF
fi

# run as an unprivileged user when started as root
RUN_AS=""
if [ "$(id -u)" = "0" ]; then
	chown -R "$PUID:$PGID" "$DATA_DIR" /tmp/caddy /tmp/craig-stars
	RUN_AS="su-exec $PUID:$PGID"
fi

# Viper reads env vars named after the (upper-cased, dotted) config keys.
# Those names aren't valid shell identifiers, so pass them via env(1).
set -- \
	"ADDRESS=127.0.0.1:9000" \
	"AUTH.URL=$CS_PUBLIC_URL" \
	"AUTH.SECURECOOKIE=$CS_SECURE_COOKIE"
if [ -n "${CS_AUTH_SECRET:-}" ]; then
	set -- "$@" "AUTH.SECRET=$CS_AUTH_SECRET"
fi

echo "entrypoint: starting craig-stars backend (public URL: $CS_PUBLIC_URL)"
# shellcheck disable=SC2086
$RUN_AS env "$@" /usr/local/bin/craig-stars serve &
BACKEND_PID=$!

echo "entrypoint: starting caddy on :8080"
# shellcheck disable=SC2086
$RUN_AS caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

shutdown() {
	echo "entrypoint: stopping"
	kill -TERM "$CADDY_PID" "$BACKEND_PID" 2>/dev/null || true
	wait "$BACKEND_PID" 2>/dev/null || true
	wait "$CADDY_PID" 2>/dev/null || true
	exit 0
}
trap shutdown TERM INT

# supervise: if either process exits, stop the other and exit non-zero
while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
	sleep 2 &
	wait $! || true
done

echo "entrypoint: a process exited unexpectedly, shutting down" >&2
kill -TERM "$CADDY_PID" "$BACKEND_PID" 2>/dev/null || true
wait 2>/dev/null || true
exit 1
