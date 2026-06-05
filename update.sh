#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

echo "================================================"
echo "  Multica — Update Script"
echo "  Repo: $REPO_ROOT"
echo "================================================"
echo ""

# ---------- Stash local changes ----------
if ! git diff --quiet; then
  echo "==> Stashing local changes..."
  git stash push -m "auto-stash before update $(date +%Y-%m-%d_%H:%M:%S)"
  STASHED=true
else
  STASHED=false
fi

# ---------- Fetch upstream changes ----------
echo "==> Fetching from upstream (multica-ai/multica)..."
git fetch upstream main

# ---------- Merge upstream into local branch ----------
LOCAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "==> Merging upstream/main into $LOCAL_BRANCH..."
if git merge upstream/main --no-edit; then
  echo "✓ Merged upstream changes"
else
  echo "✗ Merge conflict detected!"
  echo "  Resolve conflicts manually, then run:"
  echo "    git commit"
  echo "    git push origin $LOCAL_BRANCH"
  echo "    ./update.sh  # to continue with Docker update"
  exit 1
fi

# ---------- Restore stashed changes ----------
if [ "$STASHED" = true ]; then
  echo "==> Restoring local stashed changes..."
  git stash pop || true
fi

# ---------- Push to fork ----------
echo "==> Pushing to origin (ahmed-zhran/multica)..."
git push origin "$LOCAL_BRANCH"

# ---------- Pull latest Docker images ----------
echo "==> Pulling latest Docker images..."
docker compose -f docker-compose.selfhost.yml pull || {
  echo "⚠ Could not pull images. They may not be published yet."
  echo "  If you built locally, your images are unaffected."
}

# ---------- Recreate containers ----------
echo "==> Recreating containers with latest images..."
docker compose -f docker-compose.selfhost.yml up -d --remove-orphans

echo ""
echo "✓ Update complete!"
echo "   Run ./run.sh if you need to see the status."
