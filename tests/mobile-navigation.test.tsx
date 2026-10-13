// @vitest-environment jsdom
import React, { act } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { App } from '../src/App';

let root: Root;
let container: HTMLDivElement;
beforeEach(() => {
  localStorage.clear();
  vi.stubGlobal('IS_REACT_ACT_ENVIRONMENT', true);
  vi.stubGlobal('matchMedia', vi.fn(() => ({ matches: true })));
  vi.stubGlobal('scrollTo', vi.fn());
  vi.stubGlobal('requestAnimationFrame', (callback: FrameRequestCallback) => { callback(0); return 0; });
  HTMLElement.prototype.scrollIntoView = vi.fn();
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
});

it('persists a migrated refresh preference and renders only supported choices', async () => {
  localStorage.setItem('statusWatchr.pollingSeconds', '3600');
  await act(async () => root.render(<App />));
  const select = container.querySelector<HTMLSelectElement>('#polling-interval')!;
  expect(Array.from(select.options, option => option.value)).toEqual(['0', '15', '30', '60', '300']);
  expect(select.value).toBe('300');
  expect(localStorage.getItem('statusWatchr.pollingSeconds')).toBe('300');
  await act(async () => { select.value = '0'; select.dispatchEvent(new Event('change', { bubbles: true })); });
  expect(localStorage.getItem('statusWatchr.pollingSeconds')).toBe('0');
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); vi.unstubAllGlobals(); });

it('shows collector diagnostics only inside View details', async () => {
  await act(async () => root.render(<App />));
  expect(container.querySelector('.collector-readiness')).toBeNull();
  const button = (label: string) => Array.from(container.querySelectorAll('button')).find(item => item.textContent?.trim() === label)!;
  await act(async () => button('Settings').click());
  await act(async () => button('View details').click());
  expect(container.querySelector('.connection-detail-panel .collector-readiness')?.textContent).toBe('Mac readiness is not measured in preview');
  expect(container.querySelector('.connection-card-summary .collector-readiness')).toBeNull();
  await act(async () => button('Settings').click());
  expect(container.querySelector('.collector-readiness')).toBeNull();
});

it('opens the tapped conversation immediately and returns focus to that card', async () => {
  await act(async () => root.render(<App />));
  const cards = container.querySelectorAll<HTMLButtonElement>('.session-card');
  const target = cards[cards.length - 1];
  const title = target.querySelector('h3')!.textContent;
  target.focus();
  await act(async () => target.click());
  expect(container.querySelector('.work-area')?.classList.contains('mobile-details-open')).toBe(true);
  expect(container.querySelector('.selected-task h3')?.textContent).toBe(title);
  expect(document.activeElement).toBe(container.querySelector('.activity-panel'));
  expect(HTMLElement.prototype.scrollIntoView).toHaveBeenCalled();
  await act(async () => container.querySelector<HTMLButtonElement>('.mobile-back')!.click());
  expect(container.querySelector('.work-area')?.classList.contains('mobile-details-open')).toBe(false);
  expect(document.activeElement).toBe(target);
  expect(window.scrollTo).toHaveBeenCalledWith({ top: 0 });
});

it('opens watched conversation details directly and returns to its watch row', async () => {
  await act(async () => root.render(<App />));
  const toggle = Array.from(container.querySelectorAll('button')).find(button => button.textContent?.startsWith('Watching'))!;
  await act(async () => toggle.click());
  const row = container.querySelector<HTMLButtonElement>('.watch-details-button')!;
  const title = row.querySelector('span')!.textContent;
  row.focus();
  await act(async () => row.click());
  expect(container.querySelector('.selected-task h3')?.textContent).toBe(title);
  expect(container.querySelector('.work-area')?.classList.contains('mobile-details-open')).toBe(true);
  expect(document.activeElement).toBe(container.querySelector('.activity-panel'));
  await act(async () => container.querySelector<HTMLButtonElement>('.mobile-back')!.click());
  expect(document.activeElement).toBe(row);
});
