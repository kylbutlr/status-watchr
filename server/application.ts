import { readFile } from 'node:fs/promises';
import { resolve, sep, extname } from 'node:path';
import type { IncomingMessage, ServerResponse } from 'node:http';

type Options = { origin: string; assets: string; api: (request: Request) => Promise<Response> };
const mime: Record<string, string> = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.webmanifest': 'application/manifest+json' };
export function application({ origin, assets, api }: Options) {
  const root = resolve(assets), canonical = new URL(origin);
  const attempts = new Map<string, { count: number; until: number }>();
  return async (req: IncomingMessage, res: ServerResponse) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    try {
      if (req.headers.host !== canonical.host) { res.writeHead(403); res.end('Use the configured origin.'); return; }
      const url = new URL(req.url || '/', origin);
      if (url.pathname === '/api' || url.pathname.startsWith('/api/')) {
        const method = req.method || 'GET';
        // Native ingestion has its own bearer credential. Browser mutations also
        // require the exact configured origin, including passwordless loopback use.
        const ingest = ['/api/events', '/api/collector'].includes(url.pathname) && method === 'POST';
        if (!['GET', 'HEAD'].includes(method) && !ingest && req.headers.origin !== origin) { res.writeHead(403); res.end('Same-origin request required.'); return; }
        let body: Buffer | undefined;
        if (!['GET', 'HEAD'].includes(method)) {
          const chunks: Buffer[] = []; let size = 0;
          for await (const chunk of req) { size += chunk.length; if (size > 16_384) { res.writeHead(413); res.end('Request too large.'); return; } chunks.push(Buffer.from(chunk)); }
          body = Buffer.concat(chunks);
        }
        const headers = new Headers();
        for (const [name, value] of Object.entries(req.headers)) if (value) headers.set(name, Array.isArray(value) ? value.join(', ') : value);
        const login = url.pathname === '/api/auth/login' && method === 'POST';
        const address = req.socket.remoteAddress || 'local';
        const prior = attempts.get(address);
        if (login && prior && prior.until > Date.now() && prior.count >= 5) { res.writeHead(429, { 'Retry-After': '900' }); res.end('Too many attempts. Try again later.'); return; }
        const result = await api(new Request(url, { method, headers, body: body ? new Uint8Array(body).buffer : undefined }));
        if (login) {
          if (result.ok) attempts.delete(address);
          else attempts.set(address, { count: prior && prior.until > Date.now() ? prior.count + 1 : 1, until: prior && prior.until > Date.now() ? prior.until : Date.now() + 900_000 });
        }
        res.writeHead(result.status, Object.fromEntries(result.headers));
        res.end(result.body ? Buffer.from(await result.arrayBuffer()) : undefined); return;
      }
      if (!['GET', 'HEAD'].includes(req.method || 'GET')) { res.writeHead(405); res.end(); return; }
      const pathname = decodeURIComponent(url.pathname);
      const path = resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
      if (!path.startsWith(root + sep) || pathname.split('/').some((part) => part.startsWith('.'))) { res.writeHead(404); res.end(); return; }
      if (path.endsWith('.mjs') || path.endsWith('.map')) { res.writeHead(404); res.end(); return; }
      const content = await readFile(path);
      res.writeHead(200, { 'Content-Type': mime[extname(path)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
      res.end(req.method === 'HEAD' ? undefined : content);
    } catch (error) {
      if (!res.headersSent) res.writeHead((error as NodeJS.ErrnoException).code === 'ENOENT' ? 404 : 503);
      res.end('The local service is unavailable. Check its configuration and retry.');
    }
  };
}
