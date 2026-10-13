// @vitest-environment jsdom
import React, { act, useEffect } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import { useWorkSwitch } from "../src/work-switch";

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });
it("pauses automatic dashboard work and resumes once when control changes", async () => {
  vi.useFakeTimers(); vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  vi.spyOn(document, "visibilityState", "get").mockReturnValue("visible");
  let state = "standby";
  const fetch = vi.fn(async () => Response.json({ configured: true, state, revision: state === "active" ? 2 : 1, leaseSeconds: 60 }));
  vi.stubGlobal("fetch", fetch);
  let refreshes = 0;
  function Consumer() {
    const work = useWorkSwitch(true);
    useEffect(() => { if (work.allowed()) refreshes += 1; }, [work.allowed, work.change]);
    return <span>{work.label}</span>;
  }
  const container = document.createElement("div");
  const root = createRoot(container);
  try {
    await act(async () => { root.render(<Consumer />); });
    expect(container.textContent).toBe("Switchr: Off"); expect(refreshes).toBe(0);
    state = "active";
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000); });
    expect(container.textContent).toBe("Switchr: On"); expect(refreshes).toBe(1);
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000); });
    expect(refreshes).toBe(1);
    state = "standby";
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000); });
    expect(container.textContent).toBe("Switchr: Off"); expect(refreshes).toBe(1);
  } finally { await act(async () => root.unmount()); vi.restoreAllMocks(); }
});
