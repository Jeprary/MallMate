'use strict';
const crypto=require('node:crypto'),Adapter=require('../shared/store-adapter');
const ordered=value=>Array.isArray(value)?value.map(ordered):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,ordered(value[k])])):value;
const digest=value=>crypto.createHash('sha256').update(JSON.stringify(ordered(value))).digest('hex');
function evidenceId(storeId,amapPoiId,reference){return 'cost-'+digest({storeId,amapPoiId,...reference}).slice(0,24);}
function merge(base,snapshot){
 if(!base||!Array.isArray(base.records)||snapshot?.schemaVersion!==1||snapshot.baseCatalogueVersion!==base.catalogueVersion||!Array.isArray(snapshot.records)||snapshot.records.length!==base.records.length||typeof snapshot.sourceReadAt!=='string'||!Number.isFinite(Date.parse(snapshot.sourceReadAt)))throw Error('Consumption reference catalogue scope/version mismatch');
 const originals=new Map(base.records.map(r=>[r.id,r])),seen=new Set(),byId=new Map(),counts={available:0,conflict:0,missing:0};
 for(const row of snapshot.records){
  const original=originals.get(row?.storeId),raw=row?.consumptionReference;
  if(!original||seen.has(row.storeId)||row.amapPoiId!==original.fields?.AmapPoiId||Object.keys(row).some(k=>!['storeId','amapPoiId','consumptionReference'].includes(k)))throw Error('Invalid consumption reference identity');
  seen.add(row.storeId);let ref;
  if(raw?.status==='missing'){
   if(Object.keys(raw).some(k=>k!=='status'))throw Error('Invalid missing consumption reference');
   ref=Adapter.normalizeConsumptionReference(null);
  }else{
   ref=Adapter.normalizeConsumptionReference(raw);
   if(ref.status==='missing'||digest(raw)!==digest(ref))throw Error('Invalid consumption reference facts');
   const {id,...facts}=ref;
   if(id!==evidenceId(row.storeId,row.amapPoiId,facts))throw Error('Invalid consumption reference evidence identity');
  }
  counts[ref.status]++;byId.set(row.storeId,ref);
 }
 const localDates=[...new Set([...byId.values()].flatMap(r=>r.observations.filter(o=>o.source==='amap_business_cost').map(o=>o.sourceFetchedAt)).filter(Boolean))];
 const records=base.records.map(r=>({...r,fields:{...r.fields,ConsumptionReference:byId.get(r.id)}}));
 return {...base,records,source:(base.source||'snapshot')+'+consumption-reference',catalogueVersion:'snapshot-'+digest({baseCatalogueVersion:base.catalogueVersion,records:snapshot.records}),consumptionReference:{baseCatalogueVersion:base.catalogueVersion,sourceReadAt:snapshot.sourceReadAt,statusCounts:counts,referenceCount:counts.available+counts.conflict,sources:{softr_amap_cost:{field:'Softr Stores.AmapCost',retrievedAt:snapshot.sourceReadAt,sourceFetchedAt:null},amap_business_cost:{field:'AMap business.cost',sourceFetchedAt:localDates.length===1?localDates[0]:null}},meaning:'Reference consumption values only, not verified per-person/meal pricing or a min/max budget guarantee. Currency and unknown source dates remain unknown. Conflicting values are not a range or a selected current price.'}};
}
module.exports={merge,evidenceId};
