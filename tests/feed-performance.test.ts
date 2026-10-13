import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("feed performance boundaries", () => {
  const apiSource = readFileSync(new URL("../netlify/functions/api.mts", import.meta.url), "utf8");
  const migration = readFileSync(new URL("../database/migrations/003_feed_performance.sql", import.meta.url), "utf8");

  it("keeps snapshots conditional and timelines on demand", () => {
    expect(apiSource).toContain('requestUrl.searchParams.get("since")');
    expect(apiSource).toContain("return notModified(revision)");
    expect(apiSource).toContain("/^\\/sessions\\/([^/]+)\\/events$/");
    expect(apiSource).toContain("left join lateral");
    expect(apiSource).toContain("limit 100");
  });

  it("writes session state and its event in one database transaction", () => {
    expect(apiSource).toContain("sql.transaction([");
  });

  it("ranks run identity by source start rather than delayed ingestion", () => {
    expect(apiSource).toContain("order by started_at desc nulls last, last_event_at desc, id desc");
  });

  it("indexes snapshot revisions, freshness, task ranking, and event revisions", () => {
    expect(migration).toContain("agent_sessions_updated_at_idx");
    expect(migration).toContain("agent_sessions_active_freshness_idx");
    expect(migration).toContain("agent_sessions_task_recency_idx");
    expect(migration).toContain("agent_events_created_at_idx");
  });
});
