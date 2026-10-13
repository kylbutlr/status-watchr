// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import { MacCheckIn } from "../src/MacCheckIn";

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

it("ages the received heartbeat independently of network polling and catches up on focus", async () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-09-22T02:02:00Z"));
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  const container = document.createElement("div");
  const root = createRoot(container);
  try {
    await act(async () => root.render(<MacCheckIn receivedAt="2026-09-22T02:00:00Z" />));
    expect(container.textContent).toBe("Mac last checked in: 2m ago");
    expect(container.querySelector("time")?.dateTime).toBe("2026-09-22T02:00:00Z");
    await act(async () => vi.advanceTimersByTimeAsync(60_000));
    expect(container.textContent).toBe("Mac last checked in: 3m ago");
    vi.setSystemTime(new Date("2026-09-22T03:00:00Z"));
    await act(async () => window.dispatchEvent(new Event("focus")));
    expect(container.textContent).toBe("Mac last checked in: 1h ago");
    expect(fetch).not.toHaveBeenCalled();
  } finally { await act(async () => root.unmount()); }
  expect(vi.getTimerCount()).toBe(0);
});

it("does not invent a check-in when the timestamp is missing or invalid", async () => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  const container = document.createElement("div");
  const root = createRoot(container);
  try {
    for (const receivedAt of [undefined, "invalid"]) {
      await act(async () => root.render(<MacCheckIn receivedAt={receivedAt} />));
      expect(container.textContent).toBe("Mac last checked in: Unavailable");
      expect(container.querySelector("time")).toBeNull();
    }
    await act(async () => root.render(<MacCheckIn receivedAt={new Date().toISOString()} />));
    expect(container.textContent).toBe("Mac last checked in: just now");
  } finally { await act(async () => root.unmount()); }
});
