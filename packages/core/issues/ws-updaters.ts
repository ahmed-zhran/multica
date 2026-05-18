import type { QueryClient } from "@tanstack/react-query";
import { issueKeys } from "./queries";
import { labelKeys } from "../labels/queries";
import {
  findIssueLocation,
  patchIssueInBuckets,
} from "./cache-helpers";
import { cleanupDeletedIssueCaches } from "./delete-cache";
import type { Issue, IssueLabelsResponse, Label } from "../types";
import type { ListIssuesCache } from "../types";

/**
 * Issue created elsewhere (WS broadcast). With server-authoritative sorting we
 * cannot place the issue in the right spot without knowing every mounted sort
 * variant, so we invalidate the whole list prefix and let TanStack refetch the
 * first page. Same for assignee-grouped caches whose ORDER BY also depends on
 * server sort. The `my` caches are covered by `myAll` prefix invalidation.
 */
export function onIssueCreated(
  qc: QueryClient,
  wsId: string,
  issue: Issue,
) {
  qc.invalidateQueries({ queryKey: issueKeys.list(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.myAll(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.assigneeGroupsAll(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.myAssigneeGroupsAll(wsId) });
  if (issue.parent_issue_id) {
    qc.invalidateQueries({ queryKey: issueKeys.children(wsId, issue.parent_issue_id) });
    qc.invalidateQueries({ queryKey: issueKeys.childProgress(wsId) });
  }
}

/**
 * Issue updated elsewhere (WS broadcast). Plan v4 §Open-Q 2 collapses the
 * earlier "patch in place when sort field unaffected" optimisation: it added a
 * lot of cache surface and field-level branching for a microscopic win, and
 * with server-sorted lists almost every update can shift order. We invalidate
 * the workspace list / my-issues / assignee group prefixes and let the server
 * resort.
 *
 * Detail cache is still patched in place — it's not sorted, so the field
 * merge is correct, and avoiding the refetch keeps the open issue's UI from
 * blinking on every keystroke broadcast.
 *
 * Parent-children caches need the old vs new parent_issue_id to keep both
 * trees coherent; we look up the old parent across any mounted list variant
 * before invalidation.
 */
export function onIssueUpdated(
  qc: QueryClient,
  wsId: string,
  issue: Partial<Issue> & { id: string },
) {
  const detailData = qc.getQueryData<Issue>(issueKeys.detail(wsId, issue.id));
  let oldParentId: string | null = detailData?.parent_issue_id ?? null;
  if (!oldParentId) {
    for (const [, cache] of qc.getQueriesData<ListIssuesCache>({
      queryKey: issueKeys.list(wsId),
    })) {
      if (!cache) continue;
      const loc = findIssueLocation(cache, issue.id);
      if (loc) {
        oldParentId = loc.issue.parent_issue_id;
        break;
      }
    }
  }
  const newParentId = issue.parent_issue_id ?? null;
  const parentChanged =
    issue.parent_issue_id !== undefined && newParentId !== oldParentId;

  qc.invalidateQueries({ queryKey: issueKeys.list(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.myAll(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.assigneeGroupsAll(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.myAssigneeGroupsAll(wsId) });
  qc.setQueryData<Issue>(issueKeys.detail(wsId, issue.id), (old) =>
    old ? { ...old, ...issue } : old,
  );

  if (oldParentId) {
    qc.invalidateQueries({ queryKey: issueKeys.children(wsId, oldParentId) });
  }
  if (newParentId && parentChanged) {
    qc.invalidateQueries({ queryKey: issueKeys.children(wsId, newParentId) });
  }
  if (oldParentId || newParentId) {
    if (issue.status !== undefined || issue.parent_issue_id !== undefined) {
      qc.invalidateQueries({ queryKey: issueKeys.childProgress(wsId) });
    }
  }
}

/**
 * Patch an issue's labels in-place across every mounted list / my-list
 * variant + the detail cache + the per-issue label cache. Triggered by the
 * `issue_labels:changed` WS event after attach/detach so list/board chips
 * and the issue-detail Properties LabelPicker update without a refetch.
 *
 * Why prefix-patch instead of invalidate: labels don't affect any sort key,
 * so the existing row positions stay correct — patching in place avoids the
 * cascade of refetches an invalidate would trigger on every label change,
 * which is noisy on AI workspaces where agents reshape labels frequently.
 *
 * The byIssue cache backs `LabelPicker`; without patching it, externally
 * driven label changes (agents, other tabs) leave the picker stale until it
 * remounts — `staleTime: Infinity` + `refetchOnWindowFocus: false` (see
 * `query-client.ts`) means focus changes won't recover it.
 */
export function onIssueLabelsChanged(
  qc: QueryClient,
  wsId: string,
  issueId: string,
  labels: Label[],
) {
  const labelPatch = (old: ListIssuesCache | undefined) =>
    old ? patchIssueInBuckets(old, issueId, { labels }) : old;
  qc.setQueriesData<ListIssuesCache>({ queryKey: issueKeys.list(wsId) }, labelPatch);
  qc.setQueriesData<ListIssuesCache>({ queryKey: issueKeys.myAll(wsId) }, labelPatch);
  qc.setQueryData<Issue>(issueKeys.detail(wsId, issueId), (old) =>
    old ? { ...old, labels } : old,
  );
  qc.setQueryData<IssueLabelsResponse>(labelKeys.byIssue(wsId, issueId), (old) =>
    old ? { ...old, labels } : old,
  );
  qc.invalidateQueries({ queryKey: issueKeys.assigneeGroupsAll(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.myAssigneeGroupsAll(wsId) });
}

export function onIssueDeleted(
  qc: QueryClient,
  wsId: string,
  issueId: string,
) {
  cleanupDeletedIssueCaches(qc, wsId, issueId);
  qc.invalidateQueries({ queryKey: issueKeys.assigneeGroupsAll(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.myAssigneeGroupsAll(wsId) });
}

/**
 * Issue position bucket was rebalanced by the server (see
 * `position_rebalance.go`). The new positions are server-authoritative and
 * affect ordering across every sort variant that touches `position` directly
 * (Manual / position sort), plus the assignee-grouped views whose inner
 * ORDER BY still mentions position. We invalidate all of these prefixes so
 * TanStack refetches and the user sees the rebalanced order in place.
 *
 * `items` is intentionally not consumed here: the server already committed
 * before publishing, so the refetch will pick up the new positions verbatim.
 * Building a client-side reordered array would mean replicating the server
 * ORDER BY (including direction toggles, NULLS LAST quirks, the priority CASE
 * expression) — an obvious source of drift bugs.
 */
export function onIssueRebalanced(
  qc: QueryClient,
  wsId: string,
  _status: string,
  _items: { id: string; position: number }[],
) {
  qc.invalidateQueries({ queryKey: issueKeys.list(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.myAll(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.assigneeGroupsAll(wsId) });
  qc.invalidateQueries({ queryKey: issueKeys.myAssigneeGroupsAll(wsId) });
}

/**
 * Used when the `issue:rebalanced` WS payload fails schema validation. We
 * don't know which bucket changed, so invalidate the same prefixes — a
 * conservative, best-effort recovery that keeps the UI consistent.
 */
export function onIssueRebalancedFallback(qc: QueryClient, wsId: string) {
  onIssueRebalanced(qc, wsId, "", []);
}
