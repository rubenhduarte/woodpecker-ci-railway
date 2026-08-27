#!/bin/sh
# Woodpecker CI agent entrypoint for Railway.
#
# Runs as root so it can prepare the volume, then drops to uid 1000 (woodpecker)
# before exec'ing the agent — the Local backend runs pipeline commands as whoever
# the agent is, and upstream is explicit that it must not be root.
set -eu

log() { echo "[railway-entrypoint] $*"; }

# `woodpecker-agent ping` is the image's own HEALTHCHECK. Never run the volume
# preparation for it.
if [ "${1:-}" = "ping" ]; then
    exec /bin/woodpecker-agent.real "$@"
fi

WP_USER=woodpecker
WP_UID=1000
WP_GID=1000

# Single volume, so both things that must survive a redeploy live under it: the
# agent's own registration id, and the Local backend's workflow directories.
DATA_DIR="${WOODPECKER_RAILWAY_DATA_DIR:-/var/lib/woodpecker}"
TEMP_DIR="${WOODPECKER_BACKEND_LOCAL_TEMP_DIR:-$DATA_DIR/tmp}"

mkdir -p "$DATA_DIR" "$TEMP_DIR" "/home/$WP_USER"

# A workflow killed mid-run (redeploy, pipeline timeout) leaves its directory
# behind, and on a volume that accumulates forever. Boot is the only safe moment
# to clear them, because no workflow is running yet.
if [ -d "$TEMP_DIR" ]; then
    stale=$(find "$TEMP_DIR" -maxdepth 1 -name 'woodpecker-local-*' -type d 2>/dev/null | wc -l | tr -d ' ')
    if [ "$stale" != "0" ]; then
        log "removing $stale stale workflow director(ies) from $TEMP_DIR"
        find "$TEMP_DIR" -maxdepth 1 -name 'woodpecker-local-*' -type d -exec rm -rf {} + 2>/dev/null || true
    fi
fi

chown -R "$WP_UID:$WP_GID" "$DATA_DIR" "/home/$WP_USER"

export WOODPECKER_BACKEND="${WOODPECKER_BACKEND:-local}"
export WOODPECKER_BACKEND_LOCAL_TEMP_DIR="$TEMP_DIR"
export WOODPECKER_AGENT_CONFIG_FILE="${WOODPECKER_AGENT_CONFIG_FILE:-$DATA_DIR/agent.conf}"
export HOME="/home/$WP_USER"

# Railway regenerates the container hostname on every deploy, which would show up
# as a renamed agent in the server's agent list on each rollout. Pin it; the
# registration id in agent.conf is what actually identifies this agent.
export WOODPECKER_HOSTNAME="${WOODPECKER_HOSTNAME:-railway-agent}"

# Railway's health check probes $PORT.
export WOODPECKER_HEALTHCHECK_ADDR="${WOODPECKER_HEALTHCHECK_ADDR:-:${PORT:-3000}}"

# Railway has no service ordering, so on a first deploy the server is usually
# still building. Wait it out rather than crash-looping through it.
export WOODPECKER_CONNECT_RETRY_COUNT="${WOODPECKER_CONNECT_RETRY_COUNT:-30}"
export WOODPECKER_CONNECT_RETRY_DELAY="${WOODPECKER_CONNECT_RETRY_DELAY:-10s}"

# `${{woodpecker-server.RAILWAY_PRIVATE_DOMAIN}}` renders empty until that service
# owns a deployment, which leaves this variable set to a bare ":9000" on a fresh
# template deploy. Recognise that shape and fall back to the deterministic name.
case "${WOODPECKER_SERVER:-}" in
    "" | :*)
        WOODPECKER_SERVER="${WOODPECKER_RAILWAY_SERVER_FALLBACK:-woodpecker-server.railway.internal:9000}"
        log "WOODPECKER_SERVER was unset or host-less; using $WOODPECKER_SERVER"
        ;;
esac
export WOODPECKER_SERVER

# The Local backend hands os.Environ() to every pipeline step, so anything left in
# the environment is readable by any pipeline this agent runs. Move the shared
# secret into a file the agent reads instead, and drop it from the environment.
if [ -n "${WOODPECKER_AGENT_SECRET:-}" ]; then
    secret_file="$DATA_DIR/agent-secret"
    printf '%s' "$WOODPECKER_AGENT_SECRET" > "$secret_file"
    chmod 0400 "$secret_file"
    chown "$WP_UID:$WP_GID" "$secret_file"
    unset WOODPECKER_AGENT_SECRET
    export WOODPECKER_AGENT_SECRET_FILE="$secret_file"
    log "agent secret moved out of the environment into $secret_file"
fi

log "backend=$WOODPECKER_BACKEND server=$WOODPECKER_SERVER hostname=$WOODPECKER_HOSTNAME"
log "data=$DATA_DIR temp=$TEMP_DIR healthcheck=$WOODPECKER_HEALTHCHECK_ADDR"

exec su-exec "$WP_UID:$WP_GID" /bin/woodpecker-agent.real "$@"
