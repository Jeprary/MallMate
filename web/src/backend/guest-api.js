// Narrow guest-facing reads and bounded AI access. No account, config or write routes.
'use strict';
const storeMedia=require('../shared/store-media.js');
const Intent=require('../shared/mall-intent.js');
const Clarifications=require('../shared/clarification-count.js');
const CardFeedback=require('../shared/card-feedback.js');
const Presentation=require('../shared/recommendation-presentation.js');
const Requirements=require('../shared/requirements.js');
const Needs=require('../shared/needs.js');
const Adapter=require('../shared/store-adapter');
const Opening=require('./opening-hours');
const openingEvidence=require('../../assets/opening-hours-holds.json');
const photoLibrary=require('../../assets/store-photos.json');
const photoSelection=require('../../assets/photo-selection.json');
const photoSupplement=require('../../assets/store-photo-supplement.json');
const {sameSitePhoto}=require('./arrival-assets.js');
const reviewHighlights=require('../../assets/store-review-highlights.json');
const featuredDishes=require('../../assets/store-featured-dishes.json');
const englishStoreNames=require('../../assets/store-names-en.json');
const FIELD_NAMES=['Name','NameEn','Category','Pricemin','Pricemax','Floor','AmapFloor','AmapPoiId','AmapIndoorPid','BuildingId','MallName','Address','Hours','Quiet','Tags','Cuisine','Walkminutes','AmapType','MallPoiId','MallId','AmapHours','EntityType'];
const fieldKey=s=>String(s).toLowerCase().replace(/[^a-z]/g,'');
const fieldsByKey=new Map(FIELD_NAMES.map(name=>[fieldKey(name),name]));
function publicValue(value,depth=0){
 if(value===null||['string','number','boolean'].includes(typeof value))return value;
 if(depth>=3)return undefined;
 if(Array.isArray(value))return value.slice(0,60).map(v=>publicValue(v,depth+1)).filter(v=>v!==undefined);
 if(value&&typeof value==='object')for(const key of ['label','name','value']){
  if(Object.hasOwn(value,key)){const clean=publicValue(value[key],depth+1);if(clean!==undefined)return clean;}
 }
 return undefined;
}
function publicStores(records,{withStoreDetails=false}={}){
 return (Array.isArray(records)?records:[]).filter(r=>r&&typeof r.id==='string'&&/^[A-Za-z0-9_-]{1,200}$/.test(r.id)).map(r=>{
  const fields={};for(const [key,value] of Object.entries(r.fields||{})){
   const name=fieldsByKey.get(fieldKey(key));if(!name)continue;
   const clean=publicValue(value);if(clean!==undefined)fields[name]=clean;
  }
  // PhotoUrl/ImageUrl/CoverImage/Photos bypass the generic field whitelist:
  // publish only the validated URL and explicit public attribution/title.
  const primaryPhotos=storeMedia.allFromFields(r.fields);
  const excluded=new Set([...primaryPhotos.map(p=>p.url),...(photoSelection[fields.AmapPoiId]?.rejectedUrls||[])]);
  const labelledBrandPhotos=(photoLibrary[fields.AmapPoiId]?.photos||[]).filter(p=>p.title&&/品牌官网/.test(p.source||''));
  const alternatives=storeMedia.allFromFields({Photos:labelledBrandPhotos}).filter(p=>!excluded.has(p.url));
  const orderedPhotos=[];
  const seen=new Set();
  const sources=[...primaryPhotos,...alternatives];
  const preferred=photoSelection[fields.AmapPoiId]?.coverUrl;
  const preferredIndex=sources.findIndex(source=>source.url===preferred);
  const explicitUpload=primaryPhotos[0]?.url.startsWith('https://mallmate.pages.dev/assets/uploads/');
  if(!explicitUpload&&preferredIndex>0)sources.unshift(...sources.splice(preferredIndex,1));
  const verifiedSupplement=photoSupplement[fields.AmapPoiId];
  for(const source of sources){
   const url=sameSitePhoto(source.url);
   if(!url||seen.has(url))continue;
   orderedPhotos.push({...source,url});
   seen.add(url);
   if(orderedPhotos.length===12)break;
  }
  if(!orderedPhotos.length&&verifiedSupplement){
   for(const source of storeMedia.allFromFields({Photos:[verifiedSupplement]})){
    const url=sameSitePhoto(source.url);
    if(url)orderedPhotos.push({...source,url});
   }
  }
  const photo=orderedPhotos[0];
  if(withStoreDetails&&!photo)fields.PhotoEvidenceStatus='unverified';
  const reference=Object.entries(r.fields||{}).find(([key])=>fieldKey(key)==='consumptionreference');
  if(reference)fields.ConsumptionReference=Adapter.normalizeConsumptionReference(reference[1]);
  const content=Object.entries(r.fields||{}).find(([key])=>fieldKey(key)==='storecontent');
  if(content){const clean=Adapter.normalizeStoreContent(content[1]);if(clean)fields.StoreContent=clean;}
  if(withStoreDetails&&r.id===`amap-${fields.AmapPoiId}`){
   const reviewSet=reviewHighlights[fields.MallPoiId]?.[fields.AmapPoiId];
   if(reviewSet)fields.ReviewHighlights=reviewSet;
   const dishes=featuredDishes[fields.MallPoiId]?.[fields.AmapPoiId];
   const publication=require('./featured-items-publication').publicFields(r,{curated:dishes});
   for(const item of [...(publication.FeaturedItems||[]),...(publication.FeaturedDishes?.items||[]),...(publication.StoreEvents?.items||[])]){
    const safeUrl=storeMedia.fromFields({PhotoUrl:item.imageUrl})?.url;
    item.imageUrl=sameSitePhoto(item.image)||sameSitePhoto(safeUrl);
   }
   Object.assign(fields,publication);
  }
  if(photo){fields.PhotoUrl=photo.url;fields.PhotoSource=photo.source;fields.PhotoTitle=photo.title;if(orderedPhotos.length>1)fields.Photos=orderedPhotos;}
  // Derive from sanitized raw hours for every source. Never forward a supplied
  // schedule as trusted data, and never attach a wall-clock/live status here.
  fields.ListedHours=Opening.describe(Adapter.normalizeRecord({id:r.id,fields}).hours);
  const conflict=openingEvidence.holds.find(hold=>hold.mallPoiId===fields.MallPoiId&&hold.amapPoiId===fields.AmapPoiId&&hold.reason==='conflicting_sources');
  if(conflict){
   const candidates=conflict.observations.filter(observation=>openingEvidence.preferredSources.includes(observation.source)&&Opening.describe(observation.listedHours).status==='parsed');
   const schedules=new Set(candidates.map(observation=>JSON.stringify(Opening.describe(observation.listedHours).schedule)));
   const preferred=schedules.size===1?candidates[0]:null;
   if(preferred){
    fields.Hours=preferred.listedHours;
    fields.ListedHours={...Opening.describe(fields.Hours),source:{label:preferred.source,url:preferred.url,checkedOn:preferred.checkedOn}};
   }else{
    fields.Hours=null;
    fields.AmapHours=null;
    fields.ListedHours={...Opening.describe(null),weekdayConvention:'ISO-8601',reason:'conflicting_sources'};
   }
  }
  if(!fields.NameEn&&Object.hasOwn(englishStoreNames,r.id))fields.NameEn=englishStoreNames[r.id];
  return {id:r.id,fields};
 });
}
function chatInput(input){
 const maxLength=input?.source==='voice'?1500:500;
 if(!input||typeof input!=='object'||Array.isArray(input)||typeof input.text!=='string'||!input.text.trim()||input.text.trim().length>maxLength)throw Error('Enter a message of at most '+maxLength+' characters.');
 const c=input.context;if(!c||typeof c!=='object'||Array.isArray(c))throw Error('Invalid shopping context.');
 const context={};for(const key of ['category','min','max','time','quiet','origin'])context[key]=c[key];
 if(!['all','cafe','food','shops'].includes(c.category)||typeof c.quiet!=='boolean'||!['entrance','atrium'].includes(c.origin)||![c.min,c.max,c.time].every(x=>typeof x==='number'&&Number.isFinite(x))||c.min<0||c.max<c.min||c.max>10000||c.time<1||c.time>240)throw Error('Invalid shopping context.');
 const source={};if(Object.hasOwn(input,'source')){if(!['voice','text','card'].includes(input.source))throw Error('Invalid input source.');source.source=input.source;}
 const history=(Array.isArray(input.history)?input.history:[]).slice(-8).filter(m=>m&&['user','agent'].includes(m.role)&&typeof m.text==='string').map(m=>{const message={role:m.role,text:m.text.slice(0,m.role==='user'&&m.source==='voice'?1500:500)};if(m.role==='user'&&Object.hasOwn(m,'source')){if(!['voice','text','card'].includes(m.source))throw Error('Invalid input source.');message.source=m.source;}return message;});
 const currentStoreIds=(Array.isArray(input.currentStoreIds)?input.currentStoreIds:[]).filter(x=>typeof x==='string'&&/^[A-Za-z0-9_-]{1,200}$/.test(x)).slice(0,3);
 const focus={};if(input.focusedStoreId!=null){if(typeof input.focusedStoreId!=='string'||!currentStoreIds.includes(input.focusedStoreId))throw Error('Invalid focused card');focus.focusedStoreId=input.focusedStoreId;}
 const presentation=Presentation.clean(input.presentation);if(presentation)focus.presentation=presentation;
 const requirements=Requirements.clean(input.requirements);if(requirements)focus.requirements=requirements;
 const needs=Needs.clean(input.needs);if(needs)focus.needs=needs;
 const cardFeedback=CardFeedback.clean(input.cardFeedback,currentStoreIds);
 return {...source,...focus,currentStoreIds,...(cardFeedback?{cardFeedback}:{}),excludedStoreIds:(Array.isArray(input.excludedStoreIds)?input.excludedStoreIds:[]).filter(x=>typeof x==='string'&&/^[A-Za-z0-9_-]{1,200}$/.test(x)).slice(0,200),budgetSpecified:input.budgetSpecified===true,timeSpecified:input.timeSpecified===true,quietRequired:input.quietRequired===true,text:input.text.trim(),context,history,intent:Intent.clean(input.intent),clarificationsUsed:Clarifications.count(input.clarificationsUsed),excludedTerms:(Array.isArray(input.excludedTerms)?input.excludedTerms:[]).filter(x=>typeof x==='string').slice(0,60).map(x=>x.slice(0,60))};
}
function createGuestApi({allStores,loadCatalogue,indoorAssets,AI,body,reply,recommendationEvents,navigationDestination,navigationDestinations,now=()=>Date.now(),rateLimit=6,windowMs=60000,maxConcurrent=2}){
 const attempts=new Map();let inFlight=0;
 function reserve(req){
  const time=now(),key=req.socket?.remoteAddress||'local';
  for(const [address,entry] of attempts)if(entry.until<=time)attempts.delete(address);
  const entry=attempts.get(key)||{count:0,until:time+windowMs};
  if(entry.count>=rateLimit)return {retry:Math.max(1,Math.ceil((entry.until-time)/1000)),message:'Too many AI requests. Please try again shortly.'};
  if(inFlight>=maxConcurrent)return {retry:1,message:'AI is busy. Please try again shortly.'};
  entry.count++;attempts.set(key,entry);inFlight++;return null;
 }
 return async function guestApi(req,res,url){
  const route=url.pathname;if(!route.startsWith('/api/public/'))return false;
  if(req.method==='GET'&&route==='/api/public/stores'){
   try{const data=loadCatalogue?await loadCatalogue():{records:await allStores()};reply(res,200,{records:publicStores(data.records,{withStoreDetails:true}),...(navigationDestination?{navigationDestination}:{}),...(navigationDestinations?{navigationDestinations}:{}),...(data.source?{source:data.source,fetchedAt:data.fetchedAt,stale:data.stale===true}:{}),...(data.catalogueVersion?{catalogueVersion:data.catalogueVersion}:{}),...(data.supplement?{supplement:data.supplement}:{}),...(data.consumptionReference?{consumptionReference:data.consumptionReference}:{}),...(data.publication?{publication:data.publication}:{})});}catch{reply(res,502,{error:'Could not load stores. Please try again.'});}return true;
  }
  if(req.method==='GET'&&route==='/api/public/indoor-map/manifest'){
   try{reply(res,200,indoorAssets.manifest());}catch{reply(res,503,{error:'Floor maps are unavailable.'});}return true;
  }
  const floor=route.match(/^\/api\/public\/indoor-map\/floors\/([123])$/);
  if(req.method==='GET'&&floor){
   try{reply(res,200,indoorAssets.scene(Number(floor[1])));}catch{reply(res,503,{error:'This floor map is unavailable.'});}return true;
  }
  if(req.method==='GET'&&route==='/api/public/ai/status'){
   try{const s=AI.status();reply(res,200,{configured:s.configured===true,provider:String(s.provider||''),model:String(s.model||'')});}catch{reply(res,503,{error:'AI status is unavailable.'});}return true;
  }
  if(req.method==='POST'&&(route==='/api/public/ai/chat'||route==='/api/public/agent/turns')){
   const denied=reserve(req);if(denied){reply(res,429,{error:denied.message},{'Retry-After':String(denied.retry)});return true;}
   try{
    let input;try{input=chatInput(await body(req));}catch{reply(res,400,{error:'Enter a valid message and shopping context.'});return true;}
    if((input.cardFeedback||input.needs||input.requirements)&&route!=='/api/public/agent/turns'){reply(res,400,{error:'Structured conversation state requires the Agent turn endpoint.'});return true;}
    if(!AI.status().configured){reply(res,503,{error:'AI is unavailable. You can still browse stores.'});return true;}
    if(route==='/api/public/agent/turns'){
     if(typeof AI.agentTurn!=='function'){reply(res,503,{error:'Agent is unavailable.'});return true;}
     let tracking;try{tracking=await recommendationEvents?.startTurn(req,res,input);}catch{console.error(JSON.stringify({event:'recommendation_tracking_unavailable'}));}
     await require('./agent-http').streamTurn(req,res,{input,AI,loadCatalogue:loadCatalogue||(async()=>({records:await allStores()})),publicStores,manifest:()=>indoorAssets.manifest(),tracking});return true;
    }
    const data=AI.recommend?(loadCatalogue?await loadCatalogue():{records:await allStores()}):null;
    reply(res,200,AI.recommend?await AI.recommend(input,{records:publicStores(data.records),catalogueVersion:data.fetchedAt||null}):await AI.chat(input));
   }catch(error){if(error.status===429||/\(429\)/.test(error.message||''))reply(res,429,{error:'AI is busy. Please try again shortly.'},{'Retry-After':'10'});else reply(res,503,{error:'AI could not respond. Please try again or browse stores.'});}
   finally{inFlight--;}
   return true;
  }
  reply(res,404,{error:'Not found'});return true;
 };
}
module.exports={createGuestApi,publicStores,chatInput};
