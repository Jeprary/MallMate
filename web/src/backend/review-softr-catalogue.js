'use strict';

const {createHash}=require('node:crypto');
const textFields=['Name','NameEn','Floor','Category','Hours','AmapHours','Address'];
const numberFields=['Pricemin','Pricemax'];
const keyFor=fields=>JSON.stringify([fields.MallPoiId,fields.AmapPoiId]);

function overlay(snapshot, cloudRows) {
  const index=new Map();
  for(const row of cloudRows){
    const fields=row?.fields;
    if(!fields||fields.MallPoiId!==snapshot.mallId)continue;
    const key=keyFor(fields);
    if(index.has(key))throw Error('Duplicate MallPoiId and AmapPoiId in Softr.');
    index.set(key,fields);
  }

  const records=snapshot.records.map(record=>{
    const imported=index.get(keyFor(record.fields));
    if(!imported)throw Error('The Softr table is missing a published store.');
    const fields={...record.fields};
    for(const name of textFields){
      const value=imported[name];
      if(typeof value==='string'&&value.trim())fields[name]=value.trim();
    }
    for(const name of numberFields){
      const value=imported[name];
      if(typeof value==='number'&&Number.isFinite(value)&&value>=0)fields[name]=value;
    }
    return {...record,fields};
  });

  return {...snapshot,records,source:'softr-review+production-public-snapshot',
    catalogueVersion:createHash('sha256').update(JSON.stringify(records)).digest('hex')};
}

module.exports={overlay};
