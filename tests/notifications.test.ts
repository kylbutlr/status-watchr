import { describe, it, expect } from "vitest";
import { normalizedIngestEvent } from "../netlify/functions/lib/ingest-event";
import { notificationIdentity, notificationPayload, validateSubscription, pushFailureDisposition } from "../netlify/functions/lib/notifications";
import { collectorHealthLabel } from "../src/collector-health";

const event = { sessionId: "thread:turn:run", threadId: "thread", turnId: "run", eventId: "event", eventType: "local/task/completed", title: "Private title", status: "finished", occurredAt: new Date().toISOString() };
describe("notification and privacy policy", () => {
  it("deduplicates completion across adapters but separates runs and attention requests", () => {
    expect(notificationIdentity(event)).toBe(notificationIdentity({ ...event, eventId: "hook", eventType: "codex/hook/Stop" }));
    expect(notificationIdentity(event)).not.toBe(notificationIdentity({ ...event, turnId: "next" }));
    expect(notificationIdentity({ ...event, status: "needs_you" })).toBeNull();
    expect(notificationIdentity({ ...event, status: "needs_you", attentionId: "a" })).not.toBe(notificationIdentity({ ...event, status: "needs_you", attentionId: "b" }));
  });
  it("does not alert on malformed, stale, interrupted, or future observations", () => {
    for (const patch of [{ occurredAt: "bad" }, { occurredAt: new Date(Date.now() - 601_000).toISOString() }, { occurredAt: new Date(Date.now() + 61_000).toISOString() }, { status: "working" }, { status: "stale" }, { turnId: null }]) expect(notificationIdentity({ ...event, ...patch })).toBeNull();
  });
  it("stores only normalized allowlisted metadata", () => {
    const result = normalizedIngestEvent({ ...event, label: "PROMPT_SENTINEL", detail: "SOURCE_SENTINEL", statusDetail: "SECRET_SENTINEL", branch: "SECRET_BRANCH", repo: "https://user:password@github.com/owner/project.git?token=SECRET_TOKEN" });
    expect(result.repo).toBe("project");
    expect(result.title).toBe("Private title");
    expect(JSON.stringify(result)).not.toMatch(/SENTINEL|SECRET|password|github/);
    for (const field of ["prompt", "code", "diff", "terminal", "tool_input", "secret"]) expect(() => normalizedIngestEvent({ ...event, [field]: "secret" })).toThrow();
    expect(() => normalizedIngestEvent({ ...event, occurredAt: "invalid" })).toThrow();
    expect(normalizedIngestEvent({ ...event, replyPreview: "  Final\n answer  " }).replyPreview).toBe("Final answer");
    expect(normalizedIngestEvent({ ...event, notificationEligible: false }).notificationEligible).toBe(false);
    expect(() => normalizedIngestEvent({ ...event, notificationEligible: "false" })).toThrow();
    expect(notificationIdentity({ ...event, notificationEligible: false })).toBeNull();
    expect(() => normalizedIngestEvent({ ...event, status: "working", replyPreview: "Private reply" })).toThrow();
    expect(() => normalizedIngestEvent({ ...event, replyPreview: "x".repeat(201) })).toThrow();
  });
  it("includes only a bounded conversation title in watched alerts", () => {
    const payload = JSON.parse(notificationPayload("opaque-id", "finished"));
    expect(payload.body).toBe("A watched run finished. Open your private dashboard.");
    expect(payload.url).toBe("/");
    expect(JSON.stringify(payload)).not.toContain("Private title");
    const titled = JSON.parse(notificationPayload("opaque-id", "finished", "  Private\n title  "));
    expect(titled.conversationTitle).toBe("Private title");
    expect(Array.from(JSON.parse(notificationPayload("opaque-id", "failed", "😀".repeat(130))).conversationTitle)).toHaveLength(120);
    expect(JSON.parse(notificationPayload("opaque-id", "test", "Private title"))).not.toHaveProperty("conversationTitle");
    expect(JSON.parse(notificationPayload("opaque-id", "finished", "Untitled task"))).not.toHaveProperty("conversationTitle");
    expect(JSON.parse(notificationPayload("opaque-id", "finished", "Private title", "Final answer"))).toHaveProperty("replyPreview", "Final answer");
    expect(JSON.parse(notificationPayload("opaque-id", "failed", "Private title", "Final answer"))).not.toHaveProperty("replyPreview");
    expect(JSON.parse(notificationPayload("opaque-id", "finished", "Private title", "😀".repeat(130))).replyPreview.length).toBe(180);
  });
  it("rejects arbitrary push destinations and malformed keys", () => {
    const keys = { p256dh: "a".repeat(87), auth: "b".repeat(22) };
    expect(validateSubscription({ endpoint: "https://web.push.apple.com/test", keys }).endpoint).toContain("apple.com");
    for (const endpoint of ["http://web.push.apple.com/test", "https://127.0.0.1/test", "https://web.push.apple.com.attacker.test/push", "https://user:password@web.push.apple.com/push", "https://web.push.apple.com:9000/test"]) expect(() => validateSubscription({ endpoint, keys })).toThrow();
    expect(() => validateSubscription({ endpoint: "https://web.push.apple.com/test", keys: {} })).toThrow();
    expect(pushFailureDisposition({ statusCode: 410 })).toBe("revoke");
    expect(pushFailureDisposition({ statusCode: 503 })).toBe("retry");
  });
  it("never confuses a recent dashboard request with a healthy Mac", () => {
    expect(collectorHealthLabel(null)).toContain("not verified");
    const health = { source_available: true, hook_trust: "trusted" as const, received_at: new Date().toISOString(), last_hook_at: null, queued: 0 };
    expect(collectorHealthLabel(health)).toContain("execution not verified");
    expect(collectorHealthLabel({ ...health, received_at: new Date(Date.now() - 181_000).toISOString() })).toContain("not reporting");
    expect(collectorHealthLabel({ ...health, hook_trust: "untrusted" })).toContain("need review");
  });
});
