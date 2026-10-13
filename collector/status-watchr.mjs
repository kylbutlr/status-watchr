import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { closeSync, fstatSync, openSync, readSync } from "node:fs";
import readline from "node:readline";

const siteUrl = (process.env.STATUS_WATCHR_URL ?? "https://statuswatchr.netlify.app").replace(/\/$/u, "");
const codexBin = process.env.CODEX_BIN ?? "codex";
const dryRun = process.argv.includes("--dry-run");
const once = process.argv.includes("--once");
const intervalArgumentIndex = process.argv.findIndex((argument) => argument === "--interval");
const intervalArgument = intervalArgumentIndex >= 0 ? process.argv[intervalArgumentIndex + 1] : process.argv.find((argument) => argument.startsWith("--interval="))?.slice("--interval=".length);
const ingestToken = process.env.WATCHR_INGEST_TOKEN ?? "";

export function threadListParams(cursor) {
  return {
    archived: false,
    limit: 100,
    sortKey: "updated_at",
    sortDirection: "desc",
    ...(cursor ? { cursor } : {}),
  };
}

export function parseInterval(value = "15s") {
  const match = /^(\d+(?:\.\d+)?)(ms|s|m)$/u.exec(value.trim().toLowerCase());
  if (!match) throw new Error(`Invalid interval "${value}". Use a value such as 15s, 30s, or 1m.`);
  const amount = Number(match[1]);
  const multiplier = match[2] === "ms" ? 1 : match[2] === "s" ? 1_000 : 60_000;
  const milliseconds = amount * multiplier;
  if (milliseconds < 5_000) throw new Error("Interval must be at least 5s.");
  return milliseconds;
}

const intervalMs = parseInterval(intervalArgument ?? process.env.STATUS_WATCHR_INTERVAL ?? `${process.env.STATUS_WATCHR_INTERVAL_MS ?? 15_000}ms`);

const labels = {
  "turn/started": ["Turn started", "working"],
  "turn/completed": ["Turn completed", "quiet"],
  "item/commandExecution/requestApproval": ["Approval requested", "attention"],
  "item/fileChange/requestApproval": ["File approval requested", "attention"],
  "tool/requestUserInput": ["Input requested", "attention"],
  "thread/status/changed": ["Thread status changed", "quiet"],
  "local/task/started": ["Task started", "working"],
  "local/task/completed": ["Task completed", "success"],
  "local/task/aborted": ["Task aborted", "danger"],
};

export function localSessionState(filePath, maxBytes = 1_048_576) {
  let fileDescriptor;
  try {
    fileDescriptor = openSync(filePath, "r");
    const fileSize = fstatSync(fileDescriptor).size;
    const start = Math.max(0, fileSize - maxBytes);
    const buffer = Buffer.alloc(fileSize - start);
    readSync(fileDescriptor, buffer, 0, buffer.length, start);
    let latest = null;
    for (const line of buffer.toString("utf8").split("\n")) {
      try {
        const message = JSON.parse(line);
        if (message?.type !== "event_msg") continue;
        const payload = message.payload;
        if (!payload || !["task_started", "task_complete", "turn_aborted"].includes(payload.type)) continue;
        const status = payload.type === "task_started" ? "working" : payload.type === "task_complete" ? "finished" : "stale";
        const sourceTimestamp = payload.type === "task_started" ? payload.started_at : payload.completed_at;
        const occurredAtMs = Date.parse(typeof sourceTimestamp === "string" ? sourceTimestamp : typeof message.timestamp === "string" ? message.timestamp : "");
        latest = {
          status,
          marker: payload.turn_id ?? payload.turnId ?? "unknown",
          occurredAt: Number.isFinite(occurredAtMs) ? new Date(occurredAtMs).toISOString() : null,
        };
      } catch {
        // Ignore the partial first line when the bounded read starts mid-file.
      }
    }
    return latest;
  } catch {
    return null;
  } finally {
    if (fileDescriptor !== undefined) closeSync(fileDescriptor);
  }
}

export function turnSessionId(threadId, turnId) {
  return turnId && turnId !== "unknown" ? `${threadId}:turn:${turnId}` : threadId;
}

export function resolveThreadStatus(thread, localState) {
  const status = thread?.status;
  if (status?.type === "active" && status.activeFlags?.includes("waitingOnApproval")) return "needs_you";
  if (localState?.status) return localState.status;
  if (status?.type === "active") return "working";
  return undefined;
}

function threadIdFrom(message) {
  return message.params?.threadId ?? message.params?.turn?.threadId ?? message.params?.item?.threadId ?? null;
}

function statusFrom(message) {
  if (message.method === "turn/started") return "working";
  if (message.method === "turn/completed") {
    const status = message.params?.turn?.status;
    if (status === "completed") return "finished";
    if (status === "failed") return "failed";
    if (status === "interrupted") return "stale";
  }
  if (message.method === "thread/status/changed") {
    const status = message.params?.status;
    if (status?.type === "active" && status.activeFlags?.includes("waitingOnApproval")) return "needs_you";
    if (status?.type === "active") return "working";
  }
  if (message.method === "item/commandExecution/requestApproval" || message.method === "item/fileChange/requestApproval" || message.method === "tool/requestUserInput") return "needs_you";
  return undefined;
}

function eventLabel(message) {
  const known = labels[message.method];
  if (known) return known[0];
  const parts = message.method.split("/").filter(Boolean);
  const raw = parts.at(-1) ?? "event";
  return `${raw.replace(/([a-z])([A-Z])/gu, "$1 $2").replace(/[-_]/gu, " ")} event`;
}

function eventTone(message) {
  const known = labels[message.method];
  if (known) return known[1];
  return "quiet";
}

function stableEventId(message, threadId) {
  const copy = { ...message, emittedAtMs: undefined };
  return `codex-${createHash("sha256").update(JSON.stringify({ threadId, message: copy })).digest("hex").slice(0, 32)}`;
}

export function createEventDeduper() {
  const eventIds = new Set();
  return {
    has(eventId) {
      return eventIds.has(eventId);
    },
    mark(eventId) {
      eventIds.add(eventId);
    },
  };
}

export function createScanStateTracker(minimumHeartbeatMs = 120_000) {
  const states = new Map();
  const fingerprint = (event) => JSON.stringify([event.title, event.repo, event.branch, event.status]);
  return {
    shouldSend(event, nowMs = Date.now()) {
      const previous = states.get(event.sessionId);
      if (!previous || previous.fingerprint !== fingerprint(event)) return true;
      if (event.status !== "working" && event.status !== "needs_you") return false;
      return nowMs - previous.sentAtMs >= minimumHeartbeatMs;
    },
    mark(event, nowMs = Date.now()) {
      states.set(event.sessionId, { fingerprint: fingerprint(event), sentAtMs: nowMs });
    },
  };
}

export function projectLabel(value) {
  if (typeof value !== "string") return null;
  let path = value;
  if (value.includes("://")) {
    try { path = new URL(value).pathname; } catch { return null; }
  }
  return path.split(/[?#]/u)[0].split("/").filter(Boolean).at(-1)?.replace(/\.git$/u, "").slice(0, 120) ?? null;
}

export function normalizeNotification(message, context = {}, options = {}) {
  const threadId = threadIdFrom(message) ?? context.threadId;
  if (!threadId) return null;
  const thread = message.params?.thread ?? message.params?.threadInfo ?? context.thread ?? {};
  const status = statusFrom(message);
  const resolvedStatus = status ?? context.status ?? "working";
  const [label] = [eventLabel(message)];
  const turn = message.params?.turn ?? {};
  const turnId = message.params?.turnId ?? turn.id ?? message.params?.marker ?? context.turnId ?? null;
  const occurredAtMs = message.params?.occurredAt ? Date.parse(message.params.occurredAt) : Number(message.emittedAtMs ?? Date.now());
  const event = {
    sessionId: context.sessionId ?? turnSessionId(threadId, turnId),
    threadId,
    turnId: turnId && turnId !== "unknown" ? turnId : null,
    eventId: stableEventId(message, threadId),
    eventType: message.method,
    title: String(thread.name ?? thread.title ?? `Codex task ${threadId.slice(0, 8)}`).slice(0, 500),
    repo: projectLabel(thread.gitInfo?.originUrl ?? thread.cwd),
    branch: null,
    status: resolvedStatus,
    statusDetail: resolvedStatus === "needs_you" ? "Waiting for your input" : resolvedStatus === "failed" ? "Run failed" : resolvedStatus === "finished" ? "Run finished; assignment outcome not evaluated" : resolvedStatus === "stale" ? "Run interrupted" : "Run in progress; may be waiting for input",
    label,
    detail: turn.status ? `Turn status: ${turn.status}` : message.params?.status?.type ? `Thread status: ${message.params.status.type}` : null,
    tone: eventTone(message),
    startedAt: resolvedStatus === "working" ? new Date(Number.isFinite(occurredAtMs) ? occurredAtMs : Date.now()).toISOString() : null,
    occurredAt: new Date(Number.isFinite(occurredAtMs) ? occurredAtMs : Date.now()).toISOString(),
  };
  if (typeof options.observedAt === "string") event.observedAt = options.observedAt;
  return event;
}

async function sendEvent(event) {
  if (dryRun) {
    console.log(JSON.stringify(event));
    return { accepted: true, dryRun: true };
  }
  if (new URL(siteUrl).protocol !== "https:") throw new Error("Ingestion requires HTTPS");
  const response = await fetch(`${siteUrl}/api/events`, {
    method: "POST",
    redirect: "error",
    headers: { "content-type": "application/json", authorization: `Bearer ${ingestToken}` },
    body: JSON.stringify(event),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`Status Watchr rejected event (${response.status})`);
  return body;
}

async function run() {
  if (!dryRun && !ingestToken) throw new Error("WATCHR_INGEST_TOKEN is required unless --dry-run is used");
  console.error(`Status Watchr connector polling every ${intervalMs >= 60_000 ? `${intervalMs / 60_000}m` : `${intervalMs / 1_000}s`}.`);
  const processHandle = spawn(codexBin, ["app-server", "--listen", "stdio://"], { stdio: ["pipe", "pipe", "inherit"] });
  const input = readline.createInterface({ input: processHandle.stdout });
  let nextRequestId = 1;
  let initialized = false;
  let listRequestId = null;
  const contexts = new Map();

  const send = (message) => processHandle.stdin.write(`${JSON.stringify(message)}\n`);
  const request = (method, params) => {
    const id = nextRequestId++;
    send({ method, id, params });
    return id;
  };
  const finishOnce = () => {
    if (!once) return;
    setTimeout(() => processHandle.kill("SIGTERM"), 50);
  };
  const scheduleNextScan = () => {
    if (!once) setTimeout(() => { listRequestId = request("thread/list", threadListParams()); }, intervalMs);
  };
  const eventDeduper = createEventDeduper();
  const scannedSessionState = createScanStateTracker(Math.max(120_000, intervalMs));
  const sendIfNew = async (event) => {
    if (!event || eventDeduper.has(event.eventId)) return { accepted: false, duplicate: true, skipped: true };
    const response = await sendEvent(event);
    eventDeduper.mark(event.eventId);
    return response;
  };
  const sendScanned = async (event) => {
    if (!event) return { accepted: false, skipped: true };
    if (!scannedSessionState.shouldSend(event)) return { accepted: false, duplicate: true, skipped: true };
    const response = await sendEvent(event);
    scannedSessionState.mark(event);
    return response;
  };

  input.on("line", async (line) => {
    let message;
    try { message = JSON.parse(line); } catch { return; }

    if (message.id === 1 && message.result && !initialized) {
      initialized = true;
      send({ method: "initialized", params: {} });
      listRequestId = request("thread/list", threadListParams());
      return;
    }

    if (message.id === listRequestId && message.result) {
      const threads = message.result.data ?? message.result.threads ?? [];
      for (const thread of threads) {
        const threadId = thread.id;
        if (!threadId) continue;
        const localState = thread.path ? localSessionState(thread.path) : null;
        const status = resolveThreadStatus(thread, localState);
        const context = { threadId, thread, status };
        contexts.set(threadId, context);
        const observedAt = new Date().toISOString();
        if (localState && status === localState.status) {
          const method = localState.status === "working" ? "local/task/started" : localState.status === "finished" ? "local/task/completed" : "local/task/aborted";
          await sendScanned(normalizeNotification({ method, params: { threadId, marker: localState.marker, turnId: localState.marker, occurredAt: localState.occurredAt } }, context, { observedAt }));
        } else if (context.status) {
          await sendScanned(normalizeNotification({ method: "thread/status/changed", params: { threadId, status: thread.status } }, context, { observedAt }));
        }
      }
      console.error(`Status Watchr scanned ${threads.length} local Codex thread(s).`);
      finishOnce();
      scheduleNextScan();
      return;
    }

    if (message.method) {
      const threadId = threadIdFrom(message);
      const context = (threadId && contexts.get(threadId)) ?? { threadId };
      const event = normalizeNotification(message, context);
      if (event) {
        try { await sendIfNew(event); } catch (error) { console.error(error instanceof Error ? error.message : error); }
      }
    }
  });

  send({ method: "initialize", id: 1, params: { clientInfo: { name: "status-watchr", title: "Status Watchr", version: "0.1.0" } } });
  await new Promise((resolve) => processHandle.once("exit", resolve));
}

const isMain = process.argv[1] && import.meta.url === new URL(process.argv[1], "file:").href;
if (isMain) run().catch((error) => { console.error(error instanceof Error ? error.message : error); process.exitCode = 1; });
