// Read-only hook readiness check. Does not execute, trust, or modify any hook.
import { spawn } from 'node:child_process';

const child = spawn(process.env.CODEX_BIN ?? 'codex', ['app-server', '--listen', 'stdio://'], {
  stdio: ['pipe', 'pipe', 'pipe'],
});
let buffer = '';
let done = false;
const timer = setTimeout(() => finish({ result: 'UNAVAILABLE', reason: 'Hook inventory timed out.' }, 1), 15_000);

function finish(result, code) {
  if (done) return;
  done = true;
  clearTimeout(timer);
  console.log(JSON.stringify(result, null, 2));
  process.exitCode = code;
  child.stdin.end();
  child.kill();
}

function send(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

child.stderr.resume(); // Do not emit raw diagnostics or potentially sensitive configuration.
child.stdin.on('error', () => finish({ result: 'UNAVAILABLE', reason: 'App Server input unavailable.' }, 1));
child.on('error', () => finish({ result: 'UNAVAILABLE', reason: 'App Server could not be started.' }, 1));
child.on('exit', () => {
  if (!done) finish({ result: 'UNAVAILABLE', reason: 'App Server exited before reporting hook readiness.' }, 1);
});
child.stdout.on('data', (data) => {
  buffer += data.toString();
  let newline;
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    let message;
    try { message = JSON.parse(line); } catch { continue; }
    if (![1, 2].includes(message.id)) continue;
    if (message.error) {
      finish({ result: 'UNAVAILABLE', reason: 'Read-only protocol request failed.', code: message.error.code }, 1);
      return;
    }
    if (message.id === 1) {
      send({ method: 'initialized', params: {} });
      send({ id: 2, method: 'hooks/list', params: {} });
      continue;
    }
    const groups = message.result?.data;
    if (!Array.isArray(groups)) {
      finish({ result: 'UNAVAILABLE', reason: 'Unrecognized hook inventory format.' }, 1);
      return;
    }
    const expectedCommand = "/usr/bin/curl --silent --max-time 1 --output /dev/null --header 'Content-Type: application/json' --data-binary @- http://127.0.0.1:48731/codex-hook";
    const expectedEvents = ['userPromptSubmit', 'permissionRequest', 'postToolUse', 'stop', 'interrupt', 'subagentStart', 'subagentStop'];
    const hooks = groups.flatMap((group) => Array.isArray(group.hooks) ? group.hooks : [])
      .filter((hook) => typeof hook.command === 'string' && hook.command.includes('127.0.0.1:48731/codex-hook'))
      .map((hook) => ({ event: hook.eventName, enabled: hook.enabled === true, trust: hook.trustStatus, currentDefinition: hook.command === expectedCommand }));
    const ready = expectedEvents.every((event) => hooks.some((hook) => hook.event === event && hook.enabled && hook.trust === 'trusted' && hook.currentDefinition));
    finish({
      result: ready ? 'PASS' : 'FAIL',
      check: 'Status Watchr hook enablement and trust',
      hooks,
      limitation: 'A passing inventory check does not prove live Desktop App hook execution or event delivery.',
    }, ready ? 0 : 1);
    return;
  }
});

send({
  id: 1,
  method: 'initialize',
  params: { clientInfo: { name: 'status_watchr_hook_diagnostic', version: '0.0.1' }, capabilities: {} },
});
