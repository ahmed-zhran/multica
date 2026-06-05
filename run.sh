#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

# Set Multica paths relative to this repo — portable across machines
export MULTICA_HOME="$REPO_ROOT"
export MULTICA_WORKSPACES_ROOT="$REPO_ROOT/workspaces"
export PATH="$REPO_ROOT/server/bin:$PATH"

echo "================================================"
echo "  Multica — Self-hosted Server + Daemon Runner"
echo "  Repo: $REPO_ROOT"
echo "================================================"
echo ""

# ---------- Prerequisites ----------
command -v docker >/dev/null 2>&1 || { echo "✗ Docker is required. Install it first."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✗ curl is required."; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "✗ openssl is required."; exit 1; }

# ---------- CLI Binary (build from source w/ MULTICA_HOME patch) ----------
MULTICA_BIN="$REPO_ROOT/server/bin/multica"
GO_BIN="${MULTICA_GO:-/usr/local/go1.26/bin/go}"

build_multica_cli() {
  echo "==> Building Multica CLI from source (MULTICA_HOME-aware)..."
  mkdir -p "$REPO_ROOT/server/bin"

  # Install Go 1.26.1 if not present
  if [ ! -x "$GO_BIN" ]; then
    echo "   Installing Go 1.26.1 to /usr/local/go1.26..."
    curl -fsSL "https://go.dev/dl/go1.26.1.linux-amd64.tar.gz" -o /tmp/go1.26.tar.gz
    sudo rm -rf /usr/local/go1.26 /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go1.26.tar.gz
    sudo mv /usr/local/go /usr/local/go1.26
    rm -f /tmp/go1.26.tar.gz
    echo "✓ Go 1.26.1 installed"
  fi

  COMMIT=$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  cd "$REPO_ROOT/server"
  $GO_BIN build -ldflags \
    "-X main.version=0.3.17 -X main.commit=$COMMIT -X main.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -o bin/multica ./cmd/multica 2>&1
  strip bin/multica 2>/dev/null || true
  echo "✓ CLI binary built: $MULTICA_BIN"
}

if [ ! -f "$MULTICA_BIN" ]; then
  build_multica_cli
fi

# ---------- Environment file ----------
if [ ! -f .env ]; then
  echo "==> Creating .env from .env.example..."
  cp .env.example .env

  JWT=$(openssl rand -hex 32)
  if [ "$(uname)" = "Darwin" ]; then
    sed -i '' "s/^JWT_SECRET=.*/JWT_SECRET=$JWT/" .env
  else
    sed -i "s/^JWT_SECRET=.*/JWT_SECRET=$JWT/" .env
  fi
  echo "   Generated random JWT_SECRET"
fi

# ---------- Create persistent data directories ----------
mkdir -p pgdata uploads workspaces .multica
echo "==> Data directories ready: pgdata/ uploads/ workspaces/ .multica/"

# ---------- Pull images & start ----------
echo "==> Pulling latest Multica images..."
docker compose -f docker-compose.selfhost.yml pull || {
  echo ""
  echo "⚠ Official images not published yet. Building from source..."
  echo "  Run: make selfhost-build"
  exit 1
}

echo "==> Starting Multica services..."
docker compose -f docker-compose.selfhost.yml up -d

echo ""
echo "✓ Multica server is running!"
echo "   Frontend: http://localhost:${FRONTEND_PORT:-3000}"
echo "   Backend:  http://localhost:${BACKEND_PORT:-${API_PORT:-${SERVER_PORT:-${PORT:-8080}}}}"
echo ""

# ---------- Postgres health check ----------
echo "==> Waiting for PostgreSQL to be healthy..."
for i in $(seq 1 30); do
  if docker compose -f docker-compose.selfhost.yml exec -T postgres \
    pg_isready -U "${POSTGRES_USER:-multica}" -d "${POSTGRES_DB:-multica}" >/dev/null 2>&1; then
    echo "✓ PostgreSQL ready"
    break
  fi
  sleep 1
done

# ---------- CLI Config ----------
echo "==> Configuring CLI for self-hosted server..."
"$MULTICA_BIN" config set server_url "http://localhost:8080" 2>/dev/null || true
"$MULTICA_BIN" config set app_url "http://localhost:3000" 2>/dev/null || true

# ---------- Auth ----------
# If there's an old config at ~/.multica/config.json, migrate token
OLD_CONFIG="$HOME/.multica/config.json"
if [ -f "$OLD_CONFIG" ]; then
  OLD_TOKEN=$(grep -oP '"token":\s*"\K[^"]+' "$OLD_CONFIG" 2>/dev/null || true)
  if [ -n "$OLD_TOKEN" ]; then
    echo "==> Migrating auth token from ~/.multica/ to repo..."
    "$MULTICA_BIN" config set server_url "http://localhost:8080" 2>/dev/null || true
    "$MULTICA_BIN" config set app_url "http://localhost:3000" 2>/dev/null || true
    # Write token directly to config
    CFG_PATH="$REPO_ROOT/.multica/config.json"
    if [ -f "$CFG_PATH" ]; then
      sed -i 's/"token": *"[^"]*"/"token": "'"$OLD_TOKEN"'"/' "$CFG_PATH" 2>/dev/null || true
    fi
    echo "✓ Token migrated"
  fi
fi

# Check auth status
AUTH_OK=false
if AUTH_OUTPUT=$("$MULTICA_BIN" auth status 2>&1); then
  if echo "$AUTH_OUTPUT" | grep -qi "logged in\|authenticated\|token"; then
    AUTH_OK=true
  fi
fi

# Auto-login if not authenticated
if [ "$AUTH_OK" != true ]; then
  echo ""
  echo "─── ⚠ Authenticating ──────────────────────────────"

  # Read stored email or prompt
  CFG_FILE="$REPO_ROOT/.multica/config.json"
  STORED_EMAIL=$(grep -oP '"auth_email":\s*"\K[^"]+' "$CFG_FILE" 2>/dev/null || true)

  if [ -z "$STORED_EMAIL" ]; then
    # Check env var, then interactive prompt, then fallback
    if [ -n "${MULTICA_AUTH_EMAIL:-}" ]; then
      STORED_EMAIL="$MULTICA_AUTH_EMAIL"
    else
      echo "  Enter the email you used to log into the web UI:"
      printf "  Email: "
      read -r STORED_EMAIL
      if [ -z "$STORED_EMAIL" ]; then
        echo "✗ No email provided. Run again with:"
        echo "    MULTICA_AUTH_EMAIL=you@email.com ./run.sh"
        echo "  Or authenticate manually:"
        echo "    $MULTICA_BIN login"
        echo ""
        exit 1
      fi
    fi
    # Save email for next run
    "$MULTICA_BIN" config set server_url "http://localhost:8080" 2>/dev/null || true
    "$MULTICA_BIN" config set app_url "http://localhost:3000" 2>/dev/null || true
    # Inject auth_email into config.json
    if [ -f "$CFG_FILE" ]; then
      sed -i 's/}$/,"auth_email": "'"$STORED_EMAIL"'"}/' "$CFG_FILE" 2>/dev/null || true
    fi
  fi

  echo "  Email: $STORED_EMAIL"

  # Step 1: Send code (triggers dev code 888888)
  echo "  Sending verification code..."
  curl -sf -X POST "http://localhost:8080/auth/send-code" \
    -H "Content-Type: application/json" \
    -d "{\"email\": \"$STORED_EMAIL\"}" > /dev/null 2>&1 || true
  sleep 1

  # Step 2: Verify with dev code
  echo "  Verifying with code 888888..."
  AUTH_RESP=$(curl -sf -X POST "http://localhost:8080/auth/verify-code" \
    -H "Content-Type: application/json" \
    -d "{\"email\": \"$STORED_EMAIL\", \"code\": \"888888\"}" 2>/dev/null || echo "")

  TOKEN=$(echo "$AUTH_RESP" | grep -oP '"token":\s*"\K[^"]+' || true)

  if [ -n "$TOKEN" ]; then
    echo "  ✓ Authenticated!"
    # Write token to config.json
    if [ -f "$CFG_FILE" ]; then
      sed -i 's/"token": *"[^"]*"/"token": "'"$TOKEN"'"/' "$CFG_FILE" 2>/dev/null || true
      # If no token field exists, add it before closing brace
      grep -q '"token"' "$CFG_FILE" 2>/dev/null || \
        sed -i 's/}$/,"token": "'"$TOKEN"'"}/' "$CFG_FILE" 2>/dev/null || true
    fi
    AUTH_OK=true
  else
    echo "  ✗ Auto-login failed."
    echo "  Response: $(echo "$AUTH_RESP" | head -c 200)"
    echo ""
    echo "  Try running manually:"
    echo "    $MULTICA_BIN login"
    echo "  (opens browser — use email + code from backend logs)"
    echo ""
  fi
  echo "────────────────────────────────────────────────────"
  echo ""
fi

# ---------- Daemon ----------
if [ "$AUTH_OK" = true ]; then
  echo "==> Starting daemon (background)..."
  "$MULTICA_BIN" daemon stop 2>/dev/null || true
  "$MULTICA_BIN" daemon start 2>&1 || {
    echo "⚠ Daemon start had issues — check logs: $MULTICA_BIN daemon logs"
  }
  echo "✓ Daemon started"
  echo "   Status: $MULTICA_BIN daemon status"
  echo "   Logs:   $MULTICA_BIN daemon logs"
fi

echo ""
echo "─── Commands ────────────────────────────────────────"
echo "  Start:           ./run.sh"
echo "  Stop:            ./stop.sh"
echo "  Update:          ./update.sh"
echo "  Daemon status:   $MULTICA_BIN daemon status"
echo "  Daemon logs:     $MULTICA_BIN daemon logs"
echo "  Container logs:  docker compose -f docker-compose.selfhost.yml logs -f"
echo "────────────────────────────────────────────────────"
