// @vitest-environment jsdom
import React, { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NotificationOverview, NotificationProvider, Notifications } from "../src/Notifications";

let root: Root;
let container: HTMLDivElement;
let watching = false;
let fail = false;
let allUntil: string | null = null;
let allAlways = false;
const calls: { path: string; method: string; body?: Record<string, unknown> }[] = [];
beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  watching = false; fail = false; allUntil = null; allAlways = false; calls.length = 0; localStorage.clear();
  vi.stubGlobal("fetch", vi.fn(async (path: string, options?: RequestInit) => {
    const body = options?.body ? JSON.parse(String(options.body)) : undefined;
    calls.push({ path, method: String(options?.method), body });
    if (fail) return { ok: false, json: async () => ({ error: "Could not save. Try again." }) };
    if (path.endsWith("/watch")) watching = body.enabled;
    if (path.endsWith('/all')) {
      allAlways = body.mode === 'always';
      allUntil = body.until ?? (body.minutes ? new Date(Date.now() + body.minutes * 60_000).toISOString() : null);
    }
    return { ok: true, json: async () => ({ configured: true, publicKey: 'test', allAlways, allUntil, serverNow: new Date().toISOString(), watches: [{ thread_id: "thread", enabled: watching }], devices: [{ id: 'phone', created_at: new Date().toISOString() }] }) };
  }));
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); vi.useRealTimers(); vi.unstubAllGlobals(); });
const button = (text: string) => Array.from(container.querySelectorAll("button")).find((node) => node.textContent === text)!;
const render = async (demo = false) => act(async () => { root.render(<NotificationProvider demo={demo}><NotificationOverview demo={demo} /><Notifications threadId="thread" demo={demo} /></NotificationProvider>); });

describe("conversation watch UI", () => {
  it('starts compact and opens only one control panel at a time', async () => {
    await render();
    const alerts = container.querySelector<HTMLElement>('#alert-settings')!;
    const settings = container.querySelector<HTMLElement>('#dashboard-settings')!;
    expect(alerts.hidden).toBe(true); expect(settings.hidden).toBe(true);
    await act(async () => button('Alerts: Off').click());
    expect(alerts.hidden).toBe(false); expect(settings.hidden).toBe(true);
    await act(async () => button('Settings').click());
    expect(alerts.hidden).toBe(true); expect(settings.hidden).toBe(false);
    await act(async () => button('Watching (0)').click());
    expect(alerts.hidden).toBe(true); expect(settings.hidden).toBe(true);
    expect(container.querySelector('#watched-conversations')).not.toBeNull();
    await act(async () => button('Watching (0)').click());
    expect(container.querySelector('#watched-conversations')).toBeNull();
  });
  it('lists only enabled watches and opens each selected conversation', async () => {
    watching = true;
    const open = vi.fn();
    await act(async () => root.render(<NotificationProvider demo={false}><NotificationOverview demo={false} onOpenWatch={open} /><Notifications threadId="thread" demo={false} /></NotificationProvider>));
    expect(container.querySelector('#watched-conversations')).toBeNull();
    await act(async () => button('Watching (1)').click());
    const row = container.querySelector<HTMLButtonElement>('.watch-details-button')!;
    expect(row.textContent).toContain('Conversation thread');
    await act(async () => row.click());
    expect(open).toHaveBeenCalledWith({ threadId: 'thread', session: undefined });
    await act(async () => button('Mute this conversation').click());
    expect(container.querySelector('#watched-conversations')?.textContent).toContain('No conversations watched.');
    expect(button('Watching (0)')).toBeTruthy();
  });
  it('does not list temporary all-conversation coverage as an individual watch', async () => {
    allAlways = true;
    await render();
    await act(async () => button('Watching (0)').click());
    expect(container.querySelectorAll('.watch-details-button')).toHaveLength(0);
  });
  it('keeps general notification help inside the device-settings disclosure', async () => {
    await render();
    const description = 'Completion, failure, and available attention alerts, including new conversations.';
    expect(container.textContent).not.toContain(description);
    expect(container.querySelector('.notification-summary')).toBeNull();
    await act(async () => button('Notification device settings').click());
    expect(container.querySelector('#notification-device-settings')?.textContent).toContain(description);
    await act(async () => button('Notification device settings').click());
    expect(container.textContent).not.toContain(description);
    await act(async () => button('Notify for all').click());
    expect(container.querySelector('.notification-summary')?.textContent).toContain('On until');
  });
  it('enables Always on, restores it on reload, and cancels without changing watches', async () => {
    watching = true; await render();
    const select = container.querySelector('select')!;
    await act(async () => { select.value = 'always'; select.dispatchEvent(new Event('change', { bubbles: true })); });
    await act(async () => button('Notify for all').click());
    expect(calls.find(call => call.path.endsWith('/all'))?.body).toEqual({ mode: 'always' });
    expect(container.textContent).toContain('On until you turn it off');
    await act(async () => root.unmount()); root = createRoot(container); await render();
    expect(container.querySelector('select')!.value).toBe('always');
    expect(button('Turn Off').getAttribute('aria-pressed')).toBe('true');
    fail = true;
    await act(async () => button('Turn Off').click());
    expect(button('Turn Off').getAttribute('aria-pressed')).toBe('true');
    fail = false;
    await act(async () => button('Turn Off').click());
    expect(allAlways).toBe(false); expect(watching).toBe(true);
    expect(button('Notify for all')).toBeTruthy();
  });
  it('sends the next local midnight and shows a finite expiry', async () => {
    await render();
    const select = container.querySelector('select')!;
    await act(async () => { select.value = 'midnight'; select.dispatchEvent(new Event('change', { bubbles: true })); });
    await act(async () => button('Notify for all').click());
    const expected = new Date(); expected.setHours(24, 0, 0, 0);
    expect(calls.find(call => call.path.endsWith('/all'))?.body).toEqual({ mode: 'midnight', until: expected.toISOString() });
    expect(container.textContent).toContain('Stops automatically');
    expect(button('Turn Off')).toBeTruthy();
  });
  it('turns all alerts on for one hour by default and off without changing an individual watch', async () => {
    watching = true; await render();
    await act(async () => button('Notify for all').click());
    expect(calls.find(call => call.path.endsWith('/all'))?.body).toEqual({ minutes: 60 });
    expect(button('Turn Off').getAttribute('aria-pressed')).toBe('true');
    expect(button('Mute this conversation').getAttribute('aria-pressed')).toBe('true');
    await act(async () => button('Turn Off').click());
    expect(calls.filter(call => call.path.endsWith('/all')).at(-1)?.body).toEqual({ minutes: 0 });
    expect(button('Notify for all').getAttribute('aria-pressed')).toBe('false');
    expect(watching).toBe(true);
    expect(calls.filter(call => call.path.endsWith('/watch'))).toHaveLength(0);
  });
  it('expires the visible state without a reload and leaves the individual watch enabled', async () => {
    vi.useFakeTimers(); watching = true; allUntil = new Date(Date.now() + 1000).toISOString();
    await render();
    expect(button('Turn Off')).toBeTruthy();
    await act(async () => { vi.advanceTimersByTime(1001); });
    expect(button('Notify for all').getAttribute('aria-pressed')).toBe('false');
    expect(button('Mute this conversation').getAttribute('aria-pressed')).toBe('true');
  });
  it.each(['focus', 'visibilitychange', 'pageshow'])('expires on %s after suspended timers even when settings stall', async (event) => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-09-22T00:00:00Z'));
    watching = true; allUntil = new Date(Date.now() + 1000).toISOString();
    await render();
    expect(button('Turn Off')).toBeTruthy();
    vi.stubGlobal('fetch', vi.fn(() => new Promise(() => {})));
    // Move wall time without running callbacks, as when a page was suspended.
    vi.setSystemTime(new Date('2026-09-22T00:08:00Z'));
    await act(async () => { (event === 'visibilitychange' ? document : window).dispatchEvent(new Event(event)); });
    expect(container.querySelector('.notification-state')?.textContent).toBe('Off');
    expect(button('Notify for all').getAttribute('aria-pressed')).toBe('false');
    expect(container.querySelector('select')!.disabled).toBe(false);
    expect(container.querySelector('.notification-summary')).toBeNull();
    expect(button('Mute this conversation').getAttribute('aria-pressed')).toBe('true');
  });
  it('expires on return while Switchr blocks automatic requests', async () => {
    vi.useFakeTimers();
    let allowed = true;
    allUntil = new Date(Date.now() + 1000).toISOString();
    await act(async () => root.render(<NotificationProvider demo={false} automaticAllowed={() => allowed}><NotificationOverview demo={false} /></NotificationProvider>));
    const requests = calls.length;
    allowed = false;
    vi.setSystemTime(Date.now() + 480_000);
    await act(async () => { window.dispatchEvent(new Event('focus')); });
    expect(container.querySelector('.notification-state')?.textContent).toBe('Off');
    expect(calls).toHaveLength(requests);
  });
  it('expires on return when settings fail without sending preference writes', async () => {
    vi.useFakeTimers(); allUntil = new Date(Date.now() + 1000).toISOString();
    await render(); fail = true;
    vi.setSystemTime(Date.now() + 480_000);
    await act(async () => { window.dispatchEvent(new Event('focus')); });
    expect(container.querySelector('.notification-state')?.textContent).toBe('Off');
    expect(calls.every(call => call.method === 'GET')).toBe(true);
  });
  it('preserves Always on after suspended timers with unavailable settings', async () => {
    vi.useFakeTimers(); allAlways = true;
    await render(); fail = true;
    vi.setSystemTime(Date.now() + 86_400_000);
    await act(async () => { window.dispatchEvent(new Event('pageshow')); });
    expect(container.querySelector('.notification-state')?.textContent).toBe('Always on');
    expect(button('Turn Off')).toBeTruthy();
  });
  it('does not claim all alerts are on when saving fails', async () => {
    await render(); fail = true;
    await act(async () => button('Notify for all').click());
    expect(button('Notify for all').getAttribute('aria-pressed')).toBe('false');
    expect(container.textContent).toContain('Could not save. Try again.');
  });
  it("watches persistently and can be muted without enabling device permission", async () => {
    await render();
    await act(async () => button("Watch this conversation").click());
    expect(button("Mute this conversation").getAttribute("aria-pressed")).toBe("true");
    expect(calls.find((call) => call.path.endsWith("/watch"))?.body).toEqual({ threadId: "thread", enabled: true });
    expect(container.textContent).toContain("No notifications are enabled on this device yet");
    await act(async () => button("Mute this conversation").click());
    expect(button("Watch this conversation").getAttribute("aria-pressed")).toBe("false");
  });
  it("does not show a successful watch when the request fails", async () => {
    await render(); fail = true;
    await act(async () => button("Watch this conversation").click());
    expect(button("Watch this conversation").disabled).toBe(false);
    expect(container.querySelector('[role="status"]')?.textContent).toBe("Could not save. Try again.");
  });
  it("keeps demo controls non-mutating and explains phone setup", async () => {
    await render(true);
    expect(button("Watch this conversation").disabled).toBe(true);
    await act(async () => button("Notification device settings").click());
    expect(container.textContent).toContain("Home Screen");
    expect(container.textContent).toContain("Questions are not yet reliably detected");
    expect(calls).toHaveLength(0);
  });
});
