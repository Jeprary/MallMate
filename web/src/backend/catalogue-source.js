// Backend catalogue source. Snapshot mode is explicit in response metadata.
'use strict';
const fs=require('node:fs'),path=require('node:path'),Supplement=require('./catalogue-supplement');
function create({liveRead,snapshotPath,supplementPath,consumptionReferencePath,localContent=true,mode='snapshot',now=Date.now,ttlMs=60000}){
 if(!['snapshot','softr','softr-published','review-softr'].includes(mode))throw Error('Unknown catalogue source.');
 let cached=null,pending=null,generation=0;
 async function load(){
  if(cached&&now()-cached.loadedAt<ttlMs)return cached.value;
  if(pending)return pending;
  const startedGeneration=generation;
  const request=Promise.resolve().then(async()=>{
   let value;
   if(mode==='softr')value={records:await liveRead(),source:'softr',fetchedAt:new Date(now()).toISOString()};
   else {
    let data=JSON.parse(fs.readFileSync(snapshotPath,'utf8'));
    const extra=supplementPath===false?null:supplementPath||path.join(path.dirname(snapshotPath),'catalogue-supplement.json');
    if(extra&&fs.existsSync(extra))data=Supplement.merge(data,JSON.parse(fs.readFileSync(extra,'utf8')));
    const references=consumptionReferencePath===false?null:consumptionReferencePath||path.join(path.dirname(snapshotPath),'consumption-reference.json');
    if(references&&fs.existsSync(references))data=require('./consumption-reference').merge(data,JSON.parse(fs.readFileSync(references,'utf8')));
    if(mode==='snapshot'&&localContent&&data.mallId)data=require('./store-content').mergeLocal(data);
    if(mode==='review-softr')data=require('./review-softr-catalogue').overlay(data,await liveRead());
    if(mode==='softr-published'){
     const cloud=await liveRead();
     data=require('./softr-published-catalogue').merge(data,cloud,{retrievedAt:new Date(now()).toISOString()});
     data=require('./featured-items-publication').merge(data,cloud);
    }
    value={records:data.records,source:data.source||'snapshot',fetchedAt:data.fetchedAt,...(data.mallId?{mallId:data.mallId}:{}),...(data.catalogueVersion?{catalogueVersion:data.catalogueVersion}:{}),...(data.supplement?{supplement:data.supplement}:{}),...(data.consumptionReference?{consumptionReference:data.consumptionReference}:{}),...(data.publication?{publication:data.publication,softrLinks:data.softrLinks}:{})};
   }
   if(!Array.isArray(value.records))throw Error('Invalid catalogue records.');
   const result={...value,stale:false};
   if(startedGeneration===generation)cached={value:result,loadedAt:now()};return result;
  }).catch(error=>{
   if((mode==='softr-published'||mode==='review-softr')&&cached&&startedGeneration===generation){
    console.warn(JSON.stringify({event:'softr_catalogue_refresh_failed'}));
    return {...cached.value,stale:true};
   }
   throw error;
  }).finally(()=>{if(pending===request)pending=null;});
  pending=request;return request;
 }
 function invalidate(){generation++;cached=null;pending=null;}
 return {load,invalidate};
}
module.exports={create};
