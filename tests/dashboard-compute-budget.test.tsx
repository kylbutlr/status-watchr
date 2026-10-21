// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { expect, it, vi } from 'vitest';
import { App } from '../src/App';

it('backs off actual unchanged dashboard requests and refreshes immediately on focus and Switchr resume', async () => {
  vi.useFakeTimers();
  vi.stubEnv('VITE_WATCHR_LIVE', 'true');
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  vi.stubGlobal('matchMedia', () => ({ matches: false }));
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible');
  localStorage.clear();
  let state = 'active';
  let reads = 0;
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    const path = new URL(url, 'https://watchr.test');
    if (path.pathname === '/api/auth/session') return Response.json({ authenticated: true });
    if (path.pathname === '/api/work-state') return Response.json({ configured: true, state, revision: state === 'active' ? 2 : 3, leaseSeconds: 60 });
    if (path.pathname === '/api/notifications') return Response.json({ configured: false, devices: [], watches: [], allUntil: null });
    if (path.pathname === '/api/sessions') {
      reads += 1;
      if (path.searchParams.has('since')) return new Response(null, { status: 304 });
      return Response.json({ revision: 'quiet', groupingRevision: 'none', sessions: [], events: [], counts: {} });
    }
    return Response.json({ collector: null });
  }));
  const container = document.createElement('div');
  const root = createRoot(container);
  try {
    await act(async () => root.render(<App />));
    const initial = reads;
    expect(initial).toBeGreaterThan(0);
    for (const delay of [30_000, 60_000, 120_000, 240_000, 480_000]) {
      const before = reads;
      await act(async () => { await vi.advanceTimersByTimeAsync(delay - 1); });
      expect(reads).toBe(before);
      await act(async () => { await vi.advanceTimersByTimeAsync(1); });
      expect(reads).toBe(before + 1);
    }
    const quiet = reads;
    await act(async () => { await vi.advanceTimersByTimeAsync(599_999); });
    expect(reads).toBe(quiet);
    await act(async () => { window.dispatchEvent(new Event('focus')); });
    expect(reads).toBe(quiet + 1);
    state = 'standby';
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000); });
    const paused = reads;
    await act(async () => { await vi.advanceTimersByTimeAsync(600_000); });
    expect(reads).toBe(paused);
    state = 'active';
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000); });
    expect(reads).toBeGreaterThan(paused);
  } finally {
    await act(async () => root.unmount());
    vi.useRealTimers(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); vi.restoreAllMocks();
  }
});
