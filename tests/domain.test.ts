import { describe, expect, it } from "vitest";
import { activityLabel, countSessions, defaultPollingInterval, demoSessions, faviconHref, faviconStatus, faviconTitle, finishedFaviconWindowMs, hasRecentlyFinished, mapLiveEvents, mapLiveSessions, pollingIntervalLabel, pollingIntervalOptions, repositoryLabel, statusLabels, type AgentSession } from "../src/domain";

describe("agent watchr domain", () => {
  it("counts the dashboard status summary", () => {
    expect(countSessions(demoSessions)).toEqual({
      working: 1,
      needs_you: 1,
      finished: 1,
      failed: 1,
      stale: 0,
    });
  });

  it("keeps status labels human-readable", () => {
    expect(statusLabels.needs_you).toBe("Needs you");
    expect(statusLabels.finished).toBe("Finished");
  });

  it("prioritizes attention over working for the favicon", () => {
    expect(faviconStatus({ working: 0, needs_you: 0, finished: 0, failed: 0, stale: 0 })).toBe("default");
    expect(faviconStatus({ working: 1, needs_you: 0, finished: 0, failed: 0, stale: 0 })).toBe("working");
    expect(faviconStatus({ working: 1, needs_you: 1, finished: 0, failed: 0, stale: 0 })).toBe("attention");
    expect(faviconStatus({ working: 0, needs_you: 0, finished: 0, failed: 1, stale: 0 })).toBe("attention");
  });

  it("shows a finished favicon only for the recent completion window", () => {
    const now = Date.parse("2026-09-02T12:00:00.000Z");
    const finishedSession = { ...demoSessions[2], status: "finished", finishedAt: new Date(now - 60_000).toISOString() } as AgentSession;
    const expiredSession = { ...demoSessions[2], status: "finished", finishedAt: new Date(now - finishedFaviconWindowMs - 1).toISOString() } as AgentSession;

    expect(hasRecentlyFinished([finishedSession], now)).toBe(true);
    expect(faviconStatus({ working: 0, needs_you: 0, finished: 1, failed: 0, stale: 0 }, true)).toBe("finished");
    expect(hasRecentlyFinished([expiredSession], now)).toBe(false);
    expect(faviconHref("finished")).toBe("/favicon-finished.svg?status=finished");
    expect(faviconTitle("working")).toBe("Working · Status Watchr");
    expect(faviconTitle("finished")).toBe("Finished · Status Watchr");
    expect(faviconTitle("attention")).toBe("Needs attention · Status Watchr");
    expect(faviconTitle("default")).toBe("Status Watchr");
  });

  it("uses a distinct cache-busting favicon URL for each status", () => {
    expect(faviconHref("default")).toBe("/favicon.svg?status=default");
    expect(faviconHref("working")).toBe("/favicon-working.svg?status=working");
    expect(faviconHref("attention")).toBe("/favicon-attention.svg?status=attention");
  });

  it("keeps the web polling choices explicit and ordered", () => {
    expect(pollingIntervalOptions).toEqual([0, 15, 30, 60, 300]);
    expect(defaultPollingInterval).toBe(30);
    expect(pollingIntervalLabel(0)).toBe("On open / focus");
    expect(pollingIntervalLabel(15)).toBe("Every 15 seconds");
    expect(pollingIntervalLabel(300)).toBe("Every 5 minutes");
  });

  it("turns connector metadata into compact human-readable labels", () => {
    expect(repositoryLabel("https://github.com/TeamSDG/mate-the-label-shopify.git")).toBe("mate-the-label-shopify");
    expect(repositoryLabel("/Users/kylebutler/Documents/sites/status-watchr")).toBe("status-watchr");
    expect(activityLabel("local task started", "local/task/started")).toBe("Task started");
    expect(activityLabel("codex hook PermissionRequest")).toBe("Permission Request");
  });

  it("maps database sessions and events into dashboard data", () => {
    const sessions = mapLiveSessions({
      sessions: [{
        id: "thread-1",
        title: "Watch a task",
        repo: "/sites/status-watchr",
        branch: "main",
        status: "working",
        status_detail: "Activity received",
        last_seen_at: new Date().toISOString(),
        started_at: new Date(Date.now() - 120_000).toISOString(),
        finished_at: null,
      }],
      events: [{
        id: "event-1",
        session_id: "thread-1",
        event_type: "turn/started",
        label: "Turn started",
        detail: "Activity received",
        tone: "working",
        occurred_at: new Date().toISOString(),
      }],
    });

    expect(sessions[0]).toMatchObject({ id: "thread-1", status: "working", events: [{ id: "event-1", tone: "working" }] });
  });

  it("maps an on-demand timeline in newest-first order", () => {
    const events = mapLiveEvents({
      events: [
        { id: "event-1", session_id: "thread-1", event_type: "turn/started", label: "turn started", detail: null, tone: "working", occurred_at: "2026-09-03T10:00:00.000Z" },
        { id: "event-2", session_id: "thread-1", event_type: "turn/completed", label: "turn completed", detail: "Done", tone: "success", occurred_at: "2026-09-03T10:05:00.000Z" },
      ],
    });

    expect(events.map((event) => event.id)).toEqual(["event-2", "event-1"]);
    expect(events[0]).toMatchObject({ label: "Turn completed", detail: "Done", occurredAtIso: "2026-09-03T10:05:00.000Z" });
  });

  it("collapses multiple turns from one Codex task into one current card", () => {
    const sessions = mapLiveSessions({
      sessions: [
        {
          id: "thread-1:turn:turn-3",
          thread_id: "thread-1",
          title: "BRN: 495798",
          repo: "browns-shopify",
          branch: "current-fix",
          status: "working",
          status_detail: "Activity received",
          last_seen_at: "2026-09-04T02:30:23.000Z",
          last_event_at: "2026-09-04T02:25:34.000Z",
          started_at: "2026-09-04T02:25:34.000Z",
          finished_at: null,
        },
        {
          id: "thread-1:turn:turn-2",
          thread_id: "thread-1",
          title: "BRN: 495798",
          repo: "browns-shopify",
          branch: "previous-fix",
          status: "finished",
          status_detail: "Completed successfully",
          last_seen_at: "2026-09-04T02:25:24.000Z",
          last_event_at: "2026-09-04T02:25:06.000Z",
          started_at: "2026-09-04T02:24:06.000Z",
          finished_at: "2026-09-04T02:25:06.000Z",
        },
        {
          id: "thread-1:turn:turn-1",
          thread_id: "thread-1",
          title: "BRN: 495798",
          repo: "browns-shopify",
          branch: "old-fix",
          status: "working",
          status_detail: "Activity received",
          last_seen_at: "2026-09-04T02:23:27.000Z",
          last_event_at: "2026-09-04T02:21:25.000Z",
          started_at: "2026-09-04T02:21:25.000Z",
          finished_at: null,
        },
      ],
      events: [
        { id: "event-3", session_id: "thread-1:turn:turn-3", event_type: "local/task/started", label: "Task started", detail: null, tone: "working", occurred_at: "2026-09-04T02:25:34.000Z" },
        { id: "event-2", session_id: "thread-1:turn:turn-2", event_type: "local/task/completed", label: "Task completed", detail: null, tone: "success", occurred_at: "2026-09-04T02:25:06.000Z" },
        { id: "event-1", session_id: "thread-1:turn:turn-1", event_type: "local/task/started", label: "Task started", detail: null, tone: "working", occurred_at: "2026-09-04T02:21:25.000Z" },
      ],
    });

    expect(sessions).toHaveLength(1);
    expect(sessions[0]).toMatchObject({
      id: "thread-1:turn:turn-3",
      title: "BRN: 495798",
      branch: "current-fix",
      status: "working",
    });
    expect(sessions[0].events.map((event) => event.id)).toEqual(["event-3", "event-2", "event-1"]);
  });

  it("keeps separate Codex tasks when their titles match", () => {
    const sharedFields = {
      title: "BRN: 495798",
      repo: "browns-shopify",
      branch: "main",
      status: "working",
      status_detail: "Activity received",
      last_seen_at: "2026-09-04T02:30:23.000Z",
      last_event_at: "2026-09-04T02:25:34.000Z",
      started_at: "2026-09-04T02:25:34.000Z",
      finished_at: null,
    };

    const sessions = mapLiveSessions({
      sessions: [
        { ...sharedFields, id: "thread-1:turn:turn-1", thread_id: "thread-1" },
        { ...sharedFields, id: "thread-2:turn:turn-1", thread_id: "thread-2" },
      ],
      events: [],
    });

    expect(sessions).toHaveLength(2);
  });

  it("lets newer task-level attention replace an older turn heartbeat", () => {
    const sessions = mapLiveSessions({
      sessions: [
        {
          id: "thread-1:turn:turn-1",
          thread_id: "thread-1",
          title: "BRN: 495798",
          repo: "browns-shopify",
          branch: "main",
          status: "working",
          status_detail: "Activity received",
          last_seen_at: "2026-09-04T02:30:23.000Z",
          last_event_at: "2026-09-04T02:25:34.000Z",
          started_at: "2026-09-04T02:25:34.000Z",
          finished_at: null,
        },
        {
          id: "thread-1",
          thread_id: "thread-1",
          title: "BRN: 495798",
          repo: "browns-shopify",
          branch: "main",
          status: "needs_you",
          status_detail: "Waiting for your input",
          last_seen_at: "2026-09-04T02:31:00.000Z",
          last_event_at: "2026-09-04T02:31:00.000Z",
          started_at: "2026-09-04T02:31:00.000Z",
          finished_at: null,
        },
      ],
      events: [],
    });

    expect(sessions).toHaveLength(1);
    expect(sessions[0]).toMatchObject({ id: "thread-1", status: "needs_you", statusDetail: "Waiting for your input" });
  });
});
