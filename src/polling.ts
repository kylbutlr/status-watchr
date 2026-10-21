const maximumPollingDelayMs = 5 * 60 * 1_000;

export function pollingDelayMs(intervalSeconds: number, consecutiveFailures = 0, unchangedPolls = 0) {
  const baseDelay = Math.max(1, intervalSeconds) * 1_000;
  if (consecutiveFailures === 0 && unchangedPolls > 0) {
    // Quiet dashboards leave an actual sleep window; active changes reset this immediately.
    return Math.min(Math.max(baseDelay, 30_000) * 2 ** Math.min(unchangedPolls, 5), 600_000);
  }
  const multiplier = 2 ** Math.max(0, consecutiveFailures);
  return Math.min(baseDelay * multiplier, maximumPollingDelayMs);
}
