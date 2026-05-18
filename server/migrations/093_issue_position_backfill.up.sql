-- Backfill the `position` column so existing issues get sparse, deterministic
-- values inside each (workspace_id, status) bucket. Until now all rows wrote
-- `position = 0`, which collapsed the fractional indexing scheme (the (prev+next)/2
-- midpoint between two zeros is still zero, so mid-list drag-drop was a no-op).
--
-- Direction: newest first. ROW_NUMBER ordered by `created_at DESC, id DESC` means
-- the most-recently-created issue gets position = 1, the next gets 2, etc.
-- New issues are assigned `MIN(position) - 1.0` at create time, so under the
-- legacy `ORDER BY position ASC, created_at DESC` ordering still used by older
-- desktop clients, newly created issues continue to land at the top of the bucket.
--
-- Batching: there is no LIMIT here on purpose. The migration runs once during
-- deploy windowing, not on a hot loop. For workspaces that have grown large
-- enough to warrant batched backfill, the project runbook documents running this
-- SQL in chunks of 1000-10000 rows during a low-traffic window with a snapshot
-- of `position` taken beforehand so a one-shot rollback is possible.
WITH ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (
               PARTITION BY workspace_id, status
               ORDER BY created_at DESC, id DESC
           )::float8 AS new_pos
    FROM issue
)
UPDATE issue
SET position = ranked.new_pos
FROM ranked
WHERE issue.id = ranked.id;

-- Composite index used by GetMinIssuePosition on the create path and by the
-- bucket-scoped rebalance worker. `IF NOT EXISTS` so this is safe to re-run
-- if an earlier deploy left the index behind for any reason.
CREATE INDEX IF NOT EXISTS idx_issue_workspace_status_position
    ON issue (workspace_id, status, position);
