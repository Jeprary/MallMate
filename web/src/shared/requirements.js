// Model-interpreted constraints. Walking and total visit duration remain independent.
(function(root){
 'use strict';
 const keys=['budget','quiet','time'],scopes=['walk','visit'],object=x=>x&&typeof x==='object'&&!Array.isArray(x);
 function entry(key,value,updates=false){
  if(!object(value)||!['soft','hard',...(updates?['none']:[])].includes(value.mode))throw Error('Invalid requirement mode');
  const allowed=key==='budget'?['mode','min','max','quote']:key==='time'?['mode','minutes','quote']:['mode','quote'];
  if(Object.keys(value).some(k=>!allowed.includes(k)))throw Error('Invalid requirement fields');
  const quote=value.quote??null;if(quote!==null&&(typeof quote!=='string'||!quote.trim()||quote.length>200))throw Error('Invalid requirement quote');
  if(value.mode==='none')return {mode:'none',quote};
  if(key==='budget'){
   if(!Number.isFinite(value.min)||!Number.isFinite(value.max)||value.min<0||value.max<value.min||value.max>10000)throw Error('Invalid requirement budget');
   return {mode:value.mode,min:value.min,max:value.max,quote};
  }
  if(key==='time'){
   if(!Number.isFinite(value.minutes)||value.minutes<1||value.minutes>240)throw Error('Invalid requirement time');
   return {mode:value.mode,minutes:value.minutes,quote};
  }
  return {mode:value.mode,quote};
 }
 function times(value,updates=false){
  if(!object(value))throw Error('Invalid time requirements');
  // Accept the previous single-scope wire format, without replacing another saved scope.
  if(Object.hasOwn(value,'kind')){
   if(!scopes.includes(value.kind))throw Error('Invalid requirement time kind');
   const {kind,...rest}=value;return {[kind]:entry('time',rest,updates)};
  }
  if(Object.keys(value).some(k=>!scopes.includes(k)))throw Error('Invalid time requirement scopes');
  const result={};for(const kind of scopes)if(Object.hasOwn(value,kind))result[kind]=entry('time',value[kind],updates);return result;
 }
 function clean(value){
  if(value==null)return null;
  if(!object(value)||Object.keys(value).some(k=>!keys.includes(k)))throw Error('Invalid requirements');
  const result={};for(const key of keys)if(Object.hasOwn(value,key)){
   const next=key==='time'?times(value[key]):entry(key,value[key]);
   if(key!=='time'||Object.keys(next).length)result[key]=next;
  }return result;
 }
 function previous(input){
  const saved=clean(input.requirements);if(saved)return saved;
  const c=input.context||{},result={};
  if(input.budgetSpecified)result.budget={mode:'hard',min:c.min,max:c.max,quote:null};
  if(input.quietRequired)result.quiet={mode:'hard',quote:null};
  if(input.timeSpecified)result.time={visit:{mode:'hard',minutes:c.time,quote:null}};
  return result;
 }
 const equal=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
 function apply(next,old,text){
  if(equal(next,old))return old;
  if(!next.quote||!String(text||'').includes(next.quote))throw Error('Changed requirements need an exact quote from this user message');
  return next.mode==='none'?undefined:next;
 }
 function resolve(raw,input){
  if(raw.requirements==null&&input.requirements==null)return null;
  const patch=raw.requirements??{};if(!object(patch)||Object.keys(patch).some(k=>!keys.includes(k)))throw Error('Invalid requirement updates');
  const result={...previous(input)};
  for(const key of keys)if(Object.hasOwn(patch,key)){
   if(key==='time'){
    const saved={...result.time},updates=times(patch.time,true);
    for(const kind of scopes)if(Object.hasOwn(updates,kind)){
     const next=apply(updates[kind],saved[kind],input.text);if(next===undefined)delete saved[kind];else saved[kind]=next;
    }
    if(Object.keys(saved).length)result.time=saved;else delete result.time;
   }else{
    const next=apply(entry(key,patch[key],true),result[key],input.text);if(next===undefined)delete result[key];else result[key]=next;
   }
  }
  return clean(result);
 }
 function flags(requirements){return {budgetSpecified:requirements.budget?.mode==='hard',quietRequired:requirements.quiet?.mode==='hard',timeSpecified:Object.values(requirements.time||{}).some(t=>t.mode==='hard')};}
 const api={clean,previous,resolve,flags,equal};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateRequirements=api;
})(typeof window!=='undefined'?window:globalThis);
