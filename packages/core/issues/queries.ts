import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";
import type {
  GroupedIssuesResponse,
  IssueSortBy,
  IssueSortDirection,
  IssueStatus,
  ListGroupedIssuesParams,
  ListIssuesParams,
  ListIssuesCache,
} from "../types";
import { BOARD_STATUSES } from "./config";

/**
 * Sort tuple used to vary issue list cache identity by sort dimension.
 *
 * Why this exists: the workspace issue list is now server-sorted (the legacy
 * client-side `sortIssues()` was removed in MUL-2314). Switching `sortBy` must
 * trigger a new fetch — TanStack Query keys mutation off `queryKey` equality,
 * so the sort tuple has to be part of the key for an active query, and stay
 * OUT of the key when we want to address every sorted variant at once
 * (invalidate-all, `setQueriesData` for optimistic patches that don't change
 * ordering, etc.).
 *
 * The convention nailed down by the v4 plan:
 *   - mounted queries (`issueListOptions`, `useLoadMoreByStatus` setQueryData)
 *     ALWAYS pass the sort tuple — they target one specific variant.
 *   - prefix operations (`invalidateQueries`, `setQueriesData`,
 *     `getQueriesData`, `cancelQueries`) ALWAYS leave it off — TanStack's
 *     default `exact: false` matches every variant under the prefix.
 *   - exact reads after a key migration (e.g. delete-cache parent lookup,
 *     mention suggestion) use `getQueriesData` with the prefix instead of
 *     `getQueryData` exact, since they don't know which sort is mounted.
 */
export interface IssueListSort {
  sortBy: IssueSortBy;
  sortDirection: IssueSortDirection;
}

type IssueListPrefixKey = readonly ["issues", string, "list"];
type IssueListExactKey = readonly ["issues", string, "list", IssueListSort];
type IssueMyListPrefixKey = readonly ["issues", string, "my", string, MyIssuesFilter];
type IssueMyListExactKey = readonly ["issues", string, "my", string, MyIssuesFilter, IssueListSort];

function listKey(wsId: string, sort?: IssueListSort): IssueListPrefixKey | IssueListExactKey {
  const prefix: IssueListPrefixKey = ["issues", wsId, "list"];
  return sort ? [...prefix, sort] : prefix;
}

function myListKey(
  wsId: string,
  scope: string,
  filter: MyIssuesFilter,
  sort?: IssueListSort,
): IssueMyListPrefixKey | IssueMyListExactKey {
  const prefix: IssueMyListPrefixKey = ["issues", wsId, "my", scope, filter];
  return sort ? [...prefix, sort] : prefix;
}

interface IssueListKey {
  (wsId: string): IssueListPrefixKey;
  (wsId: string, sort: IssueListSort): IssueListExactKey;
}

interface IssueMyListKey {
  (wsId: string, scope: string, filter: MyIssuesFilter): IssueMyListPrefixKey;
  (wsId: string, scope: string, filter: MyIssuesFilter, sort: IssueListSort): IssueMyListExactKey;
}

export const issueKeys = {
  all: (wsId: string) => ["issues", wsId] as const,
  /**
   * Issue list key — pass `sort` for a specific variant (mounted query, load-more
   * setQueryData), omit it for a prefix key (invalidate, setQueriesData,
   * getQueriesData).
   */
  list: ((wsId: string, sort?: IssueListSort) =>
    listKey(wsId, sort)) as IssueListKey,
  assigneeGroupsAll: (wsId: string) =>
    [...issueKeys.all(wsId), "assignee-groups"] as const,
  assigneeGroups: (wsId: string, filter: AssigneeGroupedIssuesFilter) =>
    [...issueKeys.assigneeGroupsAll(wsId), filter] as const,
  /** All "my issues" queries — use for bulk invalidation. */
  myAll: (wsId: string) => [...issueKeys.all(wsId), "my"] as const,
  /**
   * Per-scope "my issues" list — same sort tuple convention as `list`.
   */
  myList: ((wsId: string, scope: string, filter: MyIssuesFilter, sort?: IssueListSort) =>
    myListKey(wsId, scope, filter, sort)) as IssueMyListKey,
  myAssigneeGroupsAll: (wsId: string) =>
    [...issueKeys.myAll(wsId), "assignee-groups"] as const,
  myAssigneeGroups: (
    wsId: string,
    scope: string,
    filter: AssigneeGroupedIssuesFilter,
  ) => [...issueKeys.myAssigneeGroupsAll(wsId), scope, filter] as const,
  detail: (wsId: string, id: string) =>
    [...issueKeys.all(wsId), "detail", id] as const,
  children: (wsId: string, id: string) =>
    [...issueKeys.all(wsId), "children", id] as const,
  childProgress: (wsId: string) =>
    [...issueKeys.all(wsId), "child-progress"] as const,
  /** Full-issue timeline (single TanStack Query, no cursor). */
  timeline: (issueId: string) =>
    ["issues", "timeline", issueId] as const,
  reactions: (issueId: string) => ["issues", "reactions", issueId] as const,
  subscribers: (issueId: string) =>
    ["issues", "subscribers", issueId] as const,
  usage: (issueId: string) => ["issues", "usage", issueId] as const,
  /** Issue-level attachments — used by the description editor so its
   *  inline file-card / image NodeViews can re-sign download URLs at
   *  click time. */
  attachments: (issueId: string) => ["issues", "attachments", issueId] as const,
  /** Per-issue task list (issue-detail Execution log section). */
  tasks: (issueId: string) => ["issues", "tasks", issueId] as const,
  /** Prefix-match key for invalidating tasks across all issues — used by
   *  the global WS task: prefix path so any task lifecycle event refreshes
   *  every per-issue list, regardless of which issue is currently mounted. */
  tasksAll: () => ["issues", "tasks"] as const,
};

export type MyIssuesFilter = Pick<
  ListIssuesParams,
  "assignee_id" | "assignee_ids" | "creator_id" | "project_id"
>;

export type AssigneeGroupedIssuesFilter = Omit<
  ListGroupedIssuesParams,
  "group_by" | "limit" | "offset" | "group_assignee_type" | "group_assignee_id"
>;

/** Page size per status column. */
export const ISSUE_PAGE_SIZE = 50;

/** Statuses the issues/my-issues pages paginate. Cancelled is intentionally excluded — it has never been surfaced in the list/board views. */
export const PAGINATED_STATUSES: readonly IssueStatus[] = BOARD_STATUSES;

/** Flatten a bucketed response to a single Issue[] for consumers that want the whole list. */
export function flattenIssueBuckets(data: ListIssuesCache) {
  const out = [];
  for (const status of PAGINATED_STATUSES) {
    const bucket = data.byStatus[status];
    if (bucket) out.push(...bucket.issues);
  }
  return out;
}

async function fetchFirstPages(
  filter: MyIssuesFilter = {},
  sort?: IssueListSort,
): Promise<ListIssuesCache> {
  const responses = await Promise.all(
    PAGINATED_STATUSES.map((status) =>
      api.listIssues({
        status,
        limit: ISSUE_PAGE_SIZE,
        offset: 0,
        ...filter,
        ...(sort
          ? { sort_by: sort.sortBy, sort_direction: sort.sortDirection }
          : {}),
      }),
    ),
  );
  const byStatus: ListIssuesCache["byStatus"] = {};
  PAGINATED_STATUSES.forEach((status, i) => {
    const res = responses[i]!;
    byStatus[status] = { issues: res.issues, total: res.total };
  });
  return { byStatus };
}

/**
 * CACHE SHAPE NOTE: The raw cache stores {@link ListIssuesCache} (buckets keyed
 * by status, each with `{ issues, total }`), and `select` flattens it to
 * `Issue[]` for consumers. Mutations and ws-updaters must use
 * `setQueryData<ListIssuesCache>(...)` and preserve the byStatus shape.
 *
 * Fetches the first page of each paginated status in parallel. Use
 * {@link useLoadMoreByStatus} to paginate a specific status into the cache.
 */
export function issueListOptions(wsId: string, sort: IssueListSort) {
  return queryOptions({
    queryKey: issueKeys.list(wsId, sort),
    queryFn: () => fetchFirstPages({}, sort),
    select: flattenIssueBuckets,
  });
}

export function issueAssigneeGroupsOptions(
  wsId: string,
  filter: AssigneeGroupedIssuesFilter,
  sort: IssueListSort,
) {
  // The sort tuple is part of the filter object that feeds into the queryKey —
  // adding it directly into the filter (rather than as a sibling key segment)
  // keeps `issueKeys.assigneeGroups` identity-stable for invalidation and lets
  // `useLoadMoreByAssigneeGroup` reuse the same key without a separate sort
  // overload.
  const filterWithSort = { ...filter, ...sort };
  return queryOptions<GroupedIssuesResponse>({
    queryKey: issueKeys.assigneeGroups(wsId, filterWithSort),
    queryFn: () =>
      api.listGroupedIssues({
        group_by: "assignee",
        limit: ISSUE_PAGE_SIZE,
        offset: 0,
        ...filter,
        sort_by: sort.sortBy,
        sort_direction: sort.sortDirection,
      }),
  });
}

/**
 * Server-filtered issue list for the My Issues page.
 * Each scope gets its own cache entry so switching tabs is instant after first load.
 */
export function myIssueListOptions(
  wsId: string,
  scope: string,
  filter: MyIssuesFilter,
  sort: IssueListSort,
) {
  return queryOptions({
    queryKey: issueKeys.myList(wsId, scope, filter, sort),
    queryFn: () => fetchFirstPages(filter, sort),
    select: flattenIssueBuckets,
  });
}

export function myIssueAssigneeGroupsOptions(
  wsId: string,
  scope: string,
  filter: AssigneeGroupedIssuesFilter,
  sort: IssueListSort,
) {
  const filterWithSort = { ...filter, ...sort };
  return queryOptions<GroupedIssuesResponse>({
    queryKey: issueKeys.myAssigneeGroups(wsId, scope, filterWithSort),
    queryFn: () =>
      api.listGroupedIssues({
        group_by: "assignee",
        limit: ISSUE_PAGE_SIZE,
        offset: 0,
        ...filter,
        sort_by: sort.sortBy,
        sort_direction: sort.sortDirection,
      }),
  });
}

export function issueDetailOptions(wsId: string, id: string) {
  return queryOptions({
    queryKey: issueKeys.detail(wsId, id),
    queryFn: () => api.getIssue(id),
  });
}

export function childIssueProgressOptions(wsId: string) {
  return queryOptions({
    queryKey: issueKeys.childProgress(wsId),
    queryFn: () => api.getChildIssueProgress(),
    select: (data) => {
      const map = new Map<string, { done: number; total: number }>();
      for (const entry of data.progress) {
        map.set(entry.parent_issue_id, { done: entry.done, total: entry.total });
      }
      return map;
    },
  });
}

export function childIssuesOptions(wsId: string, id: string) {
  return queryOptions({
    queryKey: issueKeys.children(wsId, id),
    queryFn: () => api.listChildIssues(id).then((r) => r.issues),
  });
}

/**
 * Single-fetch timeline options. The endpoint returns the full ordered set of
 * comments + activities for an issue (server caps at 2000 as a safety net).
 * Cursor pagination was removed in #1929 — at observed data sizes (p99 ~30
 * entries per issue) it added complexity without a UX win and broke reply
 * threads at page boundaries.
 */
export function issueTimelineOptions(issueId: string) {
  return queryOptions({
    queryKey: issueKeys.timeline(issueId),
    queryFn: () => api.listTimeline(issueId),
  });
}

export function issueReactionsOptions(issueId: string) {
  return queryOptions({
    queryKey: issueKeys.reactions(issueId),
    queryFn: async () => {
      const issue = await api.getIssue(issueId);
      return issue.reactions ?? [];
    },
  });
}

export function issueSubscribersOptions(issueId: string) {
  return queryOptions({
    queryKey: issueKeys.subscribers(issueId),
    queryFn: () => api.listIssueSubscribers(issueId),
  });
}

export function issueUsageOptions(issueId: string) {
  return queryOptions({
    queryKey: issueKeys.usage(issueId),
    queryFn: () => api.getIssueUsage(issueId),
  });
}

// Backs the description editor's fresh-sign download flow: NodeViews resolve
// an attachment id by matching the markdown URL against this list. The list
// is workspace-private metadata and lives on the same cache lifetime as the
// rest of the issue detail surface.
export function issueAttachmentsOptions(issueId: string) {
  return queryOptions({
    queryKey: issueKeys.attachments(issueId),
    queryFn: () => api.listAttachments(issueId),
  });
}
