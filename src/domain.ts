export type AgentStatus = "working" | "needs_you" | "finished" | "failed" | "stale";

export const pollingIntervalOptions = [0, 15, 30, 60, 300] as const;
export type PollingInterval = typeof pollingIntervalOptions[number];
export const defaultPollingInterval: PollingInterval = 30;

export function savedPollingInterval(saved: string | null): PollingInterval {
  if (saved === null || saved.trim() === '') return defaultPollingInterval;
  const seconds = Number(saved);
  if (seconds === 120) return 60;
  if ([900, 1_800, 3_600].includes(seconds)) return 300;
  return pollingIntervalOptions.find(option => option === seconds) ?? defaultPollingInterval;
}

export function pollingIntervalLabel(seconds: PollingInterval) {
  if (seconds === 0) return "On open / focus";
  if (seconds < 60) return `Every ${seconds} seconds`;
  const minutes = seconds / 60;
  return `Every ${minutes} minute${minutes === 1 ? "" : "s"}`;
}

export type AgentEvent = {
  id: string;
  label: string;
  detail: string;
  occurredAt: string;
  occurredAtIso?: string;
  tone: "working" | "attention" | "success" | "danger" | "quiet";
};

export type AgentSession = {
  id: string;
  threadId?: string;
  title: string;
  repo: string;
  branch: string;
  status: AgentStatus;
  statusLabel: string;
  statusDetail: string;
  lastSeen: string;
  lastSeenAt?: string;
  elapsed: string;
  startedAt?: string | null;
  finishedAt?: string | null;
  events: AgentEvent[];
};

type LiveEventRecord = {
  id: string;
  session_id: string;
  event_type: string;
  label: string;
  subtask_title?: string | null;
  detail: string | null;
  tone: AgentEvent["tone"];
  occurred_at: string;
};

type LiveSessionRecord = {
  id: string;
  thread_id: string | null;
  title: string;
  repo: string | null;
  branch: string | null;
  status: AgentStatus;
  status_detail: string | null;
  last_seen_at: string;
  last_event_at?: string | null;
  started_at: string | null;
  finished_at: string | null;
};

export const statusLabels: Record<AgentStatus, string> = {
  working: "In progress",
  needs_you: "Needs you",
  finished: "Finished",
  failed: "Failed",
  stale: "Stale",
};

export type FaviconStatus = "default" | "working" | "attention" | "finished";

export const finishedFaviconWindowMs = 5 * 60 * 1_000;

export function hasRecentlyFinished(sessions: AgentSession[], now = Date.now()) {
  return sessions.some((session) => {
    if (session.status !== "finished" || !session.finishedAt) return false;
    const finishedAt = Date.parse(session.finishedAt);
    const elapsed = now - finishedAt;
    return !Number.isNaN(finishedAt) && elapsed >= 0 && elapsed <= finishedFaviconWindowMs;
  });
}

export function faviconStatus(counts: Record<AgentStatus, number>, recentlyFinished = false): FaviconStatus {
  if (counts.needs_you > 0 || counts.failed > 0) return "attention";
  if (counts.working > 0) return "working";
  if (recentlyFinished) return "finished";
  return "default";
}

export function faviconHref(status: FaviconStatus) {
  const path = status === "working" ? "/favicon-working.svg" : status === "attention" ? "/favicon-attention.svg" : status === "finished" ? "/favicon-finished.svg" : "/favicon.svg";
  return `${path}?status=${status}`;
}

export function faviconTitle(status: FaviconStatus) {
  if (status === "attention") return "Needs attention · Status Watchr";
  if (status === "working") return "Working · Status Watchr";
  if (status === "finished") return "Finished · Status Watchr";
  return "Status Watchr";
}

export function relativeTime(value: string | null) {
  if (!value) return "Unknown";
  const timestamp = Date.parse(value);
  if (Number.isNaN(timestamp)) return "Unknown";
  const seconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1_000));
  if (seconds < 60) return "Just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

export function repositoryLabel(value: string) {
  const cleanValue = value.replace(/[?#].*$/, "").replace(/\/+$/, "");
  const lastSegment = cleanValue.split(/[/:]/).filter(Boolean).at(-1);
  if (!lastSegment) return value;
  try {
    return decodeURIComponent(lastSegment).replace(/\.git$/i, "");
  } catch {
    return lastSegment.replace(/\.git$/i, "");
  }
}

const knownActivityLabels: Record<string, string> = {
  "turn/started": "Turn started",
  "turn/completed": "Turn completed",
  "item/commandExecution/requestApproval": "Command approval requested",
  "item/fileChange/requestApproval": "File change approval requested",
  "tool/requestUserInput": "Input requested",
  "thread/status/changed": "Status updated",
  "local/task/started": "Task started",
  "local/task/completed": "Task completed",
  "local/task/aborted": "Task interrupted",
};

export function activityLabel(label: string, eventType?: string) {
  if (eventType && knownActivityLabels[eventType]) return knownActivityLabels[eventType];
  if (knownActivityLabels[label]) return knownActivityLabels[label];
  return label
    .replace(/^codex[ /]hook[ /]/i, "")
    .replace(/[\/_-]+/g, " ")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/^\w/, (character) => character.toUpperCase());
}

export function elapsedTime(startedAt: string | null, finishedAt: string | null) {
  if (!startedAt) return "Unknown";
  const started = Date.parse(startedAt);
  const finished = finishedAt ? Date.parse(finishedAt) : Date.now();
  if (Number.isNaN(started) || Number.isNaN(finished) || finished < started) return "Unknown";
  const minutes = Math.max(1, Math.floor((finished - started) / 60_000));
  return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

const liveTones = new Set<AgentEvent["tone"]>(["working", "attention", "success", "danger", "quiet"]);
const liveStatuses = new Set<AgentStatus>(["working", "needs_you", "finished", "failed", "stale"]);
const statusPriority: Record<AgentStatus, number> = { needs_you: 0, failed: 1, working: 2, finished: 3, stale: 4 };

function timestamp(value: string | null | undefined) {
  const parsed = Date.parse(value ?? "");
  return Number.isNaN(parsed) ? 0 : parsed;
}

function sessionTime(session: LiveSessionRecord) {
  return timestamp(session.last_event_at) || timestamp(session.started_at) || timestamp(session.last_seen_at);
}

function isNewerSession(candidate: LiveSessionRecord, current: LiveSessionRecord) {
  const timeDifference = sessionTime(candidate) - sessionTime(current);
  if (timeDifference !== 0) return timeDifference > 0;
  const lastSeenDifference = timestamp(candidate.last_seen_at) - timestamp(current.last_seen_at);
  if (lastSeenDifference !== 0) return lastSeenDifference > 0;
  return candidate.id > current.id;
}

function mapLiveEventRecord(value: unknown) {
  const event = value as Partial<LiveEventRecord>;
  if (typeof event.id !== "string" || typeof event.session_id !== "string" || typeof event.label !== "string" || typeof event.occurred_at !== "string") return null;
  const tone = liveTones.has(event.tone as AgentEvent["tone"]) ? event.tone as AgentEvent["tone"] : "quiet";
  return {
    sessionId: event.session_id,
    sortAt: timestamp(event.occurred_at),
    event: {
      id: event.id,
      label: typeof event.subtask_title === 'string' && event.subtask_title.trim()
        ? `${event.subtask_title.trim().slice(0, 500)}: ${activityLabel(event.label, event.event_type)}`
        : activityLabel(event.label, event.event_type),
      detail: event.detail ?? event.event_type ?? "Activity received",
      occurredAt: relativeTime(event.occurred_at),
      occurredAtIso: event.occurred_at,
      tone,
    } satisfies AgentEvent,
  };
}

export function mapLiveEvents(payload: unknown): AgentEvent[] {
  if (!payload || typeof payload !== "object") return [];
  const events = (payload as { events?: unknown }).events;
  if (!Array.isArray(events)) return [];
  return events
    .map(mapLiveEventRecord)
    .filter((event): event is NonNullable<typeof event> => event !== null)
    .sort((left, right) => right.sortAt - left.sortAt)
    .map(({ event }) => event);
}

export function mapLiveSessions(payload: unknown): AgentSession[] {
  if (!payload || typeof payload !== "object") return [];
  const body = payload as { sessions?: unknown; events?: unknown };
  if (!Array.isArray(body.sessions)) return [];
  const eventsBySession = new Map<string, Array<AgentEvent & { sortAt: number }>>();

  if (Array.isArray(body.events)) {
    for (const value of body.events) {
      const mappedEvent = mapLiveEventRecord(value);
      if (!mappedEvent) continue;
      const sessionEvents = eventsBySession.get(mappedEvent.sessionId) ?? [];
      sessionEvents.push({ ...mappedEvent.event, sortAt: mappedEvent.sortAt });
      eventsBySession.set(mappedEvent.sessionId, sessionEvents);
    }
  }

  const taskGroups = new Map<string, { representative: LiveSessionRecord; sessionIds: string[] }>();
  for (const value of body.sessions) {
    const session = value as Partial<LiveSessionRecord>;
    if (
      typeof session.id !== "string" ||
      typeof session.title !== "string" ||
      typeof session.last_seen_at !== "string" ||
      !liveStatuses.has(session.status as AgentStatus)
    ) continue;
    const validSession = session as LiveSessionRecord;
    const taskId = validSession.thread_id ?? validSession.id;
    const taskGroup = taskGroups.get(taskId);
    if (!taskGroup) {
      taskGroups.set(taskId, { representative: validSession, sessionIds: [validSession.id] });
      continue;
    }
    taskGroup.sessionIds.push(validSession.id);
    if (isNewerSession(validSession, taskGroup.representative)) taskGroup.representative = validSession;
  }

  return Array.from(taskGroups.values())
    .sort((left, right) => {
      const statusDifference = statusPriority[left.representative.status] - statusPriority[right.representative.status];
      if (statusDifference !== 0) return statusDifference;
      return timestamp(right.representative.last_seen_at) - timestamp(left.representative.last_seen_at);
    })
    .map(({ representative: session, sessionIds }) => ({
      id: session.id,
      threadId: session.thread_id ?? session.id,
      title: session.title,
      repo: session.repo ?? "Local Codex",
      branch: session.branch ?? "No branch",
      status: session.status as AgentStatus,
      statusLabel: statusLabels[session.status as AgentStatus],
      statusDetail: session.status_detail ?? statusLabels[session.status as AgentStatus],
      lastSeen: relativeTime(session.last_seen_at),
      lastSeenAt: session.last_seen_at,
      elapsed: elapsedTime(session.started_at ?? null, session.finished_at ?? null),
      startedAt: session.started_at,
      finishedAt: session.finished_at,
      events: sessionIds
        .flatMap((sessionId) => eventsBySession.get(sessionId) ?? [])
        .sort((left, right) => right.sortAt - left.sortAt)
        .map(({ sortAt: _sortAt, ...event }) => event),
    }));
}

export const demoSessions: AgentSession[] = [
  {
    id: "session-01",
    title: "Audit collection filter behavior",
    repo: "fieldnotes-storefront",
    branch: "demo/collection-filters",
    status: "working",
    statusLabel: "Working",
    statusDetail: "Running browser checks",
    lastSeen: "Just now",
    elapsed: "14m",
    events: [
      { id: "e-01", label: "Browser check started", detail: "Collection route /collections/new-arrivals", occurredAt: "Just now", tone: "working" },
      { id: "e-02", label: "Files changed", detail: "2 files in working tree", occurredAt: "2m ago", tone: "quiet" },
      { id: "e-03", label: "Turn started", detail: "Implement the requested visual chip behavior", occurredAt: "14m ago", tone: "quiet" },
    ],
  },
  {
    id: "session-02",
    title: "Review the release checklist",
    repo: "component-library",
    branch: "demo/release-check",
    status: "needs_you",
    statusLabel: "Needs you",
    statusDetail: "Waiting on command approval",
    lastSeen: "3m ago",
    elapsed: "8m",
    events: [
      { id: "e-04", label: "Approval requested", detail: "Run the release validation command", occurredAt: "3m ago", tone: "attention" },
      { id: "e-05", label: "Plan updated", detail: "2 of 3 checks complete", occurredAt: "5m ago", tone: "quiet" },
      { id: "e-06", label: "Turn started", detail: "Prepare the release checklist", occurredAt: "8m ago", tone: "quiet" },
    ],
  },
  {
    id: "session-03",
    title: "Reconcile this week’s activity",
    repo: "project-notes",
    branch: "demo/activity-review",
    status: "finished",
    statusLabel: "Finished",
    statusDetail: "Completed successfully",
    lastSeen: "18m ago",
    elapsed: "22m",
    events: [
      { id: "e-07", label: "Turn completed", detail: "All requested checks passed", occurredAt: "18m ago", tone: "success" },
      { id: "e-08", label: "Tests passed", detail: "31 tests in 1.8s", occurredAt: "19m ago", tone: "success" },
      { id: "e-09", label: "Turn started", detail: "Reconcile same-day activity", occurredAt: "40m ago", tone: "quiet" },
    ],
  },
  {
    id: "session-04",
    title: "Check webhook callback contract",
    repo: "demo-service",
    branch: "demo/webhook-contract",
    status: "failed",
    statusLabel: "Failed",
    statusDetail: "Needs a client-provided example",
    lastSeen: "1h ago",
    elapsed: "11m",
    events: [
      { id: "e-10", label: "Turn failed", detail: "Expected callback example was not available", occurredAt: "1h ago", tone: "danger" },
      { id: "e-11", label: "Input requested", detail: "Waiting for the example payload contract", occurredAt: "1h ago", tone: "attention" },
      { id: "e-12", label: "Turn started", detail: "Check inbound callback contract", occurredAt: "1h ago", tone: "quiet" },
    ],
  },
];

export function countSessions(sessions: AgentSession[]) {
  return sessions.reduce(
    (counts, session) => {
      counts[session.status] += 1;
      return counts;
    },
    { working: 0, needs_you: 0, finished: 0, failed: 0, stale: 0 } as Record<AgentStatus, number>,
  );
}
