import { describe, it, expect } from "vitest";
import sitemap from "./sitemap";

describe("sitemap", () => {
  it("includes /usecases/squads with priority 0.8", () => {
    const entries = sitemap();
    const entry = entries.find((e) => e.url.endsWith("/usecases/squads"));
    expect(entry).toBeDefined();
    expect(entry?.priority).toBe(0.8);
    expect(entry?.changeFrequency).toBe("weekly");
  });
});
