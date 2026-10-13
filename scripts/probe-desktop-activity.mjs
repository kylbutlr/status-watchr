// Read-only diagnostic for the installed Desktop App's local turn projection.
// No App Server is started, and no notification, credential, or network API is used.
import { execFileSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    thread: { type: 'string' },
    'codex-home': { type: 'string' },
    'expect-active': { type: 'boolean', default: false },
    'require-completed-history': { type: 'boolean', default: false },
  },
});

try {
  const threadId = values.thread ?? process.env.CODEX_THREAD_ID;
  if (!threadId || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/iu.test(threadId)) {
    throw new Error('A valid conversation UUID is required via --thread or CODEX_THREAD_ID.');
  }
  const codexHome = values['codex-home'] ?? process.env.CODEX_HOME ?? join(homedir(), '.codex');
  const databases = readdirSync(codexHome)
    .map((name) => ({ name, version: /^thread_history_(\d+)\.sqlite$/u.exec(name)?.[1] }))
    .filter((entry) => entry.version !== undefined)
    .sort((a, b) => Number(b.version) - Number(a.version));
  if (!databases.length) throw new Error('No Desktop App turn projection is available.');

  // Only lifecycle columns are selected. Message bodies, titles, tool arguments,
  // outputs, errors, repository paths, and credentials never enter this process.
  const query = `SELECT turn_id, status, started_at, completed_at
    FROM thread_turns WHERE thread_id = '${threadId}'
    ORDER BY COALESCE(started_at, 0) DESC, rollout_ordinal DESC LIMIT 20;`;
  let rows;
  try {
    const output = execFileSync('/usr/bin/sqlite3', [
      '-readonly', '-json', '-cmd', '.timeout 1000', join(codexHome, databases[0].name), query,
    ], { encoding: 'utf8', timeout: 3000, maxBuffer: 65536, stdio: ['ignore', 'pipe', 'pipe'] });
    rows = output.trim() ? JSON.parse(output) : [];
  } catch {
    throw new Error('The turn projection could not be read. No activity state inferred.');
  }
  if (!rows.length) throw new Error('This conversation has no projected turns. No activity state inferred.');
  const current = rows[0];
  const priorCompleted = rows.slice(1).filter((row) => row.status === 'completed');
  const checks = {
    currentRunHasStart: Number.isFinite(current.started_at),
    expectedActive: !values['expect-active'] || (current.status === 'inProgress' && current.completed_at === null),
    completedHistory: !values['require-completed-history'] || priorCompleted.some((row) => Number.isFinite(row.completed_at)),
  };
  const passed = Object.values(checks).every(Boolean);
  console.log(JSON.stringify({
    result: passed ? 'PASS' : 'FAIL',
    source: 'local-turn-projection',
    observedAt: new Date().toISOString(),
    currentRun: current,
    previousCompletedRunsInSample: priorCompleted.length,
    checks,
    attentionState: 'unverified',
    limitation: 'inProgress alone cannot distinguish working, waiting for input, or an abandoned run.',
  }, null, 2));
  if (!passed) process.exitCode = 1;
} catch (error) {
  console.error(JSON.stringify({ result: 'UNAVAILABLE', reason: error.message }));
  process.exitCode = 1;
}
