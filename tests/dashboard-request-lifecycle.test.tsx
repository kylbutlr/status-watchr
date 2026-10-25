// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { App } from '../src/App';

let root: Root;
let container: HTMLDivElement;
let visible: DocumentVisibilityState;
let online: boolean;
let state: string;
let stall: boolean;
let reads: number;
let controls: number;
let finish: () => void;
let requests: { search: string; signal?: AbortSignal | null }[];
const snapshot = () => Response.json({ revision: 'quiet', groupingRevision: 'none', sessions: [], events: [], counts: {} });

beforeEach(() => {
  vi.useFakeTimers();
  vi.stubEnv('VITE_WATCHR_LIVE', 'true');
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  vi.stubGlobal('matchMedia', () => ({ matches: false }));
  visible = 'visible'; online = true; state = 'active'; stall = false; reads = 0; controls = 0;
  requests = [];
  vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visible);
  vi.spyOn(navigator, 'onLine', 'get').mockImplementation(() => online);
  // Use the same timeout contract with the fake clock, including abort rejection.
  vi.spyOn(AbortSignal, 'timeout').mockImplementation((ms) => {
    const controller = new AbortController();
    window.setTimeout(() => controller.abort(new DOMException('Timed out', 'TimeoutError')), ms);
    return controller.signal;
  });
  localStorage.clear();
  vi.stubGlobal('fetch', vi.fn(async (url: string, options?: RequestInit) => {
    const path = new URL(url, 'https://watchr.test');
    if (path.pathname === '/api/auth/session') return Response.json({ authenticated: true });
    if (path.pathname === '/api/work-state') {
      controls += 1;
      return Response.json({ configured: true, state, revision: state === 'active' ? 2 : 3, leaseSeconds: 60 });
    }
    if (path.pathname === '/api/notifications') return Response.json({ configured: false, devices: [], watches: [], allUntil: null });
    if (path.pathname === '/api/sessions') {
      reads += 1;
      requests.push({ search: path.search, signal: options?.signal });
      if (stall) return new Promise<Response>((resolve, reject) => {
        finish = () => resolve(snapshot());
        options?.signal?.addEventListener('abort', () => reject(options.signal!.reason), { once: true });
      });
      return path.searchParams.has('since') ? new Response(null, { status: 304 }) : snapshot();
    }
    return Response.json({ collector: null });
  }));
  container = document.createElement('div');
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
  vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); vi.restoreAllMocks();
});
const render = () => act(async () => root.render(<App />));
const focus = () => act(async () => { window.dispatchEvent(new Event('focus')); });

it('shares an in-flight snapshot across focus, visibility, and reconnect events', async () => {
  await render();
  const initial = reads;
  stall = true;
  await focus();
  expect(reads).toBe(initial + 1);
  await act(async () => {
    window.dispatchEvent(new Event('focus'));
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new Event('online'));
  });
  expect(reads).toBe(initial + 1);
  await act(async () => finish());
  stall = false;
  await focus();
  expect(reads).toBe(initial + 2); // A later focus still refreshes immediately.
});

it('bounds a stalled refresh and recovers on focus after failure', async () => {
  await render(); stall = true;
  await focus();
  await act(async () => { await vi.advanceTimersByTimeAsync(15_000); });
  expect(container.textContent).toContain('Dashboard refresh failed');
  stall = false;
  const before = reads;
  await focus();
  expect(reads).toBe(before + 1);
  expect(container.textContent).not.toContain('Dashboard refresh failed');
});

it('pauses hidden and offline work, then refreshes on return and standby resume', async () => {
  await render();
  visible = 'hidden'; online = false;
  await act(async () => {
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(120_000);
  });
  const before = { reads, controls };
  visible = 'visible';
  await act(async () => {
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(60_000);
  });
  expect({ reads, controls }).toEqual(before);
  online = true;
  await act(async () => { window.dispatchEvent(new Event('online')); });
  expect(reads).toBe(before.reads + 1);
  state = 'standby';
  await act(async () => { await vi.advanceTimersByTimeAsync(30_000); });
  const paused = reads;
  await act(async () => { await vi.advanceTimersByTimeAsync(120_000); });
  expect(reads).toBe(paused);
  state = 'active'; stall = true;
  await act(async () => { await vi.advanceTimersByTimeAsync(30_000); });
  expect(reads).toBe(paused + 1);
  await act(async () => finish());
});

it('refreshes on visibility return when an expired lease renews at the same revision', async () => {
  await render();
  visible = 'hidden';
  await act(async () => {
    document.dispatchEvent(new Event('visibilitychange'));
    await vi.advanceTimersByTimeAsync(120_000);
  });
  const before = reads;
  visible = 'visible';
  await act(async () => { document.dispatchEvent(new Event('visibilitychange')); });
  expect(reads).toBe(before + 1);
});

it('keeps explicit refresh immediate and independent clients independent', async () => {
  await render();
  const other = createRoot(document.createElement('div'));
  try {
    const before = reads;
    await act(async () => other.render(<App />));
    expect(reads).toBe(before + 1);
    await focus();
    expect(reads).toBe(before + 3); // Both visible clients still refresh.
    const pending = reads;
    await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Refresh now"]')!.click());
    expect(reads).toBe(pending + 1);
  } finally { await act(async () => other.unmount()); }
});

it('cancels an obsolete filter read and stops the active request on unmount', async () => {
  await render(); stall = true;
  await focus();
  const obsolete = requests.at(-1)!;
  const before = reads;
  const filter = [...container.querySelectorAll<HTMLButtonElement>('[role="tab"]')]
    .find(button => button.textContent?.startsWith('In progress'))!;
  await act(async () => filter.click());
  expect(obsolete.signal?.aborted).toBe(true);
  expect(reads).toBe(before + 1);
  expect(requests.at(-1)?.search).toContain('status=working');
  const active = requests.at(-1)!;
  await act(async () => root.unmount());
  expect(active.signal?.aborted).toBe(true);
  const stopped = { reads, controls };
  await act(async () => { await vi.advanceTimersByTimeAsync(120_000); });
  expect({ reads, controls }).toEqual(stopped);
});
