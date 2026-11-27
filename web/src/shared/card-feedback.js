// A temporary, addressed card operation. It is not a permanent food preference.
(function(root){
 'use strict';
 function clean(value,currentStoreIds=[]){
  if(value==null)return null;
  if(typeof value!=='object'||Array.isArray(value)||value.action!=='replace_store'||typeof value.storeId!=='string'||!/^[A-Za-z0-9_-]{1,200}$/.test(value.storeId)||!currentStoreIds.includes(value.storeId))throw Error('Invalid card feedback target');
  return {action:'replace_store',storeId:value.storeId};
 }
 function scope(raw,input){
  if(!input.cardFeedback){if(raw.updateScope!==undefined&&raw.updateScope!=='all')throw Error('Card update needs a feedback target');return 'all';}
  const value=raw.updateScope??'card';
  if(!['card','all','keep'].includes(value)||input.source==='card'&&value!=='card')throw Error('Invalid card update scope');
  return value;
 }
 function decision(raw,input,value){
  const output={...raw};
  if(input.cardFeedback&&(input.source==='card'||value==='keep')){
   output.context={...input.context};output.intent=input.intent||raw.intent;output.excludedTerms=[...(input.excludedTerms||[])];
   for(const flag of ['budgetSpecified','timeSpecified','quietRequired'])output[flag]=!!input[flag];
   output.requirements={};
   const needs=typeof module!=='undefined'&&module.exports?require('./needs'):root.MallMateNeeds;
   output.needs=needs?.resolve(undefined,input)||{stated:[],tentative:[]};
  }
  if(raw.action!=='recommend')return output;
  if(!Object.hasOwn(raw,'question'))output.question=null;
  if(value==='card'&&Array.isArray(raw.selections)&&raw.selections.length){
   const replacements=raw.selections.filter(s=>!input.currentStoreIds.includes(s?.storeId));
   if(!replacements.length)throw Error('Provide a new replacement, not an already displayed store');
   // Some models return the resulting three-card set. Only the addressed new
   // candidate is a recommendation; the client retains its original other cards.
   output.selections=replacements;
  }
  return output;
 }
 function validate(result,input,value){
  if((input.cardFeedback&&input.source==='card')||value==='keep'){
   const sameList=(a,b)=>JSON.stringify([...new Set(a||[])].sort())===JSON.stringify([...new Set(b||[])].sort());
   if(!sameList(result.excludedTerms,input.excludedTerms)||['budgetSpecified','timeSpecified','quietRequired'].some(k=>result[k]!==!!input[k])||['category','min','max','time','quiet','origin'].some(k=>result.context[k]!==input.context[k]))throw Error('Card-only feedback must preserve existing preferences and constraints');
   if(input.intent&&(result.intent?.kind!==input.intent.kind||result.intent?.topic!==input.intent.topic))throw Error('Card-only feedback must preserve the overall intent');
   const requirements=typeof module!=='undefined'&&module.exports?require('./requirements'):root.MallMateRequirements;
   if(requirements&&result.requirements&&!requirements.equal(result.requirements,requirements.previous(input)))throw Error('Card-only feedback must preserve interpreted requirements');
   const needs=typeof module!=='undefined'&&module.exports?require('./needs'):root.MallMateNeeds;
   if(needs&&result.needs){
    const ordered=value=>{const n=needs.clean(value)||{stated:[],tentative:[]};return JSON.stringify({stated:[...n.stated].sort(),tentative:[...n.tentative].sort()});};
    if(ordered(result.needs)!==ordered(input.needs))throw Error('Card-only feedback must preserve the user need memory');
   }
  }
  if(value==='keep'){if(result.action!=='recommend'||result.selections.length)throw Error('Cancelled replacement must keep the current cards');return;}
  if(value!=='card')return;
  if(result.selections.length>1)throw Error('Return at most one replacement for the addressed card');
  if(result.selections.some(s=>input.currentStoreIds.includes(s.storeId)))throw Error('Replacement must differ from every displayed card');
 }
 function update(result,input,value){
  if(!input.cardFeedback)return null;
  if(value==='keep')return {action:'keep_current'};
  if(value==='all')return {action:'clear_pending'};
  return {action:'replace_store',storeId:input.cardFeedback.storeId,status:result.action==='ask'?'awaiting_answer':result.selections.length?'applied':'no_alternative'};
 }
 function apply(current,result){
  const change=result.cardUpdate;
  if(!change)return {selections:result.selections,pending:null,changed:true};
  if(change.action==='keep_current'||change.action==='clear_pending'&&(result.action==='ask'||!result.selections.length))return {selections:current,pending:null,changed:false};
  if(change.action==='clear_pending')return {selections:result.selections,pending:null,changed:true};
  const index=current.findIndex(s=>s.storeId===change.storeId);
  if(index<0)throw Error('Card feedback target is no longer displayed');
  if(change.action!=='replace_store')throw Error('Invalid card update');
  if(change.status==='awaiting_answer')return {selections:current,pending:{action:'replace_store',storeId:change.storeId},changed:false};
  if(change.status==='no_alternative')return {selections:current,pending:null,changed:false};
  if(change.status!=='applied'||result.action!=='recommend'||result.selections.length!==1||current.some(s=>s.storeId===result.selections[0].storeId))throw Error('Invalid replacement result');
  const selections=current.slice();selections[index]=result.selections[0];return {selections,pending:null,changed:true};
 }
 const api={clean,scope,decision,validate,update,apply};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateCardFeedback=api;
})(typeof window!=='undefined'?window:globalThis);
