import { describe, expect, it } from "vitest";
import { pollingDelayMs } from "../src/polling";
import { pollingIntervalOptions, savedPollingInterval } from '../src/domain';

describe("dashboard polling", () => {
  it("uses the selected interval after successful requests", () => {
    for (const seconds of pollingIntervalOptions.filter(value => value > 0)) {
      expect(pollingDelayMs(seconds)).toBe(seconds * 1000);
    }
  });

  it('preserves supported preferences and migrates removed choices', () => {
    for (const seconds of pollingIntervalOptions) expect(savedPollingInterval(String(seconds))).toBe(seconds);
    expect(savedPollingInterval('120')).toBe(60);
    for (const seconds of [900, 1800, 3600]) expect(savedPollingInterval(String(seconds))).toBe(300);
    for (const saved of [null, '', ' ', 'invalid', '-1', 'Infinity', '10']) expect(savedPollingInterval(saved)).toBe(30);
  });

  it("backs off repeated failures and caps the delay at five minutes", () => {
    expect(pollingDelayMs(30, 1)).toBe(60_000);
    expect(pollingDelayMs(30, 3)).toBe(240_000);
    expect(pollingDelayMs(30, 8)).toBe(300_000);
  });
});
