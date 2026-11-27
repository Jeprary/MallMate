// Public welcome and dish artwork. Only paths in the reviewed release catalogue are served.
'use strict';
const fs=require('node:fs'),path=require('node:path');
const URL_PATH='/assets/arrival/wanda-day.jpg';
const dishes=require('../../assets/store-featured-dishes.json');
const supplementalPhotos=require('../../assets/store-photo-supplement.json');
const mirroredPhotos=require('../../assets/store-photo-sources/catalogue.json');
const sourcePrefix='/assets/store-photo-sources/';
const publishedSite='https://mallmate.pages.dev';
const imageTypes={jpg:'image/jpeg',png:'image/png',webp:'image/webp',gif:'image/gif'};
const variantPath='/assets/optimized-photos/';
const manifestPath=variantPath+'manifest.js';
const variants=require('../../assets/optimized-photos/manifest.js');
const files=new Map([[URL_PATH,'image/jpeg'],[manifestPath,'text/javascript; charset=utf-8']]);
for(const version of Object.values(variants)){
 for(const [name] of version)files.set(variantPath+name,'image/webp');
}
for(const file of Object.values(mirroredPhotos)){
 const extension=file.split('.').at(-1);
 if(/^[a-f0-9]{64}\.(jpg|png|webp|gif)$/.test(file))files.set(sourcePrefix+file,imageTypes[extension]);
}
for(const photo of Object.values(supplementalPhotos)){
 if(/^\/assets\/store-photo-sources\/[a-z0-9-]+\.webp$/.test(photo.url))files.set(photo.url,'image/webp');
}
for(const stores of Object.values(dishes)){
 for(const store of Object.values(stores)){
  for(const item of store.items){
   if(/^\/assets\/featured-dishes\/[A-Za-z0-9_-]+\.webp$/.test(item.image))files.set(item.image,'image/webp');
  }
 }
}
const includes=pathname=>files.has(pathname);
function sameSitePhoto(url){
 if(typeof url!=='string')return '';
 if(Object.hasOwn(mirroredPhotos,url))return publishedSite+sourcePrefix+mirroredPhotos[url];
 if(includes(url)&&url!==manifestPath)return publishedSite+url;
 if(url.startsWith(publishedSite+'/assets/')&&includes(url.slice(publishedSite.length))&&!url.endsWith(manifestPath))return url;
 if(/^https:\/\/mallmate\.pages\.dev\/assets\/uploads\/[A-Za-z0-9._-]+\.(jpg|png|webp|gif)$/.test(url))return url;
 return '';
}
function create({root=path.resolve(__dirname,'../..')}={}){
 return function handle(req,res,url){
  const contentType=files.get(url.pathname);
  if(!contentType)return false;
  const file=path.join(root,url.pathname.slice(1));
  if(!['GET','HEAD'].includes(req.method)){req.resume();res.writeHead(405,{'Allow':'GET, HEAD','Content-Type':'application/json','X-Content-Type-Options':'nosniff'});res.end('{"error":"Read-only artwork"}');return true;}
  if(url.pathname!==manifestPath){
   res.writeHead(302,{'Location':publishedSite+url.pathname,'Cache-Control':'no-store'});
   res.end();return true;
  }
  let stat;
  try{stat=fs.statSync(file);}
  catch{
   res.writeHead(404,{'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
   res.end('{"error":"Artwork unavailable"}');
   return true;
  }
  res.writeHead(200,{'Content-Type':contentType,'Content-Length':stat.size,
   'Cache-Control':url.pathname===manifestPath?'public, max-age=300':'public, max-age=3600',
   'X-Content-Type-Options':'nosniff'});
  if(req.method==='HEAD')res.end();
  else{
   const image=fs.createReadStream(file);
   image.on('error',()=>res.destroy());
   res.once('close',()=>image.destroy());
   image.pipe(res);
  }
  return true;
 };
}
module.exports={create,URL_PATH,includes,sameSitePhoto};
