// Catalogue facts are separate from the legacy illustrative AR coordinates.
(function(root){
 'use strict';
 const types=['food','drink','retail','entertainment','facility','unknown'];
 const key=s=>String(s).toLowerCase().replace(/[^a-z0-9]/g,'');
 function values(value){
  if(value==null)return [];
  if(Array.isArray(value))return value.flatMap(values);
  if(typeof value==='object')return values(value.name??value.label??value.value);
  return [value];
 }
 function normalizeConsumptionReference(value){
  const missing=()=>({id:null,status:'missing',value:null,currency:null,observations:[],verifiedBudgetRange:false});
  if(!value||typeof value!=='object'||Array.isArray(value)||!['available','conflict'].includes(value.status)||!/^cost-[a-f0-9]{24}$/.test(value.id||'')||!Array.isArray(value.observations))return missing();
  const date=x=>typeof x==='string'&&x.length<=40&&Number.isFinite(Date.parse(x))?x:null;
  const observations=value.observations.filter(o=>o&&['softr_amap_cost','amap_business_cost'].includes(o.source)&&Number.isFinite(o.value)&&o.value>0).map(o=>({source:o.source,value:o.value,sourceFetchedAt:date(o.sourceFetchedAt),retrievedAt:date(o.retrievedAt)}));
  const amounts=[...new Set(observations.map(o=>o.value))];
  if(!observations.length||observations.length!==value.observations.length||value.status==='available'&&(amounts.length!==1||amounts[0]!==value.value)||value.status==='conflict'&&(amounts.length<2||value.value!==null))return missing();
  return {id:value.id,status:value.status,value:value.status==='available'?value.value:null,currency:typeof value.currency==='string'&&/^[A-Z]{3}$/.test(value.currency)?value.currency:null,observations,verifiedBudgetRange:false};
 }
 function briefConsumptionReference(value){
  const ref=normalizeConsumptionReference(value);
  if(ref.status==='missing')return {status:'missing'};
  return {id:ref.id,status:ref.status,value:ref.value,currency:ref.currency,...(ref.status==='conflict'?{observations:ref.observations}: {source:ref.observations[0].source})};
 }
 function normalizeStoreContent(value){
  const text=x=>typeof x==='string'&&x.trim()?x.trim():null,date=x=>typeof x==='string'&&Number.isFinite(Date.parse(x))?x:null;
  if(!value||typeof value!=='object'||Array.isArray(value)||value.status!=='published'||!text(value.text)||!['listed_type_and_tags','merchant_content','operator_content'].includes(value.basis)||!['softr','local_curated'].includes(value.origin)||!date(value.updatedAt)||!value.source||typeof value.source!=='object'||!text(value.source.label))return null;
  let url;try{url=new URL(value.source.url);if(!['http:','https:'].includes(url.protocol)||url.username||url.password)return null;}catch{return null;}
  if(value.source.observedAt!=null&&!date(value.source.observedAt))return null;
  return {text:text(value.text),status:'published',basis:value.basis,origin:value.origin,updatedAt:value.updatedAt,source:{label:text(value.source.label),url:url.href,observedAt:value.source.observedAt??null}};
 }
 function normalizeListedHours(value){
  if(!value||typeof value!=='object'||Array.isArray(value)||!['parsed','unknown'].includes(value.status)||value.basis!=='listed_hours'||value.liveVerified!==false||value.timeZone!=='Asia/Shanghai'||value.weekdayConvention!=='ISO-8601')return null;
  const hours=typeof value.hours==='string'?value.hours:null,displayHours=typeof value.displayHours==='string'&&value.displayHours.trim()?value.displayHours:null;
  const base={status:value.status,hours,timeZone:value.timeZone,weekdayConvention:value.weekdayConvention,displayHours,basis:'listed_hours',liveVerified:false};
  if(value.source&&typeof value.source.label==='string'&&value.source.label.trim()){
   try{
    const url=new URL(value.source.url);
    if(['http:','https:'].includes(url.protocol)&&!url.username&&!url.password)base.source={label:value.source.label.trim(),url:url.href,...(typeof value.source.checkedOn==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(value.source.checkedOn)?{checkedOn:value.source.checkedOn}:{})};
   }catch{}
  }
  if(value.status==='unknown')return value.reason==='conflicting_sources'?{...base,reason:value.reason}:base;
  const clock=x=>typeof x==='string'&&/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(x);
  const valid=period=>period&&typeof period==='object'&&!Array.isArray(period)&&Array.isArray(period.weekdays)&&period.weekdays.length>0&&period.weekdays.every(day=>Number.isInteger(day)&&day>=1&&day<=7)&&new Set(period.weekdays).size===period.weekdays.length&&clock(period.start)&&clock(period.end)&&[0,1].includes(period.endDayOffset)&&typeof period.allDay==='boolean'&&(!period.allDay||period.start==='00:00'&&period.end==='00:00'&&period.endDayOffset===1);
  if(!displayHours||!Array.isArray(value.schedule)||!value.schedule.length||!value.schedule.every(valid))return {...base,status:'unknown',displayHours:null};
  return {...base,schedule:value.schedule.map(period=>({weekdays:[...period.weekdays],start:period.start,end:period.end,endDayOffset:period.endDayOffset,allDay:period.allDay}))};
 }
 function hoursLabel(store,language='en'){
  const listed=normalizeListedHours(store?.listedHours);
  if(language!=='zh'&&listed?.displayHours)return listed.displayHours;
  if(listed?.status!=='parsed')return store?.hours||listed?.hours||null;
  const dayName=['','周一','周二','周三','周四','周五','周六','周日'];
  const daysLabel=weekdays=>{
   const days=[...weekdays].sort((a,b)=>a-b);
   if(days.length===7)return '每日';
   if(days.length>1&&days.every((day,index)=>index===0||day===days[index-1]+1))return `${dayName[days[0]]}至${dayName[days.at(-1)]}`;
   return days.map(day=>dayName[day]).join('、');
  };
  return listed.schedule.map(period=>`${daysLabel(period.weekdays)} ${period.allDay?'全天营业':`${period.start}–${period.endDayOffset===1?'次日':''}${period.end}`}`).join('；');
 }
 function normalizeRecord(record,options={}){
  if(!record||typeof record.id!=='string'||!record.id)throw Error('A catalogue record needs an ID.');
  const fields=record.fields||{},lookup=new Map(Object.entries(fields).map(([k,v])=>[key(k),v]));
  const get=name=>lookup.get(key(name));
  const text=name=>values(get(name)).map(String).join(', ').trim();
  const number=name=>{const raw=values(get(name))[0];return raw!==undefined&&raw!==null&&String(raw).trim()!==''&&Number.isFinite(Number(raw))&&Number(raw)>=0?Number(raw):null;};
  const tags=[...new Set(['Category','Tags','Cuisine','AmapType'].flatMap(name=>values(get(name))).flatMap(v=>String(v).split(/[,，;；|]/)).map(v=>v.trim()).filter(Boolean))];
  const amapType=text('AmapType'),rawCategory=text('Category'),explicit=text('EntityType').toLowerCase();
  function classify(value){
   if(/厕所|卫生间|洗手间|公共设施|母婴室|停车场|电梯|扶梯|公共座位|休息区|\b(?:facility|facilities|restroom|toilet|parking|elevator|escalator|rest area|public seating)\b/i.test(value))return 'facility';
   if(/影城|影院|电影院|娱乐|运动场馆|儿童乐园|\b(?:entertainment|cinema|movie theater|arcade|playground|fitness)\b/i.test(value))return 'entertainment';
   if(/咖啡|茶饮|奶茶|甜品|\b(?:cafe|café|coffee|drink|drinks|dessert|tea)\b/i.test(value))return 'drink';
   if(/餐饮|餐厅|餐馆|饭店|\b(?:food|restaurant|dining)\b/i.test(value))return 'food';
   if(/购物|零售|服装|书店|数码|\b(?:shops?|shopping|retail|clothing|fashion|bookstore|electronics)\b/i.test(value))return 'retail';
   return null;
  }
  const evidence=types.includes(explicit)&&explicit!=='unknown'?'EntityType':classify(amapType)?'AmapType':classify(rawCategory)?'Category':classify(tags.join(' '))?'Tags':null;
  const entityType=evidence==='EntityType'?explicit:evidence==='AmapType'?classify(amapType):evidence==='Category'?classify(rawCategory):evidence==='Tags'?classify(tags.join(' ')):'unknown';
  const min=number('Pricemin'),max=number('Pricemax'),priceKnown=min!==null&&max!==null&&min<=max;
  const media=options.allFromFields||root.MallMateStoreMedia?.allFromFields||(typeof module!=='undefined'&&module.exports?require('./store-media.js').allFromFields:()=>[]);
  const amapPoiId=text('AmapPoiId'),catalogue=options.photoCatalogue||root.MallMatePhotoCatalogue||{},known=catalogue[amapPoiId];
  let photos=media(fields);if(!photos.length&&known&&get('PhotoEvidenceStatus')!=='unverified')photos=(Array.isArray(known.photos)?known.photos:[]).flatMap(photo=>media({Photos:[photo],PhotoSource:photo?.source||known.source})).slice(0,12);
  const selection=options.photoSelection||root.MallMatePhotoSelection||{};
  const rejected=selection[amapPoiId]?.rejectedUrls;if(Array.isArray(rejected)&&rejected.length)photos=photos.filter(p=>!rejected.includes(p.url));
  const cover=photos.find(p=>p.url===selection[amapPoiId]?.coverUrl);
  if(cover)photos=[cover,...photos.filter(p=>p!==cover)];
  const quietRaw=values(get('Quiet'))[0],walk=number('Walkminutes'),mallPoiId=text('MallPoiId');
  return {id:record.id,name:text('Name')||'Unnamed place',nameEn:text('NameEn')||null,entityType,entityEvidence:evidence,category:({food:'food',drink:'cafe',retail:'shops',entertainment:'shops',facility:'shops',unknown:'all'})[entityType],
   rawCategory,amapType,tags,min:priceKnown?min:null,max:priceKnown?max:null,priceKnown,consumptionReference:normalizeConsumptionReference(get('ConsumptionReference')),content:normalizeStoreContent(get('StoreContent')),reviewHighlights:get('ReviewHighlights')||null,featuredDishes:get('FeaturedDishes')||null,storeEvents:get('StoreEvents')||null,minutes:walk,walkMinutesKnown:walk!==null,quiet:typeof quietRaw==='boolean'?quietRaw:null,quietKnown:typeof quietRaw==='boolean',
   mallId:text('MallId')||mallPoiId,mallPoiId,MallPoiId:mallPoiId,amapPoiId,floor:text('Floor')||text('AmapFloor')||null,amapFloor:text('AmapFloor')||null,buildingId:text('AmapIndoorPid')||text('BuildingId')||null,mallName:text('MallName')||null,address:text('Address')||null,
   hours:text('Hours')||text('AmapHours')||null,listedHours:normalizeListedHours(get('ListedHours')),photos,photo:photos[0]||null};
 }
 function legacyForAR(store,index=0){
  const positions=[[265,120],[85,100],[265,265],[85,265],[265,370]],i=Number.isInteger(index)&&index>=0?index:0;
  return {...store,category:['cafe','food','shops'].includes(store.category)?store.category:'shops',pos:[...positions[i%positions.length]],simulatedPosition:true};
 }
 const api={normalizeRecord,legacyForAR,normalizeConsumptionReference,briefConsumptionReference,normalizeStoreContent,normalizeListedHours,hoursLabel};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateStoreAdapter=api;
})(typeof window!=='undefined'?window:globalThis);
