// Public store photos only. This adapter performs no requests or DNS lookups.
(function(root){
 'use strict';
 const names=['photourl','imageurl','coverimage','photos'];
 const fieldKey=value=>String(value).toLowerCase().replace(/[^a-z]/g,'');
 const text=value=>typeof value==='string'?value.replace(/[\u0000-\u001f\u007f]/g,' ').trim().slice(0,240):'';
 function publicHost(host){
  host=host.toLowerCase().replace(/\.$/,'');
  if(host.startsWith('[')){
   // Only native globally routable IPv6; exclude mapped/translated IPv4,
   // local ranges and special-purpose 2001::/23 space.
   const [first,second]=host.slice(1,-1).split(':').map(x=>parseInt(x||'0',16));
   return first>=0x2000&&first<=0x3fff&&first!==0x2002&&!(first===0x2001&&(second<0x200||second===0xdb8));
  }
  if(/^\d+\.\d+\.\d+\.\d+$/.test(host)){
   const [a,b,c]=host.split('.').map(Number);
   return !(a===0||a===10||a===127||a>=224||(a===100&&b>=64&&b<=127)||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&(b===168||b===0||(b===88&&c===99)))||(a===198&&(b===18||b===19||(b===51&&c===100)))||(a===203&&b===0&&c===113));
  }
  return host.includes('.')&&!/(^|\.)(localhost|localdomain|local|internal|lan|home|test|invalid|example)$/.test(host);
 }
 function safeUrl(value){
  if(typeof value==='string'&&/^\/assets\/store-photo-sources\/(?:[a-f0-9]{64}\.(?:jpg|png|webp|gif)|[a-z0-9-]+\.webp)$/.test(value))return value;
  if(typeof value!=='string'||value.length>4096||/[\u0000-\u0020\u007f\\]/.test(value))return null;
  try{
   const url=new URL(value);
   if(!['http:','https:'].includes(url.protocol)||url.username||url.password||!publicHost(url.hostname))return null;
   // Signed/authenticated image URLs must never become public guest data.
   for(const name of url.searchParams.keys())if(/key|token|secret|password|credential|authorization|signature/.test(fieldKey(name))||/^(auth|sig)$/.test(fieldKey(name)))return null;
   if(url.hash)return null;
   return url.href;
  }catch{return null;}
 }
 function candidate(value,title,depth=0){
  if(depth>3)return null;
  if(typeof value==='string'){const url=safeUrl(value);return url?{url,title}:null;}
  if(Array.isArray(value)){
   for(const item of value.slice(0,30)){const found=candidate(item,title,depth+1);if(found)return found;}
  }else if(value&&typeof value==='object'){
   // Do not propagate attachment IDs, owners, tokens or other metadata.
   const url=safeUrl(value.url);if(url)return {url,title:text(value.title)||title,source:text(value.source)};
  }
  return null;
 }
 function allFromFields(fields){
  if(!fields||typeof fields!=='object'||Array.isArray(fields))return [];
  const normalized=new Map(Object.entries(fields).map(([key,value])=>[fieldKey(key),value]));
  const title=text(normalized.get('phototitle')),source=text(normalized.get('photosource'));
  const result=[],seen=new Set();
  function collect(value,depth=0){
   if(depth>3||result.length>=12)return;
   if(Array.isArray(value)){for(const item of value.slice(0,30))collect(item,depth+1);return;}
   const found=candidate(value,title);if(found&&!seen.has(found.url)){seen.add(found.url);result.push({...found,source:found.source||source});}
  }
  for(const name of names)collect(normalized.get(name));
  return result;
 }
 function fromFields(fields){return allFromFields(fields)[0]||null;}
 const api={fromFields,allFromFields};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateStoreMedia=api;
})(typeof window!=='undefined'?window:globalThis);
