DROP INDEX IF EXISTS idx_issue_workspace_status_position;

-- Cannot losslessly reverse the backfill; the original value was 0.0 for every
-- row. Reset to 0.0 so the bucket ordering falls back to `created_at DESC` and
-- behaves like pre-migration state for older clients that read `position` directly.
UPDATE issue SET position = 0;
