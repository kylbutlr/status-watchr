export type DashboardPreferences = {workspaceName: string; displayName: string; theme: 'dark'|'light'; density: 'comfortable'|'compact'; defaultFilter: 'all'|'working'|'needs_you'|'finished'|'failed'|'stale'};
export const preferenceKey = 'statusWatchr.preferences.v1';
export const preferenceDefaults: DashboardPreferences = {workspaceName:'Your activity',displayName:'',theme:'dark',density:'comfortable',defaultFilter:'all'};
const label=(value:unknown,fallback:string,max:number)=>typeof value==='string'?value.replace(/[\u0000-\u001f\u007f]/g,'').trim().slice(0,max)||fallback:fallback;
export function normalizePreferences(value:unknown):DashboardPreferences {
 const row=value&&typeof value==='object'&&!Array.isArray(value)?value as Record<string,unknown>:{};
 return {workspaceName:label(row.workspaceName,preferenceDefaults.workspaceName,64),displayName:label(row.displayName,'',48),theme:row.theme==='light'?'light':'dark',density:row.density==='compact'?'compact':'comfortable',defaultFilter:['all','working','needs_you','finished','failed','stale'].includes(String(row.defaultFilter))?row.defaultFilter as DashboardPreferences['defaultFilter']:'all'};
}
export function readPreferences(storage?:Pick<Storage,'getItem'>):DashboardPreferences {try{return normalizePreferences(JSON.parse(storage?.getItem(preferenceKey)||'{}'));}catch{return {...preferenceDefaults};}}
export function savePreferences(storage:Pick<Storage,'setItem'>|undefined,value:DashboardPreferences):boolean {try{if(!storage)return false;storage.setItem(preferenceKey,JSON.stringify(normalizePreferences(value)));return true;}catch{return false;}}
