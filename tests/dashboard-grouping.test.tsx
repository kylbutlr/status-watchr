// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { expect, it, vi } from 'vitest';
import { App } from '../src/App';

it('replaces a run by conversation identity and discards loaded subtask pages after grouping changes', async () => {
  vi.stubEnv('VITE_WATCHR_LIVE', 'true');
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  vi.stubGlobal('matchMedia', () => ({ matches: false }));
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible');
  localStorage.clear();
  localStorage.setItem('statusWatchr.pollingSeconds', '0');
  const row = (id: string, thread: string, title: string) => ({ id, thread_id: thread, title, status: 'working', last_seen_at: new Date().toISOString(), started_at: new Date().toISOString(), finished_at: null });
  let phase = 0;
  const initial = [row('parent-old', 'parent', 'Project'), ...Array.from({length: 9}, (_, n) => row(`other-${n}`, `other-${n}`, `Independent ${n}`))];
  const counts = { working: 11, needs_you: 0, finished: 0, failed: 0, stale: 0 };
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    const path = new URL(url, 'https://watchr.test');
    let payload: unknown = {};
    if (path.pathname === '/api/auth/session') payload = { authenticated: true };
    if (path.pathname === '/api/work-state') payload = { configured: false, state: 'active', revision: 1, leaseSeconds: 60 };
    if (path.pathname === '/api/notifications') payload = { configured: false, devices: [], watches: [], allUntil: null };
    if (path.pathname === '/api/sessions') {
      const more = path.searchParams.has('cursor');
      payload = { revision: String(phase), groupingRevision: phase === 2 ? 'grouped' : 'ungrouped', counts: phase === 2 ? {...counts, working: 10} : counts,
        sessions: more ? [row('child-run', 'child', 'Project: review')] : phase === 0 ? initial : [row('parent-new', 'parent', 'Renamed project'), ...initial.slice(1)],
        events: [], nextCursor: more || phase === 2 ? null : 'next' };
    }
    if (path.pathname.endsWith('/events')) payload = {events: []};
    return new Response(JSON.stringify(payload));
  }));
  const container = document.createElement('div'); document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () => root.render(<App />));
    const cards = () => [...container.querySelectorAll('.session-card')];
    expect(cards()).toHaveLength(10);
    await act(async () => [...container.querySelectorAll('button')].find(button => button.textContent?.startsWith('Load '))!.click());
    expect(cards()).toHaveLength(11);
    phase = 1;
    await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Refresh now"]')!.click());
    expect(cards()).toHaveLength(11);
    expect(cards().filter(card => card.textContent?.includes('Renamed project'))).toHaveLength(1);
    expect(cards().some(card => card.textContent?.includes('Project: review'))).toBe(true);
    phase = 2;
    await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Refresh now"]')!.click());
    expect(cards()).toHaveLength(10);
    expect(cards().some(card => card.textContent?.includes('Project: review'))).toBe(false);
  } finally {
    await act(async () => root.unmount()); container.remove();
    vi.unstubAllGlobals(); vi.unstubAllEnvs(); vi.restoreAllMocks();
  }
});
