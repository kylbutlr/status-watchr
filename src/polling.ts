const maximumPollingDelayMs = 5 * 60 * 1_000;

export function pollingDelayMs(intervalSeconds: number, consecutiveFailures = 0) {
  const baseDelay = Math.max(1, intervalSeconds) * 1_000;
  const multiplier = 2 ** Math.max(0, consecutiveFailures);
  return Math.min(baseDelay * multiplier, maximumPollingDelayMs);
}
