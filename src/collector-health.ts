export type CollectorHealth = { source_available: boolean; hook_trust: "trusted" | "untrusted" | "unknown"; received_at: string; last_hook_at: string | null; queued: number };

export function collectorHealthLabel(health: CollectorHealth | null, now = Date.now()) {
  if (!health) return "Mac monitoring not verified";
  if (!Number.isFinite(Date.parse(health.received_at)) || now - Date.parse(health.received_at) > 180_000) return "Mac not reporting; status may be outdated";
  if (!health.source_available) return "Mac connected; local run source unavailable";
  if (health.hook_trust !== "trusted") return "Run history available; attention hooks need review";
  if (!health.last_hook_at) return "Run history available; hook execution not verified";
  return "Mac reporting; question detection unverified";
}
