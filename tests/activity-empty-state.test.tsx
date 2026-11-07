// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { App } from '../src/App';
import type { CollectorHealth } from '../src/collector-health';

let root: Root;
let container: HTMLDivElement;
let health: CollectorHealth | null;
let failActivity: boolean;
let hasActivity: boolean;

beforeEach(() => {
  health = null; failActivity = false; hasActivity = false;
  localStorage.clear(); localStorage.setItem('statusWatchr.pollingSeconds', '0');
  vi.stubEnv('VITE_WATCHR_LIVE', 'true');
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  vi.stubGlobal('matchMedia', () => ({ matches: true }));
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible');
  vi.stubGlobal('fetch', vi.fn(async (input: string) => {
    const url = new URL(input, 'http://watchr.test');
    let payload: unknown = {};
    if (url.pathname === '/api/auth/session') payload = { authenticated: true };
    if (url.pathname === '/api/work-state') payload = { configured: false, state: 'active', revision: 1, leaseSeconds: 60 };
    if (url.pathname === '/api/notifications') payload = { configured: false, devices: [], watches: [], allUntil: null };
    if (url.pathname === '/api/collector') payload = { collector: health };
    if (url.pathname === '/api/sessions') {
      if (failActivity) return new Response('{}', { status: 503 });
      const visible = hasActivity && !url.searchParams.has('status');
      payload = { revision: 'fixture', counts: { working: hasActivity ? 1 : 0 }, events: [], sessions: visible ? [{ id: 'fictional', thread_id: 'fictional', title: 'Demo review', status: 'working', last_seen_at: new Date().toISOString() }] : [] };
    }
    return Response.json(payload);
  }));
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount()); container.remove();
  vi.unstubAllGlobals(); vi.unstubAllEnvs(); vi.restoreAllMocks();
});
const button = (text: string) => [...container.querySelectorAll('button')].find(node => node.textContent === text)!;
const mount = () => act(async () => root.render(<App />));
const connected = (): CollectorHealth => ({ received_at: new Date().toISOString(), source_available: true, hook_trust: 'unknown', last_hook_at: null, queued: 0 });

it('offers Mac setup in the mobile-visible activity column without starting a collector or enabling alerts', async () => {
  await mount();
  const setup = container.querySelector('.session-column [aria-label="Mac connection setup"]')!;
  expect(setup.textContent).toContain('Connect your Mac');
  expect(setup.querySelector('a')?.href).toBe('https://github.com/kylbutlr/status-watchr/blob/main/apps/macos/README.md#configure-your-server');
  expect(container.querySelector('.work-area.mobile-details-open')).toBeNull();
  expect(vi.mocked(fetch).mock.calls.every(([, init]) => !init || !('method' in init) || init.method === 'GET')).toBe(true);
});

it('distinguishes connected-without-activity from an unavailable Codex source and a stale observer', async () => {
  health = connected(); await mount();
  expect(container.querySelector('.activity-empty h3')?.textContent).toBe('Your Mac has checked in');
  health.source_available = false;
  await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Refresh now"]')!.click());
  expect(container.querySelector('.activity-empty h3')?.textContent).toBe('Codex activity is unavailable');
  health.received_at = new Date(Date.now() - 240_000).toISOString();
  await act(async () => container.querySelector<HTMLButtonElement>('[aria-label="Refresh now"]')!.click());
  expect(container.querySelector('.activity-empty h3')?.textContent).toBe('Check your Mac connection');
});

it('returns from an empty filter to existing activity without suggesting a reconnect', async () => {
  hasActivity = true; await mount();
  await act(async () => container.querySelector<HTMLButtonElement>('[role="tab"]:last-child')!.click());
  expect(container.querySelector('.activity-empty h3')?.textContent).toBe('No conversations in this view');
  expect(container.querySelector('.activity-empty a')).toBeNull();
  await act(async () => button('Show all activity').click());
  expect(container.querySelector('.session-card h3')?.textContent).toBe('Demo review');
});

it('retries a failed activity request without confusing the error with missing setup', async () => {
  failActivity = true; await mount();
  expect(container.querySelector('.activity-empty h3')?.textContent).toBe('Activity couldn’t load');
  failActivity = false;
  await act(async () => button('Try again').click());
  expect(container.querySelector('.activity-empty h3')?.textContent).toBe('Connect your Mac');
});
