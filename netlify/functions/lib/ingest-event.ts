const states = new Set(["working", "needs_you", "finished", "failed", "stale"]);
const allowed = new Set(["sessionId", "threadId", "parentThreadId", "turnId", "attentionId", "eventId", "eventType", "title", "repo", "branch", "status", "statusDetail", "label", "detail", "tone", "occurredAt", "observedAt", "startedAt", "finishedAt", "replyPreview", "notificationEligible", "excludedThreadIds", "threadTitles", "threadRelationships"]);
const labels: Record<string, string> = { working: "Run in progress", needs_you: "Attention requested", finished: "Run finished", failed: "Run failed", stale: "Observation interrupted" };

export function normalizedIngestEvent(input: Record<string, unknown>, now = Date.now()) {
  if (Object.keys(input).some((key) => !allowed.has(key))) throw new Error("Unexpected event field");
  const result: Record<string, unknown> = {};
  for (const key of ["sessionId", "threadId", "turnId", "attentionId", "eventId", "eventType"]) {
    const value = input[key];
    if (value == null && !["sessionId", "eventId", "eventType"].includes(key)) { result[key] = null; continue; }
    if (typeof value !== "string" || !/^[A-Za-z0-9_:/.-]{1,250}$/.test(value)) throw new Error("Invalid identity");
    result[key] = value;
  }
  if (typeof input.title !== "string" || !input.title.trim() || input.title.length > 500) throw new Error("Invalid title");
  result.title = input.title.trim();
  if (!states.has(String(input.status))) throw new Error("Invalid status");
  result.status = input.status;
  if (String(input.eventType).startsWith('local/question/')) {
    if (!['local/question/opened', 'local/question/answered'].includes(String(input.eventType)) || input.status !== 'working' ||
        typeof input.threadId !== 'string' || !input.threadId || typeof input.turnId !== 'string' || !input.turnId ||
        typeof input.attentionId !== 'string' || !/^call_[A-Za-z0-9_-]{1,180}:(?:[0-9]|[1-5][0-9]|6[0-3])$/.test(input.attentionId) ||
        typeof input.occurredAt !== 'string' || !Number.isFinite(Date.parse(input.occurredAt)) ||
        input.replyPreview !== undefined || input.parentThreadId !== undefined || input.threadTitles !== undefined ||
        input.threadRelationships !== undefined || input.excludedThreadIds !== undefined) throw new Error('Invalid question event');
  }
  if (input.parentThreadId !== undefined) {
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (String(input.eventType).startsWith('local/threads/') || typeof input.parentThreadId !== 'string' || !uuid.test(input.parentThreadId) || typeof input.threadId !== 'string' || !uuid.test(input.threadId) || input.threadId.toLowerCase() === input.parentThreadId.toLowerCase()) throw new Error('Invalid parent identity');
    result.parentThreadId = input.parentThreadId.toLowerCase();
  }
  if (input.eventType === 'local/threads/relationships') {
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (input.status !== 'stale' || input.threadId != null || input.turnId != null || input.attentionId != null || input.replyPreview !== undefined || input.excludedThreadIds !== undefined || input.threadTitles !== undefined ||
        !Array.isArray(input.threadRelationships) || input.threadRelationships.length < 1 || input.threadRelationships.length > 100 || input.threadRelationships.some(row =>
          !row || typeof row !== 'object' || Array.isArray(row) || Object.keys(row).some(key => !['threadId', 'parentThreadId'].includes(key)) ||
          typeof row.threadId !== 'string' || !uuid.test(row.threadId) || typeof row.parentThreadId !== 'string' || !uuid.test(row.parentThreadId) || row.threadId.toLowerCase() === row.parentThreadId.toLowerCase())) throw new Error('Invalid thread relationships');
    result.threadRelationships = input.threadRelationships.map(row => ({ threadId: row.threadId.toLowerCase(), parentThreadId: row.parentThreadId.toLowerCase() }));
    if (new Set((result.threadRelationships as {threadId: string}[]).map(row => row.threadId)).size !== input.threadRelationships.length) throw new Error('Duplicate thread relationship');
  } else if (input.threadRelationships !== undefined) { throw new Error('Unexpected thread relationships'); }
  if (input.eventType === 'local/threads/titles') {
    if (input.status !== 'stale' || input.threadId != null || input.turnId != null || input.attentionId != null || input.replyPreview !== undefined || input.excludedThreadIds !== undefined ||
        !Array.isArray(input.threadTitles) || input.threadTitles.length < 1 || input.threadTitles.length > 100 || input.threadTitles.some(row =>
          !row || typeof row !== 'object' || Array.isArray(row) || Object.keys(row).some(key => !['threadId', 'title'].includes(key)) ||
          typeof row.threadId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(row.threadId) ||
          typeof row.title !== 'string' || !row.title.trim() || row.title.length > 500 || row.title.trim() === 'Untitled task')) throw new Error('Invalid thread titles');
    result.threadTitles = input.threadTitles.map(row => ({ threadId: row.threadId.toLowerCase(), title: row.title.trim() }));
  } else if (input.threadTitles !== undefined) { throw new Error('Unexpected thread titles'); }
  if (input.eventType === "local/threads/excluded") {
    if (input.status !== "stale" || input.threadId != null || input.turnId != null || input.replyPreview !== undefined || input.attentionId != null ||
        !Array.isArray(input.excludedThreadIds) || input.excludedThreadIds.length < 1 || input.excludedThreadIds.length > 100 ||
        input.excludedThreadIds.some(id => typeof id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))) throw new Error("Invalid thread exclusions");
    result.excludedThreadIds = [...new Set(input.excludedThreadIds.map(id => String(id).toLowerCase()))];
  } else if (input.excludedThreadIds !== undefined) {
    throw new Error("Unexpected thread exclusions");
  }
  if (input.notificationEligible !== undefined) {
    if (typeof input.notificationEligible !== "boolean") throw new Error("Invalid notification eligibility");
    result.notificationEligible = input.notificationEligible;
  }
  result.label = labels[String(input.status)];
  result.statusDetail = input.status === "finished" ? "Run finished; assignment outcome not evaluated" : input.status === "working" ? "May be waiting for input" : result.label;
  result.detail = null;
  if (input.replyPreview !== undefined) {
    if (input.status !== "finished" || typeof input.replyPreview !== "string") throw new Error("Invalid reply preview");
    const preview = input.replyPreview.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\s+/g, " ").trim();
    if (!preview || preview.length > 200) throw new Error("Invalid reply preview");
    result.replyPreview = preview;
  }
  result.tone = ({ working: "working", needs_you: "attention", finished: "success", failed: "danger", stale: "quiet" } as Record<string, string>)[String(input.status)];
  let project = typeof input.repo === "string" ? input.repo : "";
  if (project.includes("://")) { try { project = new URL(project).pathname; } catch { project = ""; } }
  result.repo = project.split(/[?#]/)[0].split("/").filter(Boolean).pop()?.replace(/\.git$/, "").slice(0, 120) ?? null;
  result.branch = null;
  for (const key of ["occurredAt", "observedAt", "startedAt", "finishedAt"]) {
    const value = input[key];
    if (value == null) { result[key] = null; continue; }
    const time = typeof value === "string" ? Date.parse(value) : NaN;
    if (!Number.isFinite(time) || time > now + 60_000) throw new Error("Invalid timestamp");
    result[key] = new Date(time).toISOString();
  }
  return result;
}
