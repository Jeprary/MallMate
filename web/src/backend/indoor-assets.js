// Production-only, revision-bound indoor-map bundle. No research-directory dependency.
'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const ROOT=path.resolve(__dirname,'../../assets/indoor-map');
const load=file=>JSON.parse(fs.readFileSync(file,'utf8'));
function scene(floor,root=ROOT){
 if(![1,2,3].includes(floor))throw Error('Invalid floor.');
 const bundle=load(path.join(root,'manifest.json')),entry=bundle.floors.find(f=>f.floor===floor);
 if(!entry?.ready)throw Error('Floor unavailable.');
 const data=load(path.join(root,`${floor}.json`));
 if(data.floor!==floor||data.source_model_revision!==entry.revision)throw Error('Floor revision mismatch.');
 const version=crypto.createHash('sha256').update(JSON.stringify(data)).digest('hex');
 if(version!==entry.assetVersion)throw Error('Floor checksum mismatch.');
 return data;
}
function manifest(root=ROOT){
 const bundle=load(path.join(root,'manifest.json')),rooms=new Map();
 const floors=[1,2,3].map(floor=>{
  try{const data=scene(floor,root),entry=bundle.floors.find(f=>f.floor===floor);rooms.set(floor,new Set(data.rooms.map(r=>r.id)));return {floor,ready:true,revision:entry.revision,assetVersion:entry.assetVersion};}
  catch{return {floor,ready:false};}
 });
 const bindings=(bundle.bindings||[]).filter(p=>rooms.get(p.floor)?.has(p.regionId)).map(p=>({floor:p.floor,regionId:p.regionId,name:p.name,point:p.point,poiId:p.poiId||null,csvName:p.csvName||null}));
 return {buildingId:bundle.buildingId,name:bundle.name,floors,bindings};
}
module.exports={manifest,scene};
