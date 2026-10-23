import {useState} from 'react';
import {normalizePreferences,preferenceDefaults,type DashboardPreferences as Preferences} from './dashboard-preferences';
export function DashboardPreferences({value,onSave}:{value:Preferences;onSave:(value:Preferences)=>boolean}) {
 const [message,setMessage]=useState('');
 return <details className="dashboard-preferences"><summary>Workspace preferences</summary>
  <p>Personalize this browser. Display labels do not change server access, watched conversations, or notification permissions.</p>
  <form key={JSON.stringify(value)} onSubmit={event=>{event.preventDefault();const form=new FormData(event.currentTarget);const saved=onSave(normalizePreferences(Object.fromEntries(form)));setMessage(saved?'Saved for this browser. The default view applies next time you open the app.':'Applied for this visit. Browser storage is unavailable.');}}>
   <label>Workspace name<input name="workspaceName" defaultValue={value.workspaceName} required maxLength={64}/></label>
   <label>Your display name<input name="displayName" defaultValue={value.displayName} maxLength={48} autoComplete="nickname" placeholder="Optional"/></label>
   <label>Appearance<select name="theme" defaultValue={value.theme}><option value="dark">Dark</option><option value="light">Light</option></select></label>
   <label>Spacing<select name="density" defaultValue={value.density}><option value="comfortable">Comfortable</option><option value="compact">Compact</option></select></label>
   <label>Default view<select name="defaultFilter" defaultValue={value.defaultFilter}><option value="all">All activity</option><option value="working">In progress</option><option value="needs_you">Needs attention</option><option value="finished">Finished</option><option value="failed">Failed</option><option value="stale">Stale</option></select></label>
   <div className="preference-actions"><button className="primary-button" type="submit">Save preferences</button><button type="button" className="text-button" onClick={()=>{const saved=onSave({...preferenceDefaults});setMessage(saved?'Default preferences restored.':'Defaults applied for this visit. Browser storage is unavailable.');}}>Reset defaults</button></div>
  </form><p role="status" aria-live="polite">{message}</p></details>;
}
