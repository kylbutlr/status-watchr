import { describe, expect, it } from 'vitest';
import { notificationDuration } from '../src/notification-duration';

describe('notification duration choices', () => {
  it('keeps existing durations and represents Always on explicitly', () => {
    expect(notificationDuration('60')).toEqual({ minutes: 60 });
    expect(notificationDuration('always')).toEqual({ mode: 'always' });
  });
  it('ends at the next local calendar midnight, including month rollover', () => {
    for (const now of [new Date(2026, 0, 31, 23, 59, 59), new Date(2026, 2, 8, 0), new Date(2026, 10, 1, 0)]) {
      const result = notificationDuration('midnight', now);
      expect(result.mode).toBe('midnight');
      const until = new Date(result.until!);
      expect(until.getHours()).toBe(0); expect(until.getMinutes()).toBe(0);
      const expected = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
      expect(until.getTime()).toBe(expected.getTime());
      expect(until.getTime()).toBeGreaterThan(now.getTime());
    }
  });
});
