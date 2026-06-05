#!/usr/bin/env bash
set -euo pipefail

# project-link.sh — Bind a Multica project to a local directory
#
# Usage:
#   ./project-link.sh list-projects                    # list available projects
#   ./project-link.sh list-resources <project-id>       # view linked directories
#   ./project-link.sh add <project-id> <path> [label]  # link project → dir
#   ./project-link.sh remove <project-id> <res-id>      # remove a link
#
# The daemon must be running. The daemon ID is auto-detected.
#
# Examples:
#   ./project-link.sh list-projects
#   ./project-link.sh add ae21ddd2 /data/projects/aurora "Aurora monorepo"
#   ./project-link.sh list-resources ae21ddd2

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
export MULTICA_HOME="$REPO_ROOT"
export PATH="$REPO_ROOT/server/bin:$PATH"
MULTICA_BIN="$REPO_ROOT/server/bin/multica"

CMD="${1:-help}"

get_daemon_id() {
  "$MULTICA_BIN" daemon status --output json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('daemon_id',''))" 2>/dev/null || true
}

case "$CMD" in
  add)
    if [ $# -lt 3 ]; then
      echo "Usage: $0 add <project-id> <absolute-path> [label]"
      echo ""
      echo "  Find project IDs: ./project-link.sh list-projects"
      exit 1
    fi
    PROJECT_ID="$2"
    LOCAL_PATH="$3"
    LABEL="${4:-$(basename "$LOCAL_PATH")}"

    # Resolve to absolute path
    LOCAL_PATH="$(realpath -m "$LOCAL_PATH" 2>/dev/null || echo "$LOCAL_PATH")"

    if [ ! -d "$LOCAL_PATH" ]; then
      echo "✗ Directory does not exist: $LOCAL_PATH" >&2
      exit 1
    fi

    DAEMON_ID=$(get_daemon_id)
    if [ -z "$DAEMON_ID" ]; then
      echo "✗ Daemon not running. Start it with ./run.sh" >&2
      exit 1
    fi

    echo "==> Linking project '$PROJECT_ID' → $LOCAL_PATH"
    "$MULTICA_BIN" project resource add "$PROJECT_ID" \
      --type local_directory \
      --local-path "$LOCAL_PATH" \
      --daemon-id "$DAEMON_ID" \
      --label "$LABEL"
    echo ""
    echo "✓ Done! Agents assigned to this project will work directly in: $LOCAL_PATH"
    echo "  (instead of a synthetic scratch directory)"
    ;;

  remove)
    if [ $# -lt 3 ]; then
      echo "Usage: $0 remove <project-id> <resource-id>"
      exit 1
    fi
    PROJECT_ID="$2"
    RESOURCE_ID="$3"
    echo "==> Removing resource $RESOURCE_ID from project '$PROJECT_ID'"
    "$MULTICA_BIN" project resource remove "$PROJECT_ID" "$RESOURCE_ID"
    echo "✓ Removed"
    ;;

  list-resources)
    PROJECT_ID="${2:-}"
    if [ -z "$PROJECT_ID" ]; then
      echo "Usage: $0 list-resources <project-id>"
      exit 1
    fi
    echo "==> Resources for project '$PROJECT_ID':"
    "$MULTICA_BIN" project resource list "$PROJECT_ID" --output table
    ;;

  list-projects)
    echo "==> Projects:"
    "$MULTICA_BIN" project list --output table
    ;;

  *)
    echo "Multica — Link Project to Local Directory"
    echo ""
    echo "Usage:"
    echo "  ./project-link.sh list-projects                   # list all projects"
    echo "  ./project-link.sh list-resources <id>             # view linked dirs"
    echo "  ./project-link.sh add <project-id> <path> [label] # link project → dir"
    echo "  ./project-link.sh remove <project-id> <res-id>    # remove a link"
    echo ""
    echo "Examples:"
    echo "  ./project-link.sh list-projects"
    echo "  ./project-link.sh add ae21ddd2 /data/projects/aurora"
    echo "  ./project-link.sh list-resources ae21ddd2"
    exit 1
    ;;
esac