'use strict';
const crypto=require('node:crypto'),Adapter=require('../shared/store-adapter'),Reference=require('./consumption-reference'),Content=require('./store-content');
const Media=require('../shared/store-media');
const hash=value=>crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const date=value=>typeof value==='string'&&Number.isFinite(Date.parse(value))?value:null;
const isDemo=row=>row.fields?.Isdemo===true||/^demo\b/i.test(String(row.fields?.Name||''));
// This release publishes the verified directory, not every POI imported into Stores.
// Keep its stable IDs for map, cards, saved reviews and consumption evidence.
function merge(base,cloud,{retrievedAt}={}){
 if(!base?.mallId||!Array.isArray(base.records)||!Array.isArray(cloud)||!date(retrievedAt))throw Error('Invalid published Softr catalogue.');
 const byPoi=new Map();
 for(const row of cloud){
  if(!row||isDemo(row)||row.fields?.MallPoiId!==base.mallId)continue;
  const poi=row.fields?.AmapPoiId;if(typeof poi!=='string'||!poi)continue;
  const rows=byPoi.get(poi)||[];rows.push(row);byPoi.set(poi,rows);
 }
 const links=[],counts={available:0,conflict:0,missing:0},seen=new Set();
 const records=base.records.map(local=>{
  const poi=local.fields?.AmapPoiId;
  if(!poi||seen.has(poi)||local.fields?.MallPoiId!==base.mallId)throw Error('Invalid published store identity.');
  seen.add(poi);const matches=byPoi.get(poi)||[];
  if(matches.length!==1)throw Error(`Published Softr store ${local.id} has ${matches.length} matching records.`);
  const row=matches[0],f=row.fields;
  if(typeof row.id!=='string'||!row.id||typeof f.Name!=='string'||!f.Name.trim())throw Error('Invalid Softr store identity or name.');
  links.push({storeId:local.id,softrRecordId:row.id,amapPoiId:poi});
  const fields={...local.fields};
  const photo=typeof f.PhotoUrl==='string'&&f.PhotoUrl.startsWith('https://')
   ? Media.fromFields({PhotoUrl:f.PhotoUrl}) :null;
  if(photo){
   fields.Photos=[{url:photo.url},...Media.allFromFields(local.fields).filter(item=>item.url!==photo.url)];
   fields.PhotoUrl=photo.url;
   delete fields.PhotoTitle;
   delete fields.PhotoSource;
  }
  const content=Content.forStore(local,f);if(content)fields.StoreContent=content;else delete fields.StoreContent;
  // Raw imported Quiet/Walkminutes values are not verified preference facts.
  // Classification and editorial tags remain one verified local group until a
  // cloud publishing schema can maintain them together, rather than mix types.
  for(const key of ['Name','Address','MallName','Hours','AmapHours'])if(Object.hasOwn(f,key))fields[key]=f[key];
  // Preserve the independently verified floor/map binding when the import has no floor.
  for(const key of ['Floor','AmapFloor'])if(typeof f[key]==='string'&&f[key].trim())fields[key]=f[key];
  const min=f.Pricemin,max=f.Pricemax,validRange=typeof min==='number'&&typeof max==='number'&&Number.isFinite(min)&&Number.isFinite(max)&&min>=0&&max>=min;
  fields.Pricemin=validRange?min:null;fields.Pricemax=validRange?max:null;
  const prior=Adapter.normalizeConsumptionReference(local.fields.ConsumptionReference);
  const observations=prior.observations.filter(o=>o.source!=='softr_amap_cost');
  if(typeof f.AmapCost==='number'&&Number.isFinite(f.AmapCost)&&f.AmapCost>0)observations.unshift({source:'softr_amap_cost',value:f.AmapCost,sourceFetchedAt:date(f.FetchedAt),retrievedAt});
  let reference;
  if(!observations.length)reference=Adapter.normalizeConsumptionReference(null);
  else{
   const amounts=[...new Set(observations.map(o=>o.value))],facts={status:amounts.length===1?'available':'conflict',value:amounts.length===1?amounts[0]:null,currency:prior.currency,observations,verifiedBudgetRange:false};
   reference={id:Reference.evidenceId(local.id,poi,facts),...facts};
  }
  fields.ConsumptionReference=reference;counts[reference.status]++;
  return {id:local.id,fields};
 });
 const source='softr-published+local-evidence';
 return {...base,records,source,fetchedAt:retrievedAt,catalogueVersion:'softr-published-'+hash({records,links}),
  publication:{mallId:base.mallId,publishedCount:records.length,cloudRecordCount:cloud.length,unpublishedCount:cloud.length-records.length,baseCatalogueVersion:base.catalogueVersion,identity:'MallPoiId+AmapPoiId',fetchedAt:retrievedAt},
  softrLinks:links,
  consumptionReference:{...base.consumptionReference,sourceReadAt:retrievedAt,statusCounts:counts,referenceCount:counts.available+counts.conflict,sources:{...base.consumptionReference?.sources,softr_amap_cost:{field:'Softr Stores.AmapCost',retrievedAt,sourceFetchedAt:null}},meaning:'Reference consumption observations, not a verified per-person price or budget range. Conflicts and missing observations remain explicit.'}};
}
module.exports={merge};
