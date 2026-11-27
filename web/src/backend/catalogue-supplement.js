'use strict';
const crypto=require('node:crypto');
const PUBLIC_FIELDS=new Set(['Name','AmapPoiId','MallPoiId','AmapType','Address','Floor','AmapFloor','AmapHours','Hours','Photos','PhotoSource']);
function merge(base,supplement){
 if(!base||!Array.isArray(base.records)||supplement?.schemaVersion!==1||!Array.isArray(supplement.records)||!base.mallId||supplement.mallId!==base.mallId)throw Error('Invalid catalogue supplement scope');
 const seenIds=new Set(base.records.map(r=>r.id)),seenPois=new Set(base.records.map(r=>r.fields?.AmapPoiId).filter(Boolean)),added=[],provenance=[];
 for(const record of supplement.records){
  const f=record?.fields,p=record?.provenance;
  if(!f||!/^B[A-Z0-9]{8,}$/.test(f.AmapPoiId||'')||record.id!=='amap-'+f.AmapPoiId||f.MallPoiId!==base.mallId||typeof f.Name!=='string'||!f.Name.trim()||Object.keys(f).some(k=>!PUBLIC_FIELDS.has(k)))throw Error('Invalid supplemental store identity or fields');
  if(!p||typeof p.sourceFile!=='string'||!p.sourceFile.trim()||typeof p.jsonPointer!=='string'||!p.jsonPointer.startsWith('/')||typeof p.observedAt!=='string'||!/(?:Z|[+-]\d{2}:\d{2})$/i.test(p.observedAt)||!Number.isFinite(Date.parse(p.observedAt))||!/^[a-f0-9]{64}$/.test(p.sourceSha256||'')||p.currentOperationVerified!==false)throw Error('Missing supplemental store provenance');
  if(seenIds.has(record.id)||seenPois.has(f.AmapPoiId))continue;
  seenIds.add(record.id);seenPois.add(f.AmapPoiId);added.push({id:record.id,fields:structuredClone(f)});provenance.push({storeId:record.id,...structuredClone(p)});
 }
 if(!added.length)return base;
 const hash=crypto.createHash('sha256').update(JSON.stringify({base,added,provenance})).digest('hex');
 return {...base,records:[...base.records,...added],source:(base.source||'snapshot')+'+verified-supplement',catalogueVersion:'snapshot-'+hash,supplement:{addedStoreIds:added.map(r=>r.id),provenance}};
}
module.exports={merge};
