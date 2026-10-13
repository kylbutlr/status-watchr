import type { AgentSession } from './domain';

const key = (session: AgentSession) => session.threadId ?? session.id;

// Runs can replace the representative ID without creating another conversation.
export function mergeSessionPage(current: AgentSession[], incoming: AgentSession[]) {
  const merged = new Map(current.map(session => [key(session), session]));
  for (const session of incoming) merged.set(key(session), session);
  return [...merged.values()];
}

export function refreshSessionPage(current: AgentSession[], firstPage: AgentSession[]) {
  const firstPageKeys = new Set(firstPage.map(key));
  return [...firstPage, ...current.filter(session => !firstPageKeys.has(key(session)))];
}
