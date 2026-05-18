import { describe, expect, it } from "vitest";
import {
  IssueRebalancedPayloadSchema,
  EMPTY_ISSUE_REBALANCED_PAYLOAD,
} from "./schemas";
import { parseWithFallback } from "./schema";

// Guards the contract from MUL-2314 plan v4 Blocker A: `issue:rebalanced` is a
// newly introduced WebSocket event, and its payload must traverse the same
// parseWithFallback boundary as REST responses do. We verify three scenarios:
//   1) happy path produces the parsed payload
//   2) totally malformed payload falls back to the empty constant
//   3) lenient fields (status enum, items shape) accept partial data without
//      throwing into the WS handler
describe("IssueRebalancedPayloadSchema", () => {
  const endpoint = { endpoint: "ws:issue:rebalanced" } as const;

  it("parses a valid payload", () => {
    const result = parseWithFallback(
      {
        workspace_id: "ws-1",
        status: "todo",
        items: [
          { id: "issue-1", position: 1 },
          { id: "issue-2", position: 2.5 },
        ],
      },
      IssueRebalancedPayloadSchema,
      EMPTY_ISSUE_REBALANCED_PAYLOAD,
      endpoint,
    );
    expect(result.workspace_id).toBe("ws-1");
    expect(result.status).toBe("todo");
    expect(result.items).toHaveLength(2);
  });

  it("falls back when the payload is malformed at the top level", () => {
    const result = parseWithFallback(
      "this is not an object",
      IssueRebalancedPayloadSchema,
      EMPTY_ISSUE_REBALANCED_PAYLOAD,
      endpoint,
    );
    expect(result).toBe(EMPTY_ISSUE_REBALANCED_PAYLOAD);
  });

  it("accepts payloads with an unknown status value (lenient enum)", () => {
    const result = parseWithFallback(
      {
        workspace_id: "ws-1",
        status: "status_value_added_in_a_future_release",
        items: [],
      },
      IssueRebalancedPayloadSchema,
      EMPTY_ISSUE_REBALANCED_PAYLOAD,
      endpoint,
    );
    expect(result.workspace_id).toBe("ws-1");
    expect(result.status).toBe("status_value_added_in_a_future_release");
  });

  it("defaults `items` to [] when the server omits it", () => {
    const result = parseWithFallback(
      { workspace_id: "ws-1", status: "todo" },
      IssueRebalancedPayloadSchema,
      EMPTY_ISSUE_REBALANCED_PAYLOAD,
      endpoint,
    );
    expect(result.items).toEqual([]);
  });
});
