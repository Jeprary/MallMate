// Read historical review evidence from a local snapshot; no network or credentials.
'use strict';
const fs=require('node:fs/promises'),path=require('node:path');
const DEFAULT_PATH=path.resolve(__dirname,'../../.local-data/restaurant-evidence.json');
const SOURCE='local-review-database',MAX_EXCERPT=240;
const HELD=new Set(['hold_for_branch_verification','hold_for_menu_verification']);

function chars(value){return Array.from(value);}
function validateId(value){return typeof value==='string'&&value.trim()===value&&value.length>0&&value.length<=200;}
function publicUrl(value){
 if(typeof value!=='string')throw Error('Invalid review source');
 const parsed=new URL(value);
 if(!['https:','http:'].includes(parsed.protocol)||parsed.username||parsed.password)throw Error('Invalid review source');
 return value;
}
function keywordFields(value){
 if(!value||typeof value!=='object'||Array.isArray(value)||typeof value.term!=='string')throw Error('Invalid review keyword');
 if(value.polarity!=='mention_only')throw Error('Unsupported review keyword polarity');
 const result={term:value.term};
 for(const key of ['aspect','polarity'])if(Object.hasOwn(value,key)){
  if(typeof value[key]!=='string')throw Error('Invalid review keyword');
  result[key]=value[key];
 }
 for(const key of ['evidenceStart','evidenceEnd'])if(Object.hasOwn(value,key)){
  if(!Number.isInteger(value[key])||value[key]<0)throw Error('Invalid review keyword');
  result[key]=value[key];
 }
 return result;
}
function normalize(data){
 if(!data||data.schemaVersion!==1||!Array.isArray(data.restaurants)||!Array.isArray(data.reviews))throw Error('Invalid local review snapshot');
 const restaurants=new Map(),reviews=new Map(),ids=new Set();
 for(const row of data.restaurants){
  if(!row||!validateId(row.id)||typeof row.name!=='string'||restaurants.has(row.id))throw Error('Invalid restaurant identity');
  if(row.address!=null&&typeof row.address!=='string'||row.floor!=null&&!['string','number'].includes(typeof row.floor)||row.operationStatus!=null&&typeof row.operationStatus!=='string')throw Error('Invalid restaurant fields');
  restaurants.set(row.id,{id:row.id,name:row.name,floor:row.floor??null,address:row.address??null,operationStatus:row.operationStatus||'unknown'});
  reviews.set(row.id,[]);
 }
 for(const row of data.reviews){
  if(!row||!validateId(row.id)||ids.has(row.id)||!restaurants.has(row.restaurantId)||typeof row.text!=='string'||!row.text.trim()||typeof row.status!=='string')throw Error('Invalid local review record');
  for(const key of ['publishedDate','bodySha256','baselineBodySha256'])if(row[key]!=null&&typeof row[key]!=='string')throw Error('Invalid review metadata');
  if(row.keywords!=null&&!Array.isArray(row.keywords))throw Error('Invalid review keywords');
  ids.add(row.id);
  const review={id:row.id,restaurantId:row.restaurantId,text:row.text,summary:typeof row.summary==='string'?row.summary:'',publishedDate:row.publishedDate??null,sourceUrl:publicUrl(row.sourceUrl),provider:typeof row.provider==='string'?row.provider:'unknown',bodySha256:row.bodySha256??null,baselineBodySha256:row.baselineBodySha256??null,status:row.status,blockedForCurrentRecommendation:row.blockedForCurrentRecommendation===true,keywords:(row.keywords||[]).map(keywordFields)};
  reviews.get(row.restaurantId).push(review);
 }
 const textRepresentation=data.textRepresentation==='review_summary'?'review_summary':'review_excerpt';
 return {builtAt:typeof data.builtAt==='string'?data.builtAt:null,textRepresentation,restaurants,reviews};
}
function blocked(review,restaurant){return review.blockedForCurrentRecommendation||restaurant.operationStatus==='platform_temporarily_closed';}
function eligible(review,restaurant){return review.status==='historical_opinion'&&!blocked(review,restaurant);}
function excerpt(text,query){
 const codepoints=chars(text),needle=chars(query.toLocaleLowerCase());
 let start=0;
 if(needle.length){
  const offset=text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());
  if(offset>=0)start=Math.max(0,chars(text.slice(0,offset)).length-80);
 }
 if(start+MAX_EXCERPT>codepoints.length)start=Math.max(0,codepoints.length-MAX_EXCERPT);
 return {textExcerpt:codepoints.slice(start,start+MAX_EXCERPT).join(''),truncated:codepoints.length>MAX_EXCERPT,textCharacterCount:codepoints.length,excerptStart:start};
}
function matches(review,query){
 if(!query)return true;
 const q=query.toLocaleLowerCase();
 return review.text.toLocaleLowerCase().includes(q)||review.keywords.some(k=>k.term.toLocaleLowerCase().includes(q));
}
function create({filePath=process.env.MALLMATE_REVIEW_SNAPSHOT||DEFAULT_PATH,loadSnapshot}={}){
 if(loadSnapshot!==undefined&&typeof loadSnapshot!=='function')throw Error('Invalid snapshot loader');
 let loading;
 function load(){
  if(!loading)loading=Promise.resolve().then(async()=>{
   try{
    const data=loadSnapshot?await loadSnapshot():JSON.parse(await fs.readFile(filePath,'utf8'));
    return {ok:true,data:normalize(data)};
   }catch(error){return {ok:false,reason:error.code==='ENOENT'?'missing_snapshot':error instanceof SyntaxError?'invalid_snapshot':'snapshot_unavailable'};}
  });
  return loading;
 }
 function unavailable(extra={}){return {databaseAvailable:false,status:'database_unavailable',source:SOURCE,builtAt:null,...extra};}
 function coverageFrom(data,storeId){
  const restaurant=data.restaurants.get(storeId);
  if(!restaurant)return {databaseAvailable:true,status:'store_not_in_database',source:SOURCE,builtAt:data.builtAt,storeId,bodyCount:null,eligibleBodyCount:null,heldBodyCount:null,blockedBodyCount:null};
  const rows=data.reviews.get(storeId);
  return {databaseAvailable:true,status:rows.length?'available':'no_reviews',source:SOURCE,builtAt:data.builtAt,storeId,name:restaurant.name,operationStatus:restaurant.operationStatus,bodyCount:rows.length,eligibleBodyCount:rows.filter(r=>eligible(r,restaurant)).length,heldBodyCount:rows.filter(r=>HELD.has(r.status)).length,blockedBodyCount:rows.filter(r=>blocked(r,restaurant)).length};
 }
 async function coverage(storeId){
  if(!validateId(storeId))throw Error('Invalid store ID');
  const state=await load();
  if(!state.ok)return unavailable({storeId,reason:state.reason,bodyCount:null,eligibleBodyCount:null,heldBodyCount:null,blockedBodyCount:null});
  return coverageFrom(state.data,storeId);
 }
 async function getReviews({storeIds,query='',limit=4,includeHeld=false}={}){
  if(!Array.isArray(storeIds)||storeIds.length<1||storeIds.length>3||new Set(storeIds).size!==storeIds.length||!storeIds.every(validateId)||typeof query!=='string'||chars(query).length>80||!Number.isInteger(limit)||limit<1||limit>6||typeof includeHeld!=='boolean')throw Error('Invalid review query');
  query=query.trim();
  const state=await load();
  if(!state.ok)return unavailable({reason:state.reason,places:[],reviews:[],totalMatches:null,moreAvailable:false});
  const data=state.data,places=storeIds.map(id=>coverageFrom(data,id)),groups=[];
  for(const storeId of storeIds){
   const restaurant=data.restaurants.get(storeId);
   if(!restaurant)continue;
   groups.push(data.reviews.get(storeId).filter(r=>(includeHeld||eligible(r,restaurant))&&matches(r,query)));
  }
  const totalMatches=groups.reduce((n,g)=>n+g.length,0),selected=[];
  while(selected.length<limit){
   let found=false;
   for(const group of groups)if(group.length&&selected.length<limit){selected.push(group.shift());found=true;}
   if(!found)break;
  }
  const output=selected.map(review=>{
   const restaurant=data.restaurants.get(review.restaurantId);
   return {id:review.id,storeId:review.restaurantId,storeName:restaurant.name,...excerpt(review.text,query),summary:review.summary,publishedDate:review.publishedDate,sourceUrl:review.sourceUrl,provider:review.provider,bodySha256:review.bodySha256,baselineBodySha256:review.baselineBodySha256,keywords:review.keywords.map(k=>({...k})),recommendationEvidenceStatus:review.status,blockedForCurrentRecommendation:blocked(review,restaurant),historicalOpinion:true,currentFact:false,textRepresentation:data.textRepresentation,fullTextStoredLocally:data.textRepresentation==='review_excerpt'};
  });
  const anyKnown=places.some(p=>p.status!=='store_not_in_database'),anyBodies=places.some(p=>p.bodyCount>0);
  const status=output.length?'available':!anyKnown?'store_not_in_database':!anyBodies?'no_reviews':query?'no_matches':'no_eligible_reviews';
  return {databaseAvailable:true,status,source:SOURCE,builtAt:data.builtAt,places,reviews:output,totalMatches,moreAvailable:totalMatches>output.length};
 }
 async function stats(){
  const state=await load();
  if(!state.ok)return unavailable({reason:state.reason,restaurantCount:null,reviewBodyCount:null,restaurantsWithReviewBodies:null,eligibleBodyCount:null,heldBodyCount:null,blockedBodyCount:null});
  const data=state.data,all=[...data.reviews.values()].flat();
  return {databaseAvailable:true,status:'available',source:SOURCE,builtAt:data.builtAt,restaurantCount:data.restaurants.size,reviewBodyCount:all.length,restaurantsWithReviewBodies:[...data.reviews.values()].filter(r=>r.length).length,eligibleBodyCount:all.filter(r=>eligible(r,data.restaurants.get(r.restaurantId))).length,heldBodyCount:all.filter(r=>HELD.has(r.status)).length,blockedBodyCount:all.filter(r=>blocked(r,data.restaurants.get(r.restaurantId))).length};
 }
 return {coverage,getReviews,stats};
}
module.exports={create};
