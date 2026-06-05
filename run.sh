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

# ---------- CLI Binary ----------
MULTICA_BIN="$REPO_ROOT/server/bin/multica"
if [ ! -f "$MULTICA_BIN" ]; then
  echo "==> Downloading Multica CLI binary..."
  mkdir -p "$REPO_ROOT/server/bin"

  # Fetch the latest release tag from GitHub
  echo "   Fetching latest release..."
  TAG=$(curl -sI "https://github.com/multica-ai/multica/releases/latest" | \
    grep -i "^location:" | sed 's|.*/v|v|' | tr -d '[:space:]')
  if [ -z "$TAG" ]; then
    TAG="v0.3.17"
    echo "   (auto-detection failed, using $TAG)"
  fi
  VERSION="${TAG#v}"

  echo "   Downloading multica-cli-${VERSION}-linux-amd64.tar.gz ..."
  curl -fsSL "https://github.com/multica-ai/multica/releases/download/${TAG}/multica-cli-${VERSION}-linux-amd64.tar.gz" \
    -o /tmp/multica.tar.gz
  tar -xzf /tmp/multica.tar.gz -C /tmp/ multica
  mv /tmp/multica "$MULTICA_BIN"
  chmod +x "$MULTICA_BIN"
  rm -f /tmp/multica.tar.gz
  echo "✓ CLI binary installed: $MULTICA_BIN"
fi

# ---------- Environment file ----------
if [ ! -f .env ]; then
  echo "==> Creating .env from .env.example..."
  cp .env.example .env

  # Generate a random JWT_SECRET
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

# ---------- Auth Check ----------
AUTH_OK=false
if AUTH_OUTPUT=$("$MULTICA_BIN" auth status 2>&1); then
  if echo "$AUTH_OUTPUT" | grep -qi "logged in\|authenticated\|token"; then
    AUTH_OK=true
  fi
fi

# ---------- Daemon ----------
if [ "$AUTH_OK" = true ]; then
  echo "==> Starting daemon (background)..."
  "$MULTICA_BIN" daemon stop 2>/dev/null || true  # Clean up any stale daemon
  "$MULTICA_BIN" daemon start 2>&1 || {
    echo "⚠ Daemon start had issues — check logs with: $MULTICA_BIN daemon logs"
  }
  echo "✓ Daemon started"
  echo "   Status: $MULTICA_BIN daemon status"
  echo "   Logs:   $MULTICA_BIN daemon logs"
else
  echo ""
  echo "─── ⚠ One-time auth required ──────────────────────"
  echo "  The daemon needs to log in to your server once."
  echo "  Run this command:"
  echo ""
  echo "    $MULTICA_BIN login"
  echo ""
  echo "  This opens a browser — enter your email and the"
  echo "  verification code shown in the backend logs."
  echo ""
  echo "  After that, run ./run.sh again and the daemon"
  echo "  will start automatically."
  echo "────────────────────────────────────────────────────"
  echo ""
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
