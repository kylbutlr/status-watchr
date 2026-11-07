import { collectorHealthLabel, type CollectorHealth } from './collector-health';

const macSetup = 'https://github.com/kylbutlr/status-watchr/blob/main/apps/macos/README.md#configure-your-server';

export function ActivityEmptyState({ loading, error, filtered, health, onShowAll, onRefresh, onConnection }: {
  loading: boolean;
  error: string | null;
  filtered: boolean;
  health: CollectorHealth | null;
  onShowAll: () => void;
  onRefresh: () => void;
  onConnection: () => void;
}) {
  if (loading) return <p className="empty-state" role="status">Loading recent activity…</p>;
  if (error) return <section className="activity-empty" aria-label="Activity unavailable">
    <h3>Activity couldn’t load</h3>
    <p>Check your server connection, then try again.</p>
    <button type="button" onClick={onRefresh}>Try again</button>
  </section>;
  if (filtered) return <section className="activity-empty" aria-label="No matching activity">
    <h3>No conversations in this view</h3>
    <p>Try All to see your other recent activity.</p>
    <button type="button" onClick={onShowAll}>Show all activity</button>
  </section>;

  const stale = health && (!Number.isFinite(Date.parse(health.received_at)) || Date.now() - Date.parse(health.received_at) > 180_000);
  const title = !health ? 'Connect your Mac' : stale ? 'Check your Mac connection' : !health.source_available ? 'Codex activity is unavailable' : 'Your Mac has checked in';
  const description = !health
    ? 'The dashboard receives activity from the Mac observer. Connect it to this server with its ingestion token, then start monitoring. The dashboard password is separate.'
    : stale
      ? 'The last Mac check-in is out of date. Check that the observer is running and can reach this server.'
      : !health.source_available
        ? 'The observer can reach this server, but cannot read local Codex activity. Check its source status on your Mac.'
        : 'No recent conversations have arrived yet. Start a Codex conversation on your Mac. Watching conversations and enabling alerts are optional.';

  return <section className="activity-empty" aria-label="Mac connection setup">
    <h3>{title}</h3>
    <p>{description}</p>
    <div className="activity-empty-actions">
      <a href={macSetup} target="_blank" rel="noreferrer">{health ? 'Mac setup and troubleshooting' : 'Set up the Mac observer'} ↗</a>
      <button type="button" onClick={onConnection}>Connection details</button>
    </div>
    {health ? <p className="activity-empty-status">{collectorHealthLabel(health)}</p> : null}
  </section>;
}
