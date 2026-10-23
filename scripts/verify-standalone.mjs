import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createConnection} from 'node:net';

const port=4288,origin=`http://127.0.0.1:${port}`;
await new Promise((resolve,reject)=>{const probe=createConnection({host:'127.0.0.1',port});probe.once('connect',()=>{probe.destroy();reject(Error('Port 4288 is occupied. Do not start a duplicate server.'));});probe.once('error',error=>error.code==='ECONNREFUSED'?resolve():reject(error));});
const data=await mkdtemp(join(tmpdir(),'watchr-standalone-'));
let child;
const env={...process.env,WATCHR_LOAD_ENV:'false',WATCHR_AUTH_MODE:'none',WATCHR_ACCESS_PASSWORD:'',WATCHR_PORT:String(port),WATCHR_ORIGIN:origin,WATCHR_DATA_DIR:data,WATCHR_INGEST_TOKEN:'',WATCHR_SESSION_SECRET:'',WATCHR_VAPID_PUBLIC_KEY:'',WATCHR_VAPID_PRIVATE_KEY:'',WATCHR_VAPID_SUBJECT:'',APP_SWITCHR_URL:'',APP_SWITCHR_READER_TOKEN:'',DATABASE_URL:''};
async function start(extra={}){
 child=spawn(process.execPath,['dist/server.mjs'],{env:{...env,...extra},stdio:['ignore','pipe','pipe']});
 console.log(JSON.stringify({pid:child.pid,repository:process.cwd(),command:'node dist/server.mjs (disposable data)',port}));
 let errors='';child.stderr.on('data',chunk=>{errors+=chunk;});
 await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Server did not start: '+errors)),20_000);child.once('error',reject);child.once('exit',code=>{clearTimeout(timer);reject(Error('Server exited: '+code+' '+errors));});child.stdout.on('data',chunk=>{if(String(chunk).includes('Status Watchr:')){clearTimeout(timer);resolve();}});});
}
async function stop(){if(!child||child.exitCode!==null||child.signalCode!==null)return;child.kill('SIGTERM');await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{child.kill('SIGKILL');reject(Error('Server required forced stop.'));},10_000);child.once('exit',()=>{clearTimeout(timer);resolve();});});}
const request=(path,method='GET',body,headers={})=>fetch(origin+path,{signal:AbortSignal.timeout(15_000),method,headers:{'Content-Type':'application/json',...headers},body:body===undefined?undefined:JSON.stringify(body)});
try{
 await start();
 const health=await (await request('/api/auth/session')).json();assert.equal(health.authenticated,true);assert.equal(health.authenticationMode,'none');
 assert.equal((await request('/api/sessions')).status,200);
 assert.equal((await request('/')).status,200);
 assert.equal((await request('/server.mjs')).status,404);
 assert.equal((await request('/api/notifications/watch','PUT',{threadId:'fictional',enabled:true},{Origin:'https://other.example'})).status,403);
 assert.equal((await request('/api/events','POST',{})).status,401);
 const {ingestToken}=JSON.parse(await readFile(join(data,'server-secrets.json'),'utf8'));
 const event={sessionId:'fictional-thread:fictional-run',threadId:'fictional-thread',turnId:'fictional-run',eventId:'fictional-start',eventType:'local/task/started',title:'Fictional release review',status:'working',occurredAt:new Date().toISOString()};
 assert.equal((await request('/api/events','POST',event,{Authorization:`Bearer ${ingestToken}`})).status,202);
 await stop();await start();
 const persisted=await (await request('/api/sessions')).json();assert.match(JSON.stringify(persisted),/Fictional release review/);
 await stop();
 await start({WATCHR_AUTH_MODE:'password',WATCHR_ACCESS_PASSWORD:'fictional-test-password'});
 assert.equal((await (await request('/api/auth/session')).json()).authenticated,false);
 assert.equal((await request('/api/sessions')).status,401);
 const login=await request('/api/auth/login','POST',{password:'fictional-test-password'},{Origin:origin});assert.equal(login.status,200);
 const cookie=login.headers.get('set-cookie');assert.ok(cookie);assert.ok(!cookie.includes('; Secure'));
 assert.equal((await request('/api/sessions','GET',undefined,{Cookie:cookie.split(';')[0]})).status,200);
 console.log('PASS: passwordless access, origin checks, native ingest credential, persisted restart, local password login, and static source exclusion.');
}finally{await stop();await rm(data,{recursive:true,force:true});}
await new Promise((resolve,reject)=>{const probe=createConnection({host:'127.0.0.1',port});probe.once('connect',()=>{probe.destroy();reject(Error('Test port remained open.'));});probe.once('error',error=>error.code==='ECONNREFUSED'?resolve():reject(error));});
console.log('Cleanup verified: child exited, disposable data removed, port 4288 closed.');
