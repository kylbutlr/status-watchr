import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { createEventDeduper, createScanStateTracker, localSessionState, normalizeNotification, parseInterval, resolveThreadStatus, threadListParams, turnSessionId } from "../collector/status-watchr.mjs";

describe("Status Watchr collector", () => {
  const context = { threadId: "thr_test", thread: { name: "Test task", gitInfo: { branch: "main" } } };

  it("maps an active turn to working metadata", () => {
    expect(normalizeNotification({ method: "turn/started", params: { threadId: "thr_test", turn: { id: "turn_1", status: "inProgress" } } }, context)).toMatchObject({
      sessionId: turnSessionId("thr_test", "turn_1"),
      status: "working",
      label: "Turn started",
      branch: null,
      turnId: "turn_1",
    });
  });

  it("maps approval requests to needs you without exposing prompt content", () => {
    const event = normalizeNotification({ method: "item/commandExecution/requestApproval", params: { threadId: "thr_test", command: "private command" } }, context);
    expect(event).toMatchObject({ status: "needs_you", label: "Approval requested" });
    expect(JSON.stringify(event)).not.toContain("private command");
  });

  it("maps completed turns to finished", () => {
    expect(normalizeNotification({ method: "turn/completed", params: { threadId: "thr_test", turn: { status: "completed" } } }, context)).toMatchObject({ status: "finished", label: "Turn completed" });
  });

  it("maps local rollout markers when the app server reports notLoaded", () => {
    const event = normalizeNotification({ method: "local/task/started", params: { threadId: "thr_test", marker: "turn_1" } }, { ...context, status: "working" });
    expect(event).toMatchObject({ status: "working", label: "Task started", tone: "working" });
  });

  it("reads the latest local rollout marker without loading the thread", () => {
    const directory = mkdtempSync(join(tmpdir(), "status-watchr-"));
    const filePath = join(directory, "session.jsonl");
    writeFileSync(filePath, [
      JSON.stringify({ type: "event_msg", timestamp: "2026-09-02T10:00:00.000Z", payload: { type: "task_started", turn_id: "turn_1", started_at: "2026-09-02T10:00:00.000Z" } }),
      JSON.stringify({ type: "event_msg", timestamp: "2026-09-02T10:05:00.000Z", payload: { type: "task_complete", turn_id: "turn_1", completed_at: "2026-09-02T10:05:00.000Z" } }),
    ].join("\n"));

    expect(localSessionState(filePath)).toEqual({ status: "finished", marker: "turn_1", occurredAt: "2026-09-02T10:05:00.000Z" });
    rmSync(directory, { recursive: true, force: true });
  });

  it("preserves the source time when an old stale marker is scanned", () => {
    const directory = mkdtempSync(join(tmpdir(), "status-watchr-"));
    const filePath = join(directory, "session.jsonl");
    writeFileSync(filePath, JSON.stringify({ type: "event_msg", timestamp: "2026-09-02T10:05:00.000Z", payload: { type: "turn_aborted", turn_id: "turn_1", completed_at: "2026-09-02T10:05:00.000Z" } }));

    const state = localSessionState(filePath);
    expect(state).toEqual({ status: "stale", marker: "turn_1", occurredAt: "2026-09-02T10:05:00.000Z" });
    expect(normalizeNotification({ method: "local/task/aborted", params: { threadId: "thr_test", marker: state.marker, turnId: state.marker, occurredAt: state.occurredAt } }, { ...context, status: "stale" })).toMatchObject({
      sessionId: turnSessionId("thr_test", "turn_1"),
      occurredAt: "2026-09-02T10:05:00.000Z",
      turnId: "turn_1",
    });
    rmSync(directory, { recursive: true, force: true });
  });

  it("deduplicates repeated lifecycle event IDs", () => {
    const dedupe = createEventDeduper();
    const event = normalizeNotification({ method: "local/task/aborted", params: { threadId: "thr_test", marker: "turn_1" } }, { ...context, status: "stale" });

    expect(dedupe.has(event.eventId)).toBe(false);
    dedupe.mark(event.eventId);
    expect(dedupe.has(event.eventId)).toBe(true);
  });

  it("throttles unchanged scan heartbeats but sends metadata changes immediately", () => {
    const tracker = createScanStateTracker(120_000);
    const event = normalizeNotification({ method: "local/task/started", params: { threadId: "thr_test", marker: "turn_1" } }, { ...context, status: "working" });

    expect(tracker.shouldSend(event, 1_000)).toBe(true);
    tracker.mark(event, 1_000);
    expect(tracker.shouldSend(event, 120_999)).toBe(false);
    expect(tracker.shouldSend(event, 121_000)).toBe(true);
    expect(tracker.shouldSend({ ...event, title: "Renamed task" }, 1_001)).toBe(true);
  });

  it("does not repeat terminal scan states without a state change", () => {
    const tracker = createScanStateTracker(120_000);
    const event = normalizeNotification({ method: "local/task/completed", params: { threadId: "thr_test", marker: "turn_1" } }, { ...context, status: "finished" });

    tracker.mark(event, 1_000);
    expect(tracker.shouldSend(event, 500_000)).toBe(false);
  });

  it("preserves the source occurrence time when a scan finds a completion", () => {
    expect(normalizeNotification(
      { method: "local/task/completed", params: { threadId: "thr_test", marker: "turn_1", occurredAt: "2026-09-02T10:05:00.000Z" } },
      { ...context, status: "finished" },
    )).toMatchObject({
      occurredAt: "2026-09-02T10:05:00.000Z",
    });
  });

  it("separates a polling observation time from the source event time", () => {
    expect(normalizeNotification(
      { method: "local/task/started", params: { threadId: "thr_test", marker: "turn_1", occurredAt: "2026-09-02T10:00:00.000Z" } },
      { ...context, status: "working" },
      { observedAt: "2026-09-03T12:00:00.000Z" },
    )).toMatchObject({
      occurredAt: "2026-09-02T10:00:00.000Z",
      observedAt: "2026-09-03T12:00:00.000Z",
    });
  });

  it("uses renamed thread metadata when a notification carries it", () => {
    expect(normalizeNotification(
      { method: "thread/status/changed", params: { threadId: "thr_test", thread: { name: "Renamed task" }, status: { type: "active" } } },
      { ...context, status: "working" },
    )).toMatchObject({ title: "Renamed task" });
  });

  it("prefers the local completed marker over a stale active thread status", () => {
    expect(resolveThreadStatus({ status: { type: "active" } }, { status: "finished" })).toBe("finished");
    expect(resolveThreadStatus({ status: { type: "active" } }, { status: "stale" })).toBe("stale");
    expect(resolveThreadStatus({ status: { type: "active", activeFlags: ["waitingOnApproval"] } }, { status: "stale" })).toBe("needs_you");
  });

  it("accepts readable polling interval settings", () => {
    expect(parseInterval("30s")).toBe(30_000);
    expect(parseInterval("1m")).toBe(60_000);
    expect(() => parseInterval("2s")).toThrow("at least 5s");
  });

  it("requests recently updated Codex threads and can carry a returned cursor", () => {
    expect(threadListParams()).toEqual({ archived: false, limit: 100, sortKey: "updated_at", sortDirection: "desc" });
    expect(threadListParams("2026-09-02T16:48:42Z")).toEqual({ archived: false, limit: 100, sortKey: "updated_at", sortDirection: "desc", cursor: "2026-09-02T16:48:42Z" });
  });
});
