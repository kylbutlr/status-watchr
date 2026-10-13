import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { describe, it, expect, vi } from "vitest";
import { notificationPayload } from "../netlify/functions/lib/notifications";

describe("push-only worker", () => {
  it.each(["finished", "needs_you", "failed", "question", "test"])("displays the server's %s payload", async (kind) => {
    const handlers: Record<string, (event: unknown) => void> = {};
    const showNotification = vi.fn(async (_title: string, _options: unknown) => {});
    runInNewContext(readFileSync(new URL("../public/sw.js", import.meta.url), "utf8"), {
      self: {
        addEventListener: (name: string, handler: (event: unknown) => void) => { handlers[name] = handler; },
        registration: { showNotification },
      },
    });
    const waits: Promise<unknown>[] = [];
    const payload = JSON.parse(notificationPayload("request-id", kind, "Watched task", "PRIVATE_REPLY"));
    handlers.push({ data: { json: () => payload }, waitUntil: (promise: Promise<unknown>) => { waits.push(promise); } });
    await Promise.all(waits);
    expect(showNotification).toHaveBeenCalledTimes(1);
    expect(showNotification.mock.calls[0]?.[0]).toBe(kind === "test" ? "Status Watchr" : "Watched task");
    expect(showNotification.mock.calls[0]?.[1]).toMatchObject({ tag: "request-id", data: { url: "/" } });
    if (kind === "question") {
      // Existing installed workers already accept this wire copy. New request kinds must preserve it.
      expect(payload.body).toBe("A watched conversation needs your attention.");
      expect(showNotification.mock.calls[0]?.[1]).toMatchObject({ body: "Needs your attention." });
      expect(JSON.stringify(showNotification.mock.calls)).not.toContain("PRIVATE_REPLY");
    }
  });

  it("shows watched titles with fixed status copy and never opens a payload URL", async () => {
    const handlers: Record<string, (event: unknown) => void> = {};
    const showNotification = vi.fn(async (_title: string, _options: unknown) => {});
    const openWindow = vi.fn(async () => {});
    runInNewContext(readFileSync(new URL("../public/sw.js", import.meta.url), "utf8"), {
      self: { addEventListener: (name: string, handler: (event: unknown) => void) => { handlers[name] = handler; }, registration: { showNotification }, location: { origin: "https://watchr.test" } },
      clients: { openWindow }, URL, Set,
    });
    const waits: Promise<unknown>[] = [];
    const waitUntil = (promise: Promise<unknown>) => { waits.push(promise); };
    handlers.push({ data: { json: () => ({ tag: "test", body: "SECRET_PROMPT" }) }, waitUntil });
    expect(showNotification).not.toHaveBeenCalled();
    handlers.push({ data: { json: () => ({ tag: "test", body: "A watched run finished. Open your private dashboard.", title: "SECRET_TITLE", url: "https://attacker.test" }) }, waitUntil });
    handlers.push({ data: { json: () => ({ tag: "title", body: "A watched run finished. Open your private dashboard.", conversationTitle: "  Watched\n task  " }) }, waitUntil });
    handlers.push({ data: { json: () => ({ tag: "long", body: "A watched run failed. Open your private dashboard.", conversationTitle: "x".repeat(121) }) }, waitUntil });
    handlers.push({ data: { json: () => ({ tag: "reply", body: "A watched run finished. Open your private dashboard.", conversationTitle: "Watched task", replyPreview: "  A useful\n final answer. " }) }, waitUntil });
    handlers.notificationclick({ notification: { close: vi.fn(), data: { url: "https://attacker.test" } }, waitUntil });
    await Promise.all(waits);
    expect(showNotification.mock.calls[0]?.[0]).toBe("Status Watchr");
    expect(showNotification.mock.calls[1]?.[0]).toBe("Watched task");
    expect(showNotification.mock.calls[1]?.[1]).toMatchObject({ body: "Run finished." });
    expect(showNotification.mock.calls[2]?.[0]).toBe("Status Watchr");
    expect(showNotification.mock.calls[3]?.[0]).toBe("Watched task");
    expect(showNotification.mock.calls[3]?.[1]).toMatchObject({ body: "Run finished: A useful final answer." });
    expect(JSON.stringify(showNotification.mock.calls)).not.toContain("SECRET");
    expect(openWindow).toHaveBeenCalledWith("https://watchr.test/");
    expect(handlers.fetch).toBeUndefined();
  });
});
