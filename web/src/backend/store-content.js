'use strict';
const crypto=require('node:crypto'),Adapter=require('../shared/store-adapter'),pilot=require('../../assets/store-content.json');
function fromFields(fields){
 if(fields?.ContentPublished!==true)return null;
 let source;try{source=typeof fields.ContentSource==='string'?JSON.parse(fields.ContentSource):null;}catch{return null;}
 return Adapter.normalizeStoreContent({text:fields.ShortSummary,status:'published',basis:source?.basis,origin:'softr',updatedAt:fields.ContentUpdatedAt,source});
}
function forStore(local,fields){
 // Explicit cloud drafts/empty content suppress older local content once its
 // publishing fields exist. A missing schema uses the documented local pilot.
 if(['ShortSummary','ContentSource','ContentUpdatedAt','ContentPublished'].some(key=>Object.hasOwn(fields||{},key)))return fromFields(fields);
 if(pilot.schemaVersion!==1||pilot.mallId!==local.fields?.MallPoiId)return null;
 const row=pilot.records.find(row=>row.storeId===local.id&&row.amapPoiId===local.fields?.AmapPoiId&&row.mallPoiId===local.fields?.MallPoiId);
 return Adapter.normalizeStoreContent(row?.content);
}
function mergeLocal(base){
 if(!base||!Array.isArray(base.records))throw Error('Invalid local content catalogue.');
 let count=0;
 const records=base.records.map(record=>{
  const content=forStore(record,{});if(!content)return record;count++;
  return {...record,fields:{...record.fields,StoreContent:content}};
 });
 if(!count)return base;
 const version=crypto.createHash('sha256').update(JSON.stringify({baseCatalogueVersion:base.catalogueVersion,content:records.filter(r=>r.fields?.StoreContent).map(r=>({id:r.id,content:r.fields.StoreContent}))})).digest('hex');
 return {...base,records,source:(base.source||'snapshot')+'+local-content',catalogueVersion:'snapshot-'+version};
}
module.exports={fromFields,forStore,mergeLocal};
