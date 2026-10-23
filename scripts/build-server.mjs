import { build } from 'esbuild';
await build({ entryPoints: ['server/start.ts'], outfile: 'dist/server.mjs', bundle: true, platform: 'node', target: 'node24', format: 'esm', packages: 'external' });
