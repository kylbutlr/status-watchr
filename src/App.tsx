import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { countSessions, savedPollingInterval, demoSessions, elapsedTime, faviconStatus, faviconTitle, finishedFaviconWindowMs, hasRecentlyFinished, mapLiveEvents, mapLiveSessions, pollingIntervalLabel, pollingIntervalOptions, relativeTime, repositoryLabel, statusLabels, type AgentEvent, type AgentSession, type AgentStatus, type FaviconStatus, type PollingInterval } from "./domain";
import { replaceFavicon } from "./favicon";
import { useWorkSwitch } from "./work-switch";
import { pollingDelayMs } from "./polling";
import { NotificationOverview, NotificationProvider, Notifications, type WatchedConversation } from "./Notifications";
import { collectorHealthLabel, type CollectorHealth } from "./collector-health";
import { MacCheckIn } from "./MacCheckIn";
import { mergeSessionPage, refreshSessionPage } from './session-pages';

type Filter = "all" | AgentStatus;

const filterOptions: Array<{ value: Filter; label: string }> = [
  { value: "all", label: "All" },
  { value: "working", label: "In progress" },
  { value: "needs_you", label: "Needs you" },
  { value: "finished", label: "Finished" },
  { value: "failed", label: "Failed" },
];

const activeStatuses = new Set<AgentStatus>(["needs_you", "failed", "working"]);
const liveSessionPageSize = 10;

function StatusDot({ status }: { status: AgentStatus }) {
  return <span aria-hidden="true" className={`status-dot status-dot-${status}`} />;
}

function App() {
  const isLocalDemo = import.meta.env.DEV && import.meta.env.VITE_WATCHR_LIVE !== "true";
  const [previewCheckInAt] = useState(() => new Date(Date.now() - 120_000).toISOString());
  const [authState, setAuthState] = useState<"checking" | "signed_out" | "signed_in">(isLocalDemo ? "signed_in" : "checking");
  const [filter, setFilter] = useState<Filter>("all");
  const [selectedId, setSelectedId] = useState(demoSessions[0].id);
  const [mobileDetailsOpen, setMobileDetailsOpen] = useState(false);
  const [selectedWatch, setSelectedWatch] = useState<WatchedConversation | null>(null);
  const detailPanel = useRef<HTMLElement>(null);
  const returnTarget = useRef<HTMLElement | null>(null);
  const listScroll = useRef(0);
  const selectedThread = useRef<string | null>(null);
  const openConversation = (id: string) => {
    setSelectedWatch(null);
    returnTarget.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    listScroll.current = window.scrollY;
    const conversation = sessions.find(session => session.id === id);
    selectedThread.current = conversation?.threadId ?? id;
    setSelectedId(id);
    setMobileDetailsOpen(true);
  };
  useEffect(() => {
    if (!mobileDetailsOpen || !window.matchMedia('(max-width: 850px)').matches) return;
    detailPanel.current?.focus({ preventScroll: true });
    detailPanel.current?.scrollIntoView({ block: 'start' });
  }, [mobileDetailsOpen]);
  const openWatch = (watch: WatchedConversation) => {
    returnTarget.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    listScroll.current = window.scrollY;
    selectedThread.current = watch.threadId;
    setSelectedWatch(watch);
    setSelectedId(watch.session?.id ?? watch.threadId);
    setMobileDetailsOpen(true);
    requestAnimationFrame(() => {
      detailPanel.current?.focus({ preventScroll: true });
      detailPanel.current?.scrollIntoView({ block: 'start' });
    });
  };
  const backToConversations = () => {
    setMobileDetailsOpen(false);
    requestAnimationFrame(() => {
      returnTarget.current?.focus({ preventScroll: true });
      window.scrollTo({ top: listScroll.current });
    });
  };
  const workSwitch = useWorkSwitch(!isLocalDemo && authState === "signed_in");
  const [showConnection, setShowConnection] = useState(false);
  const [liveSessions, setLiveSessions] = useState<AgentSession[]>([]);
  const [liveError, setLiveError] = useState<string | null>(null);
  const [lastSyncAt, setLastSyncAt] = useState<Date | null>(null);
  const [collectorHealth, setCollectorHealth] = useState<CollectorHealth | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [loadMoreError, setLoadMoreError] = useState<string | null>(null);
  const [sessionCursor, setSessionCursor] = useState<string | null>(null);
  const [liveCounts, setLiveCounts] = useState<Record<AgentStatus, number>>({ working: 0, needs_you: 0, finished: 0, failed: 0, stale: 0 });
  const [statusClock, setStatusClock] = useState(0);
  const [snapshotRevision, setSnapshotRevision] = useState("");
  const [timelineEvents, setTimelineEvents] = useState<Record<string, AgentEvent[]>>({});
  const refreshController = useRef<AbortController | null>(null);
  const timelineController = useRef<AbortController | null>(null);
  const loadMoreController = useRef<AbortController | null>(null);
  const snapshotRevisionRef = useRef<string | null>(null);
  const groupingRevisionRef = useRef<string | null>(null);
  const sessionCursorRef = useRef<string | null>(null);
  const loadedPageCountRef = useRef(0);
  const [pollingInterval, setPollingInterval] = useState<PollingInterval>(() => {
    const saved = window.localStorage.getItem("statusWatchr.pollingSeconds");
    return savedPollingInterval(saved);
  });
  useEffect(() => {
    window.localStorage.setItem("statusWatchr.pollingSeconds", String(pollingInterval));
  }, [pollingInterval]);
  const sessions = isLocalDemo ? demoSessions : liveSessions;
  const counts = isLocalDemo ? countSessions(sessions) : liveCounts;
  const currentFaviconStatus: FaviconStatus = authState === "signed_in" ? faviconStatus(counts, hasRecentlyFinished(sessions)) : "default";

  useEffect(() => {
    replaceFavicon(currentFaviconStatus);
    document.title = faviconTitle(currentFaviconStatus);
  }, [currentFaviconStatus]);

  useEffect(() => {
    const expiryTimes = sessions
      .filter((session) => session.status === "finished" && session.finishedAt)
      .map((session) => Date.parse(session.finishedAt as string) + finishedFaviconWindowMs)
      .filter((expiry) => Number.isFinite(expiry) && expiry > Date.now());
    const nextExpiry = Math.min(...expiryTimes);
    if (!Number.isFinite(nextExpiry)) return;
    const timer = window.setTimeout(() => setStatusClock((current) => current + 1), Math.max(0, nextExpiry - Date.now() + 1));
    return () => window.clearTimeout(timer);
  }, [sessions, statusClock]);

  const selectedSession = selectedWatch
    ? sessions.find(session => (session.threadId ?? session.id) === selectedWatch.threadId) ?? selectedWatch.session
    : sessions.find((session) => session.id === selectedId) ?? sessions[0];
  const visibleSessions = useMemo(
    () => filter === "all" ? sessions : sessions.filter((session) => session.status === filter),
    [filter, sessions],
  );
  const activeSessions = visibleSessions.filter((session) => activeStatuses.has(session.status));
  const quietSessions = visibleSessions.filter((session) => !activeStatuses.has(session.status));
  const totalActiveCount = isLocalDemo ? activeSessions.length : filter === "all"
    ? counts.needs_you + counts.failed + counts.working
    : activeStatuses.has(filter as AgentStatus) ? counts[filter as AgentStatus] : 0;
  const totalQuietCount = isLocalDemo ? quietSessions.length : filter === "all"
    ? counts.finished + counts.stale
    : activeStatuses.has(filter as AgentStatus) ? 0 : counts[filter as AgentStatus];
  const totalVisibleCount = filter === "all" ? Object.values(counts).reduce((total, count) => total + count, 0) : counts[filter as AgentStatus];
  const remainingSessionCount = Math.max(0, totalVisibleCount - sessions.length);
  const nextSessionCount = Math.min(liveSessionPageSize, remainingSessionCount);
  const handleFilterChange = (nextFilter: Filter) => {
    setSelectedWatch(null);
    setMobileDetailsOpen(false);
    const nextSessions = nextFilter === "all" ? sessions : sessions.filter((session) => session.status === nextFilter);
    loadMoreController.current?.abort();
    sessionCursorRef.current = null;
    loadedPageCountRef.current = 0;
    snapshotRevisionRef.current = null;
    setSessionCursor(null);
    setSnapshotRevision("");
    setLoadMoreError(null);
    if (!isLocalDemo) setLiveSessions([]);
    setFilter(nextFilter);
    if (nextSessions[0]) setSelectedId(nextSessions[0].id);
  };

  const loadLiveSessions = useCallback(async (force = false): Promise<"success" | "failure" | "skipped"> => {
    if (document.visibilityState === "hidden" || !navigator.onLine) return "skipped";
    refreshController.current?.abort();
    const controller = new AbortController();
    refreshController.current = controller;
    setIsRefreshing(true);
    try {
      void fetch("/api/collector", { cache: "no-store", signal: controller.signal }).then(async (response) => {
        if (!response.ok) { setCollectorHealth(null); return; }
        const health = await response.json();
        if (!controller.signal.aborted) setCollectorHealth(health.collector ?? null);
      }).catch(() => { if (!controller.signal.aborted) setCollectorHealth(null); });
      const params = new URLSearchParams();
      if (filter !== "all") params.set("status", filter);
      if (!force && snapshotRevisionRef.current) params.set("since", snapshotRevisionRef.current);
      const query = params.size ? `?${params}` : "";
      const response = await fetch(`/api/sessions${query}`, { cache: "no-store", signal: controller.signal });
      if (response.status === 401) {
        setAuthState("signed_out");
        return "skipped";
      }
      if (response.status === 304) {
        setLastSyncAt(new Date());
        setLiveError(null);
        return "success";
      }
      if (!response.ok) throw new Error(`Unable to load live sessions (${response.status})`);
      const payload = await response.json() as {
        revision?: unknown;
        groupingRevision?: unknown;
        counts?: Partial<Record<AgentStatus, unknown>>;
        nextCursor?: unknown;
      };
      const nextRevision = typeof payload.revision === "string" ? payload.revision : response.headers.get("x-status-watchr-revision");
      if (controller.signal.aborted) return 'skipped';
      const firstPage = mapLiveSessions(payload);
      const groupingRevision = typeof payload.groupingRevision === 'string' ? payload.groupingRevision : null;
      const groupingChanged = groupingRevisionRef.current !== groupingRevision;
      groupingRevisionRef.current = groupingRevision;
      const preserveLoadedPages = loadedPageCountRef.current > 1 && !groupingChanged;
      if (groupingChanged) {
        loadMoreController.current?.abort();
        timelineController.current?.abort();
        setTimelineEvents({});
      }
      if (preserveLoadedPages) setLiveSessions((current) => refreshSessionPage(current, firstPage));
      else {
        loadedPageCountRef.current = 1;
        setLiveSessions(firstPage);
        const nextCursor = typeof payload.nextCursor === "string" ? payload.nextCursor : null;
        sessionCursorRef.current = nextCursor;
        setSessionCursor(nextCursor);
      }
      if (payload.counts) {
        setLiveCounts({
          working: Number(payload.counts.working) || 0,
          needs_you: Number(payload.counts.needs_you) || 0,
          finished: Number(payload.counts.finished) || 0,
          failed: Number(payload.counts.failed) || 0,
          stale: Number(payload.counts.stale) || 0,
        });
      }
      if (nextRevision) {
        snapshotRevisionRef.current = nextRevision;
        setSnapshotRevision(nextRevision);
      }
      setLastSyncAt(new Date());
      setLiveError(null);
      return "success";
    } catch (error) {
      if (controller.signal.aborted) return "skipped";
      setLiveError(error instanceof Error ? error.message : "Unable to load live sessions");
      return "failure";
    } finally {
      if (refreshController.current === controller) {
        refreshController.current = null;
        setIsRefreshing(false);
      }
    }
  }, [filter]);

  const loadMoreSessions = useCallback(async () => {
    const cursor = sessionCursorRef.current;
    if (!cursor || isLocalDemo || isLoadingMore) return;
    loadMoreController.current?.abort();
    const controller = new AbortController();
    loadMoreController.current = controller;
    setIsLoadingMore(true);
    setLoadMoreError(null);
    try {
      const params = new URLSearchParams({ cursor });
      if (filter !== "all") params.set("status", filter);
      const response = await fetch(`/api/sessions?${params}`, { cache: "no-store", signal: controller.signal });
      if (response.status === 401) {
        setAuthState("signed_out");
        return;
      }
      if (!response.ok) throw new Error(`Unable to load more sessions (${response.status})`);
      const payload = await response.json() as {
        counts?: Partial<Record<AgentStatus, unknown>>;
        nextCursor?: unknown;
        groupingRevision?: unknown;
      };
      if (controller.signal.aborted) return;
      if (typeof payload.groupingRevision === 'string' && payload.groupingRevision !== groupingRevisionRef.current) {
        await loadLiveSessions(true);
        return;
      }
      const page = mapLiveSessions(payload);
      setLiveSessions((current) => mergeSessionPage(current, page));
      loadedPageCountRef.current += 1;
      const nextCursor = typeof payload.nextCursor === "string" ? payload.nextCursor : null;
      sessionCursorRef.current = nextCursor;
      setSessionCursor(nextCursor);
      if (payload.counts) {
        setLiveCounts({
          working: Number(payload.counts.working) || 0,
          needs_you: Number(payload.counts.needs_you) || 0,
          finished: Number(payload.counts.finished) || 0,
          failed: Number(payload.counts.failed) || 0,
          stale: Number(payload.counts.stale) || 0,
        });
      }
    } catch (error) {
      if (!controller.signal.aborted) setLoadMoreError(error instanceof Error ? error.message : "Unable to load more sessions");
    } finally {
      if (loadMoreController.current === controller) {
        loadMoreController.current = null;
        setIsLoadingMore(false);
      }
    }
  }, [filter, isLocalDemo, isLoadingMore, loadLiveSessions]);

  const loadTimeline = useCallback(async (sessionId: string) => {
    if (!sessionId || document.visibilityState === "hidden" || !navigator.onLine) return;
    timelineController.current?.abort();
    const controller = new AbortController();
    timelineController.current = controller;
    try {
      const response = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/events`, { cache: "no-store", signal: controller.signal });
      if (response.status === 401) {
        setAuthState("signed_out");
        return;
      }
      if (!response.ok) return;
      const events = mapLiveEvents(await response.json());
      if (controller.signal.aborted) return;
      setTimelineEvents((current) => ({ ...current, [sessionId]: events }));
    } catch {
      // Keep the latest event supplied by the compact snapshot as a fallback.
    } finally {
      if (timelineController.current === controller) timelineController.current = null;
    }
  }, []);

  const handlePollingIntervalChange = (value: string) => {
    const nextInterval = Number(value) as PollingInterval;
    if (!pollingIntervalOptions.includes(nextInterval)) return;
    setPollingInterval(nextInterval);
    window.localStorage.setItem("statusWatchr.pollingSeconds", String(nextInterval));
  };

  useEffect(() => {
    if (isLocalDemo) return;
    fetch("/api/auth/session").then(async (response) => {
      const result = await response.json() as { authenticated?: boolean };
      setAuthState(result.authenticated ? "signed_in" : "signed_out");
    }).catch(() => setAuthState("signed_out"));
  }, [isLocalDemo]);

  useEffect(() => {
    if (isLocalDemo || authState !== "signed_in") return;
    let refreshTimer: number | undefined;
    let runGeneration = 0;
    let consecutiveFailures = 0;
    let stopped = false;

    const schedule = () => {
      if (stopped || (pollingInterval === 0 && workSwitch.allowed()) || document.visibilityState === "hidden" || !navigator.onLine) return;
      refreshTimer = window.setTimeout(() => void run(), workSwitch.allowed() ? pollingDelayMs(pollingInterval, consecutiveFailures) : 30_000);
    };
    const run = async () => {
      const generation = ++runGeneration;
      if (refreshTimer !== undefined) window.clearTimeout(refreshTimer);
      const result = workSwitch.allowed() ? await loadLiveSessions() : "paused";
      if (stopped || generation !== runGeneration) return;
      if (result === "failure") consecutiveFailures += 1;
      if (result === "success") consecutiveFailures = 0;
      schedule();
    };
    const runImmediately = () => {
      if (document.visibilityState !== "visible" || !navigator.onLine) return;
      void run();
    };
    const handleVisibilityChange = () => {
      if (document.visibilityState === "visible") runImmediately();
    };
    document.addEventListener("visibilitychange", handleVisibilityChange);
    window.addEventListener("focus", runImmediately);
    window.addEventListener("online", runImmediately);
    runImmediately();
    return () => {
      stopped = true;
      runGeneration += 1;
      if (refreshTimer !== undefined) window.clearTimeout(refreshTimer);
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      window.removeEventListener("focus", runImmediately);
      window.removeEventListener("online", runImmediately);
      refreshController.current?.abort();
    };
  }, [authState, isLocalDemo, loadLiveSessions, pollingInterval, workSwitch.allowed, workSwitch.change]);

  useEffect(() => {
    if (isLocalDemo || authState !== "signed_in" || !selectedSession?.id) return;
    void loadTimeline(selectedSession.id);
    return () => timelineController.current?.abort();
  }, [authState, isLocalDemo, loadTimeline, selectedSession?.id, snapshotRevision]);

  useEffect(() => {
    // Keep the phone's open conversation stable if its status/filter or current run changes.
    if (selectedWatch) return;
    if (mobileDetailsOpen && selectedThread.current) {
      const conversation = sessions.find(session => (session.threadId ?? session.id) === selectedThread.current);
      if (conversation) { setSelectedId(conversation.id); return; }
      setMobileDetailsOpen(false);
    }
    if (visibleSessions.some((session) => session.id === selectedId)) return;
    setSelectedId(visibleSessions[0]?.id ?? "");
  }, [selectedId, visibleSessions, sessions, mobileDetailsOpen, selectedWatch]);

  const handleLogin = async (password: string) => {
    const response = await fetch("/api/auth/login", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ password }) });
    if (!response.ok) throw new Error((await response.json() as { error?: string }).error ?? "Unable to sign in");
    setAuthState("signed_in");
  };

  const handleLogout = async () => {
    if (!isLocalDemo) await fetch("/api/auth/logout", { method: "POST" });
    setAuthState("signed_out");
  };

  if (authState === "checking") return <div className="auth-loading">Checking private access…</div>;
  if (authState === "signed_out") return <LoginScreen onLogin={handleLogin} />;

  return (
    <NotificationProvider demo={isLocalDemo} automaticAllowed={workSwitch.allowed} workChange={workSwitch.change}><div className="app-shell">
      <header className="topbar">
        <a className="wordmark" href="/" aria-label="Status Watchr home">
          <span className="wordmark-mark"><span /><span /><span /></span>
          <span>status <strong>watchr</strong></span>
        </a>
        <div className="topbar-meta">
          <span className="private-pill"><span className="tiny-lock">●</span> Private</span>
          <button className="avatar" type="button" aria-label="Sign out" onClick={handleLogout}>kb</button>
        </div>
      </header>

      <main className="main-content">
        <NotificationOverview demo={isLocalDemo} sessions={sessions} onOpenWatch={openWatch}
          onSettingsClose={() => setShowConnection(false)}
          checkIn={<MacCheckIn receivedAt={isLocalDemo ? previewCheckInAt : collectorHealth?.received_at} />}
          collectorControls={<>
              <h2>Settings</h2>
              <p className="connection-detail">{workSwitch.label && <span title="Off pauses cloud sync and automatic alerts. Pending means confirmation is unavailable. Manual refresh remains available.">{workSwitch.label} · </span>}{isLocalDemo ? "Preview data (sample check-in)" : liveError ? "Dashboard refresh failed" : lastSyncAt ? `Dashboard refreshed ${relativeTime(lastSyncAt.toISOString()).toLowerCase()}` : "Waiting for first refresh"}</p>
              <div className="polling-controls">
                <label htmlFor="polling-interval">Dashboard refresh</label>
                <div className="polling-controls-row">
                  <select id="polling-interval" value={pollingInterval} onChange={(event) => handlePollingIntervalChange(event.target.value)}>
                    {pollingIntervalOptions.map((seconds) => <option key={seconds} value={seconds}>{pollingIntervalLabel(seconds)}</option>)}
                  </select>
                  <button className="refresh-button" type="button" aria-label="Refresh now" onClick={() => void loadLiveSessions(true)} disabled={isLocalDemo || isRefreshing}>
                    <span aria-hidden="true">↻</span>{isRefreshing ? "Refreshing" : "Refresh now"}
                  </button>
                </div>
              </div>
              <button className="text-button" type="button" onClick={() => setShowConnection((current) => !current)}>
                {showConnection ? "Hide details" : "View details"}
              </button>
          </>} />
        {showConnection ? (
          <section className="connection-detail-panel" aria-label="Connection details">
            <p className="collector-readiness" role="status">{isLocalDemo ? "Mac readiness is not measured in preview" : collectorHealthLabel(collectorHealth)}</p>
            <div><span className="detail-label">Source</span><strong>Mac lifecycle history and hooks</strong></div>
            <div><span className="detail-label">Transport</span><strong>Private HTTPS ingestion</strong></div>
            <div><span className="detail-label">Mode</span><strong>{isLocalDemo ? "Demo data" : "Live data"}</strong></div>
            <div><span className="detail-label">Phone access</span><strong>Observation only</strong></div>
            <p>
              The Mac sends conversation titles and lifecycle metadata to this private dashboard. Message bodies, source code, terminal output, and diffs are not stored or sent to the hosted service. A dashboard refresh does not prove the Mac observer is healthy. In-progress runs can be waiting for input; question detection remains unverified. Respond to questions and approvals on the Mac.
            </p>
          </section>
        ) : null}

        <section className="summary-grid" aria-label="Activity summary">
          <div className="summary-card summary-card-focus"><span className="summary-label">Needs attention</span><strong>{counts.needs_you + counts.failed}</strong><span className="summary-note">action items</span></div>
          <div className="summary-card"><span className="summary-label">In progress</span><strong>{counts.working}</strong><span className="summary-note">may be waiting for input</span></div>
          <div className="summary-card"><span className="summary-label">Finished</span><strong>{counts.finished}</strong><span className="summary-note">in this window</span></div>
          <div className="summary-card"><span className="summary-label">Loaded</span><strong>{sessions.length}</strong><span className="summary-note">recent sessions</span></div>
        </section>

        <section className={`work-area${mobileDetailsOpen ? ' mobile-details-open' : ''}`}>
          <div className="session-column">
            <div className="section-heading">
              <div><p className="eyebrow">Live queue</p><h2>Current work</h2></div>
              <span className="demo-badge">{isLocalDemo ? "Demo data" : isRefreshing ? "Refreshing" : liveError ? "Connection error" : "Live data"}</span>
            </div>
            <div className="filters" role="tablist" aria-label="Filter sessions">
              {filterOptions.map((option) => (
                <button key={option.value} className={filter === option.value ? "filter-button is-active" : "filter-button"} type="button" role="tab" aria-selected={filter === option.value} onClick={() => handleFilterChange(option.value)}>
                  {option.label}{option.value !== "all" ? <span>{counts[option.value]}</span> : null}
                </button>
              ))}
            </div>
            <div className="session-list">
              {activeSessions.length > 0 ? (
                <div className="queue-group queue-group-active">
                  <div className="queue-group-heading"><span>In progress and attention</span><strong>{totalActiveCount}</strong></div>
                  {activeSessions.map((session) => (
                    <SessionCard key={session.id} session={session} isSelected={session.id === selectedId} onSelect={() => openConversation(session.id)} />
                  ))}
                </div>
              ) : null}
              {quietSessions.length > 0 ? (
                <div className="queue-group queue-group-quiet">
                  <div className="queue-group-heading"><span>Recent and finished</span><strong>{totalQuietCount}</strong></div>
                  {quietSessions.map((session) => (
                    <SessionCard key={session.id} session={session} isSelected={session.id === selectedId} onSelect={() => openConversation(session.id)} />
                  ))}
                </div>
              ) : null}
              {sessionCursor && !isLocalDemo ? (
                <div className="queue-group">
                  <button className="load-more-button" type="button" onClick={() => void loadMoreSessions()} disabled={isLoadingMore}>
                    <span>{isLoadingMore ? "Loading…" : `Load ${nextSessionCount || liveSessionPageSize} more`}</span>
                    <small>{remainingSessionCount} remaining</small>
                  </button>
                  {loadMoreError ? <p className="load-more-error" role="alert">{loadMoreError}</p> : null}
                </div>
              ) : null}
              {visibleSessions.length === 0 ? <p className="empty-state">
                {!isLocalDemo && isRefreshing ? "Loading recent activity…" : liveError ? "Couldn’t load activity. Refresh to try again." : "Nothing in this view."}
              </p> : null}
            </div>
          </div>

          <aside className="activity-panel" ref={detailPanel} tabIndex={-1} aria-label="Conversation details">
            <button className="text-button mobile-back" type="button" onClick={backToConversations}>← Back to conversations</button>
            {selectedSession ? <>
              <div className="section-heading activity-heading"><div><p className="eyebrow">Selected task</p><h2>Activity log</h2></div><span className={`status-chip status-chip-${selectedSession.status}`}><StatusDot status={selectedSession.status} />{statusLabels[selectedSession.status]}</span></div>
              <div className="selected-task">
                <h3>{selectedSession.title}</h3>
                <SessionContext session={selectedSession} />
                <Notifications threadId={selectedSession.threadId ?? selectedSession.id} demo={isLocalDemo} />
                <div className="selected-task-facts">
                  <div><span>Duration</span><strong>{sessionElapsed(selectedSession)}</strong></div>
                  <div><span>Updates</span><strong>{selectedTimeline(selectedSession, timelineEvents, isLocalDemo).length}</strong></div>
                  <div><span>Last update</span><strong>{sessionLastSeen(selectedSession)}</strong></div>
                </div>
              </div>
              <div className="timeline">
                {selectedTimeline(selectedSession, timelineEvents, isLocalDemo).map((event) => <TimelineEvent key={event.id} event={event} />)}
              </div>
            </> : selectedWatch ? <div className="selected-task"><h3>Conversation {selectedWatch.threadId}</h3><p>Retained history is unavailable for this conversation.</p><Notifications threadId={selectedWatch.threadId} demo={isLocalDemo} /></div> : <div className="empty-state">No live activity has arrived yet. Start the Mac collector and refresh this page.</div>}
            <button className="secondary-button" type="button" onClick={() => setShowConnection(true)}>How this connects <span aria-hidden="true">↗</span></button>
          </aside>
        </section>
      </main>
      <footer className="footer"><span>status watchr</span><span>Designed for a glance, built for trust.</span></footer>
    </div></NotificationProvider>
  );
}

function SessionCard({ session, isSelected, onSelect }: { session: AgentSession; isSelected: boolean; onSelect: () => void }) {
  const latestActivity = session.events[0]?.label ?? session.statusDetail;
  return (
    <button className={`session-card session-card-status-${session.status}${isSelected ? " is-selected" : ""}`} type="button" aria-pressed={isSelected} onClick={onSelect}>
      <div className="session-card-top"><span className={`status-chip status-chip-${session.status}`}><StatusDot status={session.status} />{statusLabels[session.status]}</span><span className="session-time">{session.status === "working" || session.status === "needs_you" ? "Running" : "Took"} {sessionElapsed(session)}</span></div>
      <h3>{session.title}</h3>
      <SessionContext session={session} />
      <div className="session-card-bottom"><span>{latestActivity}</span><span>Updated {sessionLastSeen(session).toLowerCase()}</span></div>
    </button>
  );
}

function SessionContext({ session }: { session: AgentSession }) {
  return <div className="session-context"><span className="session-project" title={session.repo}>{repositoryLabel(session.repo)}</span>{session.branch !== "No branch" ? <span className="session-branch" title={session.branch}>{session.branch}</span> : null}</div>;
}

function TimelineEvent({ event }: { event: AgentSession["events"][number] }) {
  return <div className="timeline-event"><span className={`timeline-marker marker-${event.tone}`} /><div><strong>{event.label}</strong>{event.detail ? <p>{event.detail}</p> : null}</div><time>{event.occurredAtIso ? relativeTime(event.occurredAtIso) : event.occurredAt}</time></div>;
}

function sessionElapsed(session: AgentSession) {
  return session.startedAt !== undefined ? elapsedTime(session.startedAt, session.finishedAt ?? null) : session.elapsed;
}

function sessionLastSeen(session: AgentSession) {
  return session.lastSeenAt ? relativeTime(session.lastSeenAt) : session.lastSeen;
}

function selectedTimeline(session: AgentSession, timelines: Record<string, AgentEvent[]>, isLocalDemo: boolean) {
  return isLocalDemo ? session.events : timelines[session.id] ?? session.events;
}

function LoginScreen({ onLogin }: { onLogin: (password: string) => Promise<void> }) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const submit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError(null);
    setIsSubmitting(true);
    try {
      await onLogin(password);
    } catch (loginError) {
      setError(loginError instanceof Error ? loginError.message : "Unable to sign in");
    } finally {
      setIsSubmitting(false);
    }
  };

  return <main className="auth-shell"><div className="auth-card"><div className="auth-mark"><span /><span /><span /></div><p className="eyebrow">kylbutlr / private system</p><h1>Welcome back.</h1><p className="auth-copy">Status Watchr keeps a quiet eye on the work running on your Mac.</p><form onSubmit={submit}><label htmlFor="access-password">Access password</label><input id="access-password" type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} autoFocus /><button className="primary-button" type="submit" disabled={isSubmitting || password.length === 0}>{isSubmitting ? "Checking…" : "Sign in"}</button>{error ? <p className="auth-error" role="alert">{error}</p> : null}</form><p className="auth-footnote">Private by design. No activity is shown until you sign in.</p></div></main>;
}

export { App };
