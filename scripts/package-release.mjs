import {mkdtemp, mkdir, readFile, readdir, lstat, cp, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';

const root=process.cwd(), manifest=JSON.parse(await readFile('package.json','utf8'));
if(manifest.name!=='status-watchr'||manifest.version!=='1.0.0')throw Error('Review the public release version before packaging.');
const temp=await mkdtemp(join(tmpdir(),'watchr-release-')), output=resolve('releases');
const publicFiles=['sw.js','favicon.svg','favicon-working.svg','favicon-finished.svg','favicon-attention.svg','favicon.png','apple-touch-icon.png','manifest.webmanifest','icons','fonts'];
const sourceFiles=['README.md','LICENSE','SECURITY.md','CONTRIBUTING.md','CHANGELOG.md','.env.example','package.json','package-lock.json','app-stylr.json','index.html','vite.config.ts','tsconfig.json','tsconfig.app.json','tsconfig.node.json','src','server','netlify/functions','netlify.toml','database/migrations','collector','apps/macos/Package.swift','apps/macos/Package.resolved','apps/macos/Sources','apps/macos/Tests','apps/macos/Resources/Info.plist','apps/macos/Resources/StatusWatchr.icns','docs/self-hosting.md','docs/privacy.md','docs/app-stylr-exceptions.md','apps/macos/README.md','scripts/build-server.mjs','scripts/package-release.mjs','scripts/verify-standalone.mjs'];
async function copy(source,target){const entry=await lstat(source);if(entry.isSymbolicLink())throw Error('Release input is a symlink: '+source);if(entry.isDirectory()){await mkdir(target,{recursive:true});for(const file of await readdir(source))await copy(join(source,file),join(target,file));}else{await mkdir(resolve(target,'..'),{recursive:true});await cp(source,target);}}
const checksums=[];
async function archive(name,stage){const file=join(output,name+'.tar.gz');execFileSync('tar',['-czf',file,'-C',temp,name],{env:{...process.env,COPYFILE_DISABLE:'1'}});const contents=execFileSync('tar',['-tzf',file],{encoding:'utf8'});if(contents.split('\n').some(path=>/(^|\/)\.env$|\/data\/|\/node_modules\/|\/public\/updates\/|\/dist\/updates\/|\/docs\/screenshots\/|\/\.git\//.test(path)))throw Error('Unexpected private/runtime files in '+name);await writeFile(join(output,name+'-CONTENTS.txt'),contents);checksums.push(createHash('sha256').update(await readFile(file)).digest('hex')+'  '+name+'.tar.gz');}
try{
 await mkdir(output,{recursive:true});
 const sourceName=`status-watchr-source-${manifest.version}`, source=join(temp,sourceName);
 for(const file of sourceFiles)await copy(join(root,file),join(source,file));
 for(const file of publicFiles)await copy(join(root,'public',file),join(source,'public',file));
 // The public source does not ship the private pilot's signing workflow or its
 // release-channel tests. Application, native, persistence and auth tests remain.
 for(const file of await readdir(join(root,'tests')))if(!['sparkle.test.ts','release-version.test.mjs'].includes(file))await copy(join(root,'tests',file),join(source,'tests',file));
 await writeFile(join(source,'.gitignore'),'node_modules/\ndata/\ndist/\nbuild/\n.env\n.env.*\n!.env.example\nreleases/\noutputs/\napps/macos/.build/\napps/macos/.swiftpm/\n');
 await writeFile(join(source,'AGENTS.md'),'# Status Watchr\n\nRead README.md before changing the app. Preserve App Stylr semantic roles, local storage, explicit password modes, ingestion authentication, origin checks, notification opt-in, completion confirmation, and source-unavailable states. Never start real monitoring, change hooks, send phone notifications, deploy, or publish without explicit approval. Run typecheck, tests, and the standalone build with disposable data.\n');
 await archive(sourceName,source);
 const serverName=`status-watchr-server-${manifest.version}`, server=join(temp,serverName);
 for(const file of ['README.md','LICENSE','SECURITY.md','.env.example','package.json','package-lock.json','docs/self-hosting.md','docs/privacy.md','database/migrations'])await copy(join(root,file),join(server,file));
 // Copy only compiled browser/runtime assets. Historical update archives never
 // enter the standalone download, even when present in the private build tree.
 for(const file of await readdir(join(root,'dist')))if(file!=='updates')await copy(join(root,'dist',file),join(server,'dist',file));
 await archive(serverName,server);
 await writeFile(join(output,'SHA256SUMS'),checksums.join('\n')+'\n');
 console.log('Packaged standalone server, clean source, manifests and SHA-256 checksums.');
}finally{await rm(temp,{recursive:true,force:true});}
