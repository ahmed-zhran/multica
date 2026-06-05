#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

echo "================================================"
echo "  Multica — Self-hosted Server Runner"
echo "  Repo: $REPO_ROOT"
echo "================================================"
echo ""

# ---------- Prerequisites ----------
command -v docker >/dev/null 2>&1 || { echo "✗ Docker is required. Install it first."; exit 1; }

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
echo "✓ Multica is running!"
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

echo ""
echo "─── Commands ────────────────────────────────────────"
echo "  Multica CLI:     export MULTICA_HOME=\"$REPO_ROOT\""
echo "                   export MULTICA_WORKSPACES_ROOT=\"$REPO_ROOT/workspaces\""
echo "                   export PATH=\"$REPO_ROOT/server/bin:\$PATH\""
echo ""
echo "  View containers: docker compose -f docker-compose.selfhost.yml ps"
echo "  View logs:       docker compose -f docker-compose.selfhost.yml logs -f"
echo "  Stop:            docker compose -f docker-compose.selfhost.yml down"
echo "  Update:          ./update.sh"
echo "────────────────────────────────────────────────────"
