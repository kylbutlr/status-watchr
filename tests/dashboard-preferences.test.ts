import {describe,it,expect} from 'vitest';
import {normalizePreferences,readPreferences,savePreferences,preferenceKey} from '../src/dashboard-preferences';
describe('public dashboard preferences',()=>{
 it('persists only normalized personal display preferences',()=>{
  const rows=new Map<string,string>();const storage={getItem:(key:string)=>rows.get(key)??null,setItem:(key:string,value:string)=>{rows.set(key,value);}};
  const value=normalizePreferences({workspaceName:'  Fieldnotes  ',displayName:'Alex',theme:'light',density:'compact',defaultFilter:'failed',token:'not-a-preference'});
  expect(savePreferences(storage,value)).toBe(true);expect(readPreferences(storage)).toEqual(value);expect(value.workspaceName).toBe('Fieldnotes');expect(rows.get(preferenceKey)).not.toContain('token');
  expect(normalizePreferences({defaultFilter:'admin',theme:'red',workspaceName:'\n'}).defaultFilter).toBe('all');
 });
 it('works with malformed or unavailable storage',()=>{
  expect(readPreferences({getItem:()=>'{broken'}).theme).toBe('dark');
  expect(readPreferences({getItem:()=>{throw Error('denied');}}).density).toBe('comfortable');
  expect(savePreferences({setItem:()=>{throw Error('denied');}},normalizePreferences({}))).toBe(false);
 });
});
