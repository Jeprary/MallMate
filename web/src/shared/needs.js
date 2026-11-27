// Free-form conversation memory; no predefined preference categories.
(function(root){
 'use strict';
 function clean(value){
  if(value==null)return null;
  if(typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!['stated','tentative'].includes(k)))throw Error('Invalid needs');
  const result={};for(const key of ['stated','tentative']){
   const list=value[key]??[];
   if(!Array.isArray(list)||list.length>60||list.some(x=>typeof x!=='string'||!x.trim()||x.length>500))throw Error('Invalid need text');
   result[key]=[...new Set(list)];
  }return result;
 }
 function resolve(value,input){
  const previous=clean(input.needs)||{stated:[],tentative:[]};if(value==null)return previous;
  const result=clean(value),sources=[input.text||'',...(input.history||[]).filter(x=>x.role==='user').map(x=>x.text||'')];
  for(const quote of result.stated)if(!previous.stated.includes(quote)&&!sources.some(text=>text.includes(quote)))throw Error('Stated needs must quote the user; keep guesses tentative');
  return result;
 }
 const api={clean,resolve};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateNeeds=api;
})(typeof window!=='undefined'?window:globalThis);
