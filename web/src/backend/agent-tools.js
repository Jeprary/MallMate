'use strict';
const crypto=require('node:crypto');
const Adapter=require('../shared/store-adapter'),Candidates=require('../shared/chat-candidates'),Conversation=require('../shared/conversation');
const catalogueExtras=require('../../assets/store-photos.json');
const LocalReviews=require('./local-review-store');
const Opening=require('./opening-hours'),Time=require('./time-context');
const Summary=require('./catalogue-summary');
const SEARCH_DEFAULTS={query:'',kind:'browse',limit:9},REVIEW_DEFAULTS={query:'',limit:4},WEB_DEFAULTS={limit:3};
// Cache equivalence mirrors existing argument semantics; execution still validates the original arguments.
function cacheArgs(name,args){
 if(!args||typeof args!=='object'||Array.isArray(args))return args;
 if(name==='search_places'){
  const query=args.query??SEARCH_DEFAULTS.query;
  return {...args,kind:args.kind||SEARCH_DEFAULTS.kind,limit:args.limit??SEARCH_DEFAULTS.limit,query:typeof query==='string'&&query.length<=80?query.toLowerCase().trim():query};
 }
 if(name==='get_place_reviews'){
  const query=args.query??REVIEW_DEFAULTS.query;
  return {...args,limit:args.limit??REVIEW_DEFAULTS.limit,query:typeof query==='string'&&Array.from(query).length<=80?query.trim().toLocaleLowerCase():query};
 }
 if(name==='search_web')return {...args,limit:args.limit??WEB_DEFAULTS.limit,query:typeof args.query==='string'&&args.query.length<=120?args.query.trim():args.query};
 return args;
}
const TOOL_SCHEMA=[
 {name:'search_places',description:'Search the connected mall catalogue. Each place includes its name and a short summary derived from listed type/tags, not a review verdict; cite the underlying fields as evidence. Names can include the published English display label nameEn; many type labels are Chinese. query is ONE literal substring, not semantic search or automatic translation; a user preference need not be a literal directory term. Query language is independent of reply language. Use an empty query to browse diverse subtypes when no matching literal term is known. Returns listed opening-time observations at the current turn time, not live availability; unknown facts stay unknown.',args:{query:'optional literal string, <=80 characters',kind:'browse|shopping|food|drink|rest|entertainment|facility',limit:'integer 1..12'}},
 {name:'get_current_selection',description:'Resolve references such as this one/second card by reading the current displayed IDs against the server catalogue. Missing IDs stay missing.',args:{}},
 {name:'get_place_details',description:'Read facts for up to three IDs from the initial catalogue overview, earlier observations or currently displayed cards, including consumption reference source observations and raw listed hours evaluated at the current turn time. This is not live opening verification. IDs resolve against the server catalogue.',args:{storeIds:'array of 1..3 overview, observed or current store IDs'}},
 {name:'get_place_location',description:'Read the listed floor/address and supported map binding for an overview, observed or current store ID, not a live route. IDs are resolved server-side.',args:{storeId:'one overview, observed or current store ID'}},
 {name:'get_place_reviews',description:'Search saved local review text for up to three IDs from the initial catalogue overview, earlier observations or currently displayed cards. IDs are resolved server-side; newly resolved store facts accompany the reviews. query is one exact substring, not semantic search. Historical opinions only; held reviews and paused stores are excluded. Keywords mean mentions, including negations, not positive facts.',args:{storeIds:'array of 1..3 overview, observed or current store IDs',query:'optional exact substring, <=80 characters',limit:'optional total 1..6, default 4'}}
];
const WEB_TOOL={name:'search_web',description:'Search public web sources for one overview, observed or currently displayed store or its brand when local facts are insufficient. IDs are resolved server-side. Results are excerpts, not verified branch facts or full reviews. Check branch identity, source and date. This does not replace reading saved local reviews.',args:{storeId:'one overview, observed or current store ID',query:'nonempty search string, <=120 characters',limit:'optional integer 1..3, default 3'}};
const kinds=['browse','shopping','food','drink','rest','entertainment','facility'];
function coverOptions(store){
 return (store?.photos||[]).filter(photo=>photo.title).map(photo=>({
  id:'photo-'+crypto.createHash('sha256').update(photo.url).digest('hex').slice(0,16),
  title:photo.title,source:photo.source,url:photo.url
 }));
}
const publicCoverOptions=store=>coverOptions(store).map(({id,title,source})=>({id,title,source}));
function prepareRecords(records){
 return records.filter(r=>r&&r.fields&&r.fields.Isdemo!==true&&!/^demo\b/i.test(String(r.fields.Name||''))).map(r=>{const fields={...r.fields,...(r.fields.AmapPoiId?{Quiet:null}:{})};const extra=catalogueExtras[fields.AmapPoiId];if((!fields.Tags||Array.isArray(fields.Tags)&&!fields.Tags.length)&&extra?.businessTags?.length)fields.Tags=extra.businessTags;return {id:r.id,fields};});
}
function create({loadCatalogue,input,publicStores=x=>x,manifest=()=>({bindings:[]}),reviewStore=LocalReviews.create(),webSearch,signal,currentTime=Time.create(),modelInterpreted=false}){
 let catalogue,loading;const observed=new Map(),overviewNames=new Map();
 const pendingResolved=new Map();
 const schema=typeof webSearch==='function'?[...TOOL_SCHEMA,WEB_TOOL]:TOOL_SCHEMA;
 const webEvidence=new Map();
 const observedReviews=new Map(),reviewChecks=new Set();
 async function load(){
  if(catalogue)return catalogue;
  if(!loading)loading=Promise.resolve().then(loadCatalogue).then(async data=>{
   const records=publicStores(prepareRecords(data.records||[]));
   const stores=await Promise.all(records.map(async r=>{const s=Adapter.normalizeRecord(r),coverage=await reviewStore.coverage(reviewKey(s));return {...s,operationStatus:coverage.operationStatus||'unknown'};}));
   catalogue={stores,source:data.source||'catalogue',version:data.catalogueVersion||data.fetchedAt||null,consumptionReferenceInfo:data.consumptionReference||null};return catalogue;
  });
  return loading;
 }
 function listedOpening(s,at=currentTime.iso){
  if(s.listedHours?.reason==='conflicting_sources')return {...Opening.evaluate(null,at),reason:'conflicting_sources'};
  const opening=Opening.evaluate(s.hours,at);
  return s.listedHours?.source?{...opening,source:s.listedHours.source}:opening;
 }
 function fact(s,at=currentTime.iso){return {id:s.id,name:s.name,...(s.nameEn?{nameEn:s.nameEn}:{}),shortSummary:Summary.create(s),storeContent:s.content||null,consumptionReference:s.consumptionReference,entityType:s.entityType,amapType:s.amapType,tags:s.tags,floor:s.floor,hours:s.hours,listedOpening:listedOpening(s,at),min:s.min,max:s.max,quiet:s.quiet,minutes:s.minutes,operationStatus:s.operationStatus};}
 async function catalogueOverview(){
  const c=await load();
  // Identity, consumption and current listed status orient the first choice.
  // Detailed schedules and other branch facts still require a store read.
  for(const s of c.stores)overviewNames.set(s.id,{id:s.id,name:s.name,consumptionReference:Adapter.briefConsumptionReference(s.consumptionReference),operationStatus:s.operationStatus});
  return {source:c.source,catalogueVersion:c.version,total:c.stores.length,openingContext:{evaluatedAt:currentTime.iso,timeZone:Opening.TIME_ZONE,basis:'listed_hours',liveVerified:false},...(c.consumptionReferenceInfo?{consumptionReferenceInfo:c.consumptionReferenceInfo}:{}),places:c.stores.map(s=>({id:s.id,name:s.name,...(s.nameEn?{nameEn:s.nameEn}:{}),shortSummary:Summary.create(s),consumptionReference:Adapter.briefConsumptionReference(s.consumptionReference),openingStatus:listedOpening(s).status}))};
 }
 function reviewKey(s){return /^B[A-Z0-9]{8,}$/.test(s.amapPoiId||'')?'amap-'+s.amapPoiId:s.id;}
 async function reviewCoverage(s){return {...await reviewStore.coverage(reviewKey(s)),storeId:s.id};}
 function ensureArgs(args,keys){if(!args||typeof args!=='object'||Array.isArray(args)||Object.keys(args).some(k=>!keys.includes(k)))throw Error('Invalid tool arguments');}
 function get(id){
  if(typeof id==='string'&&observed.has(id))return observed.get(id);
  if(typeof id==='string'&&(overviewNames.has(id)||(input.currentStoreIds||[]).includes(id))){
   const store=catalogue?.stores.find(s=>s.id===id);if(store){pendingResolved.set(id,store);return store;}
  }
  throw Error('Store ID has not been returned by search');
 }
 async function executeInternal(name,args){
  if(!schema.some(t=>t.name===name))throw Error('Tool is unavailable');
  const c=await load();
  if(name==='search_web'){
   ensureArgs(args,['storeId','query','limit']);const s=get(args.storeId),limit=args.limit??WEB_DEFAULTS.limit;
   if(typeof args.query!=='string'||!args.query.trim()||args.query.length>120||!Number.isInteger(limit)||limit<1||limit>3)throw Error('Invalid web search arguments');
   if(signal?.aborted)throw Error('Search cancelled');
   const response=await webSearch({storeId:s.id,storeName:s.name,query:args.query.trim(),limit,signal});
   if(signal?.aborted)throw Error('Search cancelled');
   if(!response||!Array.isArray(response.results))throw Error('Invalid web search response');
   const results=[];const seen=new Set();const retrievedAt=new Date().toISOString();
   for(const row of response.results){
    if(results.length>=limit)break;
    if(!row||typeof row.title!=='string'||!row.title.trim()||typeof row.snippet!=='string'||!row.snippet.trim())continue;
    let url;try{url=new URL(row.url);}catch{continue;}
    if(!['https:','http:'].includes(url.protocol)||url.username||url.password||seen.has(url.href))continue;
    seen.add(url.href);
    const snippet=row.snippet.slice(0,600),id='web-'+crypto.createHash('sha256').update(JSON.stringify([s.id,url.href,snippet])).digest('hex').slice(0,24);
    results.push({id,storeId:s.id,title:row.title.trim().slice(0,180),url:url.href,snippet,publishedDate:typeof row.publishedDate==='string'?row.publishedDate.slice(0,40):null,retrievedAt,scope:'unverified_store_or_brand',currentFact:false});
   }
   const rows=webEvidence.get(s.id)||new Map();for(const row of results)rows.set(row.id,row);webEvidence.set(s.id,rows);
   return {provider:typeof response.provider==='string'?response.provider.slice(0,80):'injected_search',storeId:s.id,query:args.query.trim(),retrievedAt,results,note:'Search excerpts may concern the brand or another branch. Check identity and date; they do not verify live availability or hard constraints.'};
  }
  if(name==='search_places'){
   ensureArgs(args,['query','kind','limit']);const at=currentTime.iso;
   const kind=args.kind||SEARCH_DEFAULTS.kind,limit=args.limit??SEARCH_DEFAULTS.limit,query=args.query??SEARCH_DEFAULTS.query;
   if(!kinds.includes(kind)||!Number.isInteger(limit)||limit<1||limit>12||typeof query!=='string'||query.length>80)throw Error('Invalid search arguments');
   const base=modelInterpreted?{excludedTerms:input.excludedTerms||[]}:Conversation.decide(input),skip=new Set([...(input.excludedStoreIds||[]),...(input.cardFeedback&&input.source==='card'?input.currentStoreIds||[]:[])]),q=query.trim();
   const type={shopping:'retail',food:'food',drink:'drink',rest:'facility',entertainment:'entertainment',facility:'facility'}[kind];
   let rows=c.stores.filter(s=>s.operationStatus!=='platform_temporarily_closed'&&!skip.has(s.id)&&!Candidates.excluded(s,base.excludedTerms||[])&&(!type||s.entityType===type));
   if(q)rows=Candidates.directory(rows,{query:q});
   // Unknown hard constraints are not silently treated as satisfied. Return facts
   // for inspection; the final evidence/constraint validator decides eligibility.
   // Interleave subtypes so a short page is less likely to contain one cuisine only.
   const groups=new Map();for(const s of rows){const key=s.amapType||s.entityType;const group=groups.get(key)||[];group.push(s);groups.set(key,group);}
   const selected=[];while(selected.length<limit){let added=false;for(const group of groups.values())if(group.length&&selected.length<limit){selected.push(group.shift());added=true;}if(!added)break;}
   selected.forEach(s=>observed.set(s.id,s));
   const availableSubtypes=rows.length?undefined:[...c.stores.filter(s=>!type||s.entityType===type).reduce((map,s)=>map.set(s.amapType||s.entityType,(map.get(s.amapType||s.entityType)||0)+1),new Map())].map(([type,count])=>({type,count}));
   return {source:c.source,catalogueVersion:c.version,currentTime,evaluatedAt:at,totalMatches:rows.length,places:selected.map(s=>fact(s,at)),...(availableSubtypes?{availableSubtypes,coverageNote:'No matching record in this directory snapshot does not establish that the mall has no such store.'}:{}),reviewCoverage:await Promise.all(selected.map(reviewCoverage)),unknownFacts:['queue','seats','live_open_status','total_visit_duration'],moreAvailable:rows.length>selected.length};
  }
  if(name==='get_current_selection'){
   ensureArgs(args,[]);const ids=input.currentStoreIds||[],places=ids.map(id=>c.stores.find(s=>s.id===id)).filter(Boolean);places.forEach(s=>observed.set(s.id,s));
   return {source:c.source,catalogueVersion:c.version,currentTime,places:places.map(s=>fact(s)),...(input.focusedStoreId?{focusedStoreId:places.some(s=>s.id===input.focusedStoreId)?input.focusedStoreId:null}:{}),missingIds:ids.filter(id=>!places.some(s=>s.id===id))};
  }
  if(name==='get_place_details'){
   ensureArgs(args,['storeIds']);const at=currentTime.iso;if(!Array.isArray(args.storeIds)||args.storeIds.length<1||args.storeIds.length>3||new Set(args.storeIds).size!==args.storeIds.length)throw Error('Invalid detail IDs');
   return {source:c.source,catalogueVersion:c.version,currentTime,evaluatedAt:at,places:await Promise.all(args.storeIds.map(async id=>{const s=get(id);return {...fact(s,at),address:s.address,mallName:s.mallName,amapPoiId:s.amapPoiId,coverOptions:publicCoverOptions(s),reviewCoverage:await reviewCoverage(s),unknownFacts:['queue','seats','live_open_status','total_visit_duration']};}))};
  }
  if(name==='get_place_reviews'){
   ensureArgs(args,['storeIds','query','limit']);
   if(!Array.isArray(args.storeIds)||args.storeIds.length<1||args.storeIds.length>3||new Set(args.storeIds).size!==args.storeIds.length)throw Error('Invalid review IDs');
   const stores=args.storeIds.map(id=>get(id));
   const byLocal=new Map(stores.map(s=>[reviewKey(s),s.id]));
   if(byLocal.size!==args.storeIds.length)throw Error('Duplicate review branch IDs');
   const local=await reviewStore.getReviews({storeIds:[...byLocal.keys()],query:args.query??REVIEW_DEFAULTS.query,limit:args.limit??REVIEW_DEFAULTS.limit});
   const result={...local,places:(local.places||[]).map(p=>({...p,storeId:byLocal.get(p.storeId)})),reviews:(local.reviews||[]).map(r=>({...r,storeId:byLocal.get(r.storeId)})),covers:stores.map(store=>({storeId:store.id,options:publicCoverOptions(store)})).filter(row=>row.options.length)};
   for(const review of result.reviews||[]){
    if(!args.storeIds.includes(review.storeId)||review.currentFact!==false||review.blockedForCurrentRecommendation||review.recommendationEvidenceStatus!=='historical_opinion')throw Error('Invalid local review observation');
    const rows=observedReviews.get(review.storeId)||new Map();rows.set(review.id,{id:review.id,publishedDate:review.publishedDate,sourceUrl:review.sourceUrl});observedReviews.set(review.storeId,rows);
   }
   if(result.databaseAvailable===true)for(const id of args.storeIds){
    const coverage=result.places?.find(p=>p.storeId===id);
    const textRead=result.reviews?.some(r=>r.storeId===id&&typeof r.textExcerpt==='string'&&r.textExcerpt.trim());
    // A failed search term or a low total limit cannot stand in for reading a store's text.
    if(coverage?.databaseAvailable===true&&(coverage.status==='store_not_in_database'||coverage.eligibleBodyCount===0||textRead))reviewChecks.add(id);
   }
   return result;
  }
  ensureArgs(args,['storeId']);const s=get(args.storeId),binding=(manifest().bindings||[]).find(b=>b.poiId&&b.poiId===s.amapPoiId);
  return {storeId:s.id,name:s.name,floor:s.floor,address:s.address,mapAvailable:!!binding,binding:binding?{floor:binding.floor,regionId:binding.regionId}:null,liveRouteAvailable:false};
 }
 // Agent tools execute sequentially. Only a successful operation publishes
 // server-resolved facts; client IDs are never accepted as facts.
 async function execute(name,args){
  pendingResolved.clear();
  try{
   const result=await executeInternal(name,args),resolvedPlaces=[...pendingResolved.values()].map(s=>fact(s,result.evaluatedAt||currentTime.iso)),resolvedCurrentPlaces=resolvedPlaces.filter(s=>(input.currentStoreIds||[]).includes(s.id));
   for(const [id,store] of pendingResolved)observed.set(id,store);
   pendingResolved.clear();return {...result,...(resolvedPlaces.length?{resolvedPlaces}:{}),...(resolvedCurrentPlaces.length?{resolvedCurrentPlaces}:{})};
  }catch(error){pendingResolved.clear();throw error;}
 }
 function coverFor(storeId,photoId){
  if(typeof photoId!=='string')return null;
  const store=catalogue?.stores.find(item=>item.id===storeId);
  return coverOptions(store).find(photo=>photo.id===photoId)?.url||null;
 }
 return {schema,execute,catalogueOverview,coverFor,reviewChecks:()=>[...reviewChecks],webSources:()=>[...webEvidence.values()].flatMap(rows=>[...rows.values()]),observedFacts:()=>[...new Map([...overviewNames,...[...observed].map(([id,s])=>[id,fact(s)])]).values()].map(s=>({...s,reviewEvidence:[...(observedReviews.get(s.id)?.values()||[])],webEvidence:[...(webEvidence.get(s.id)?.values()||[])]})),version:()=>catalogue?.version||null};
}
module.exports={create,TOOL_SCHEMA,WEB_TOOL,prepareRecords,cacheArgs};
