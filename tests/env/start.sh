#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
NGINX_CONF="$SCRIPT_DIR/nginx.conf"
PID_FILE="$SCRIPT_DIR/logs/nginx.pid"

export DATA_ROOT="${DATA_ROOT:-$DATA_DIR}"
export AUTH_REQUIRED="${AUTH_REQUIRED:-false}"
export URL_PREFIX="${URL_PREFIX:-/}"
export REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
export REDIS_PORT="${REDIS_PORT:-6379}"
if [ -n "$REDIS_PASSWORD" ]; then
  export REDIS_PASSWORD
fi
export PAGE_LIMIT="${PAGE_LIMIT:-10}"
export LOGO_TEXT="${LOGO_TEXT:-Test Files}"
export ADMIN_GROUP="${ADMIN_GROUP:-fileserver-admin}"
export TOKEN_EXPIRE_MINUTES="${TOKEN_EXPIRE_MINUTES:-6}"
export ENABLE_CONCURRENT_CONTROL="${ENABLE_CONCURRENT_CONTROL:-false}"
export OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-}"
export OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-}"
export OIDC_DISCOVERY_URL="${OIDC_DISCOVERY_URL:-}"
export OIDC_REDIRECT_URI="${OIDC_REDIRECT_URI:-}"
export OIDC_LOGOUT_PATH="${OIDC_LOGOUT_PATH:-}"
export OIDC_LOGOUT_REDIRECT_URI="${OIDC_LOGOUT_REDIRECT_URI:-}"
export OIDC_SSL_VERIFY="${OIDC_SSL_VERIFY:-no}"
export GROUPS_CACHE_TTL="${GROUPS_CACHE_TTL:-300}"

echo "=== iDO-Files E2E Test Environment ==="

# Check Redis
echo -n "Checking Redis... "
if redis-cli ping > /dev/null 2>&1; then
    echo "OK"
else
    echo "Starting Redis..."
    brew services start redis 2>/dev/null || redis-server --daemonize yes 2>/dev/null || true
    sleep 1
    redis-cli ping > /dev/null 2>&1 || { echo "ERROR: Redis not available"; exit 1; }
    echo "Redis started"
fi

# Seed test data
echo "Seeding test data..."
bash "$PROJECT_ROOT/tests/fixtures/seed/seed-data.sh" "$DATA_DIR"

# Create symlinks (as Start.sh does)
rm -rf "$DATA_DIR/app" "$DATA_DIR/internal-download" "$DATA_DIR/internal-archive"
ln -sf "$DATA_DIR/download" "$DATA_DIR/app"
ln -sf "$DATA_DIR/download" "$DATA_DIR/internal-download"
ln -sf "$DATA_DIR/archive" "$DATA_DIR/internal-archive"

# Create log directory
mkdir -p "$SCRIPT_DIR/logs"

# Stop any existing instance
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Stopping existing nginx (pid=$OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

# Verify nginx binary
NGINX_BIN="$(which openresty 2>/dev/null || echo '/opt/homebrew/bin/openresty')"
if [ ! -x "$NGINX_BIN" ]; then
    echo "ERROR: openresty binary not found at $NGINX_BIN"
    exit 1
fi

echo "Starting OpenResty..."
cd "$SCRIPT_DIR"
"$NGINX_BIN" -p "$SCRIPT_DIR" -c "$NGINX_CONF"

sleep 1

# Verify it started
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "OpenResty started (pid=$(cat "$PID_FILE"))"
else
    echo "ERROR: OpenResty failed to start. Check logs/error.log"
    cat "$SCRIPT_DIR/logs/error.log" 2>/dev/null | tail -20
    exit 1
fi

# Health check
echo -n "Health check... "
for i in $(seq 1 10); do
    if curl -sf http://localhost:8080/health > /dev/null 2>&1; then
        echo "OK"
        echo ""
        echo "Server running at http://localhost:8080"
        echo "  List files: http://localhost:8080/download/"
        exit 0
    fi
    sleep 1
done

echo "FAILED"
echo "Error log:"
cat "$SCRIPT_DIR/logs/error.log" 2>/dev/null | tail -30
exit 1
