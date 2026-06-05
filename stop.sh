#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
MULTICA_BIN="$REPO_ROOT/server/bin/multica"

echo "→ Stopping Multica daemon..."
if [ -f "$MULTICA_BIN" ]; then
  "$MULTICA_BIN" daemon stop 2>/dev/null || echo "  (daemon wasn't running)"
else
  echo "  (CLI not found — skipping)"
fi

echo "→ Stopping Multica server stack..."
cd "$REPO_ROOT"
docker compose -f docker-compose.selfhost.yml down

echo ""
echo "✓ Everything stopped. Data preserved in:"
echo "   pgdata/ uploads/ workspaces/ .multica/"
