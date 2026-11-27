// Shopper page views. No API calls, mutable visit state or route computation.
(function(root){
'use strict';
const UI=typeof module!=='undefined'&&module.exports?require('./discovery-ui.js'):root.MallMateDiscoveryUI;
const Gallery=typeof module!=='undefined'&&module.exports?require('./store-gallery.js'):root.MallMateGallery;
const Adapter=typeof module!=='undefined'&&module.exports?require('../shared/store-adapter.js'):root.MallMateStoreAdapter;
const h=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function directory({items,query,facet,nameOf}){
 const facets=[['all','All'],['retail','Shopping'],['entertainment','Things to do'],['food','Food'],['drink','Drinks']];
 return `<section class="directory-page"><form id="search-form" class="directory-search"><label class="sr-only" for="store-search">Search stores and activities</label><input id="store-search" name="query" type="search" maxlength="80" value="${h(query)}" placeholder="Search stores and activities"><button type="submit" class="icon-button" aria-label="Search">${UI.icon('arrow')}</button></form><div class="directory-facets" aria-label="Store categories">${facets.map(([id,label])=>`<button class="pill ${id===facet?'active':''}" data-directory-facet="${id}" aria-pressed="${id===facet}">${label}</button>`).join('')}</div><section class="directory-grid" aria-label="Stores">${items.length?items.map(s=>UI.card(s,{name:nameOf(s)})).join(''):'<p class="empty">No stores found. Try another name.</p>'}</section></section>`;
}
function unavailable(){return `<h1>Store unavailable</h1><button class="primary" data-go="browse">Browse stores</button>`;}
function itemPhoto(dish){
 const local=dish?.image;
 if(typeof local==='string'&&/^\/assets\/featured-dishes\/[a-zA-Z0-9_-]+\.webp$/.test(local))return local;
 try{
  const url=new URL(dish?.imageUrl,root.location?.origin||'https://mallmate.pages.dev');
  if(url.origin==='https://mallmate.pages.dev'&&/^\/assets\/uploads\//.test(url.pathname))return url.href;
  if(url.origin===(root.location?.origin||'https://mallmate.pages.dev')&&/^\/assets\/(?:featured-dishes|store-photo-sources)\//.test(url.pathname))return url.pathname;
  return '';
 }catch{return '';}
}
function featuredDishes(data,language){
 const dishes=Array.isArray(data?.items)?data.items.map(dish=>({name:dish?.[language],photo:itemPhoto(dish)})).filter(dish=>dish.name?.trim()&&dish.photo):[];
 if(!dishes.length)return '';
 const title=language==='zh'?'特色菜':'Featured dishes';
 return `<section class="detail-featured-dishes" aria-labelledby="detail-featured-heading" data-no-localize><h2 id="detail-featured-heading">${title}</h2><ul>${dishes.map(dish=>`<li><img ${root.MallMatePhotoDisplay?.attributes(dish.photo,'dish')||`src="${h(dish.photo)}"`} alt="" loading="lazy" decoding="async" width="640" height="480"><p>${h(dish.name)}</p></li>`).join('')}</ul></section>`;
}
function storeEvents(data,language){
 const events=Array.isArray(data?.items)?data.items.filter(item=>item?.[language]?.trim()):[];
 if(!events.length)return '';
 return `<section class="detail-featured-dishes" aria-labelledby="detail-events-heading" data-no-localize><h2 id="detail-events-heading">${language==='zh'?'店内活动':'Store events'}</h2><ul>${events.map(item=>`<li><p>${h(item[language])}</p></li>`).join('')}</ul></section>`;
}
function bindFeaturedPhotos(doc){
 const section=doc.querySelector('[aria-labelledby=detail-featured-heading]');
 for(const image of section?.querySelectorAll('img')||[]){
  const fail=()=>{image.closest('li')?.remove();if(!section.querySelector('li'))section.remove();};
  root.MallMatePhotoDisplay?.watch(image,fail);
 }
}
function createPhotoTint(doc){
 const size=24,canvas=doc.createElement('canvas'),samples=new WeakMap();
 canvas.width=canvas.height=size;
 const context=canvas.getContext('2d',{willReadFrequently:true});
 return (image,offset)=>{
  if(!context||!image?.naturalWidth||image.hidden||!image.clientWidth||!image.clientHeight)return null;
  const source=image.currentSrc||image.src;
  let sample=samples.get(image);
  if(sample?.source!==source){
   let pixels=null;
   try{
    context.clearRect(0,0,size,size);
    context.drawImage(image,0,0,size,size);
    pixels=context.getImageData(0,0,size,size).data;
   }catch{
    // Reset the canvas after a cross-origin fallback so other photos still work.
    canvas.width=size;
   }
   sample={source,pixels};samples.set(image,sample);
  }
  const pixels=sample.pixels;
  if(!pixels)return null;
  const width=image.clientWidth,height=image.clientHeight;
  const scale=Math.max(width/image.naturalWidth,height/image.naturalHeight);
  const fullWidth=image.naturalWidth*scale,fullHeight=image.naturalHeight*scale;
  const insetX=(fullWidth-width)/2,insetY=(fullHeight-height)/2;
  const from=Math.max(0,Math.floor(insetX/fullWidth*size)),to=Math.min(size,Math.ceil((insetX+width)/fullWidth*size));
  const row=Math.max(0,Math.min(size-1,(insetY+offset)/fullHeight*size-.5));
  const lower=Math.floor(row),upper=Math.min(size-1,lower+1),blend=row-lower;
  const sum=[0,0,0];let weight=0;
  for(const [y,fraction] of [[lower,1-blend],[upper,blend]]){
   for(let x=from;x<to;x++){
    const at=(y*size+x)*4,alpha=fraction*pixels[at+3]/255;
    for(let channel=0;channel<3;channel++)sum[channel]+=alpha*pixels[at+channel];
    weight+=alpha;
   }
  }
  return weight?sum.map(value=>Math.round(value/weight)):null;
 };
}
function bindDetailSafeEdge(doc){
 const edge=doc.querySelector('#app .phone.no-bottom-nav .store-hero-safe-edge');
 const screen=edge?.closest('.screen');
 const view=doc.defaultView;
 if(!screen||!view)return;
 const media=view.matchMedia('(max-width:750px) and (orientation:portrait)');
 const hero=edge.parentElement;
 const app=hero.closest('#app');
 const detail=hero.parentElement;
 const content=detail.querySelector('.store-detail-content');
 const gallery=hero.querySelector('.gallery-track');
 const images=[...gallery.querySelectorAll('img')];
 const samplePhoto=createPhotoTint(doc);
 let frame=0,revealDistance=0;
 const update=()=>{
  frame=0;
  if(!media.matches)return;
  edge.toggleAttribute('data-article-scrolled',view.scrollY>=revealDistance);
  const overlap=hero.offsetHeight-content.offsetTop;
  const distance=content.offsetTop-view.scrollY-edge.offsetHeight;
  const fade=Math.max(0,Math.min(1,1-distance/Math.max(1,overlap)));
  const position=gallery.scrollLeft/Math.max(1,gallery.clientWidth);
  const index=Math.max(0,Math.min(images.length-1,Math.floor(position)));
  const offset=view.scrollY+edge.offsetHeight;
  const mix=Math.max(0,Math.min(1,position-index));
  const active=samplePhoto(images[index],offset);
  const next=mix>0?samplePhoto(images[index+1],offset):null;
  const photo=active&&next?active.map((value,channel)=>Math.round(value+(next[channel]-value)*mix)):active||next||[255,255,255];
  edge.style.setProperty('--store-photo-color',`rgb(${photo.join(' ')})`);
  edge.style.setProperty('--store-edge-progress',100*fade+'%');
  const adjusted=photo.map(value=>(value+(255-value)*fade)/255);
  const luminance=adjusted.map(value=>value<=.04045?value/12.92:((value+.055)/1.055)**2.4);
  detail.toggleAttribute('data-store-edge-light',.2126*luminance[0]+.7152*luminance[1]+.0722*luminance[2]>.179);
 };
 const schedule=()=>{if(!frame)frame=view.requestAnimationFrame(update);};
 const observer=view.IntersectionObserver?new view.IntersectionObserver(([entry])=>{if(!media.matches)edge.hidden=!entry.isIntersecting;},{root:screen}):null;
 observer?.observe(hero.querySelector('.back-link'));
 function refresh(){
  if(media.matches){
   if(edge.parentElement!==app)app.append(edge);
   edge.hidden=false;
   const blendHeight=parseFloat(view.getComputedStyle(edge,'::after').height)||0;
   revealDistance=edge.offsetHeight+blendHeight;
   update();
  }else if(edge.parentElement===app)hero.append(edge);
 }
 refresh();
 view.addEventListener('scroll',schedule,{passive:true});
 view.addEventListener('resize',refresh);
 gallery.addEventListener('scroll',schedule,{passive:true});
 gallery.addEventListener('load',schedule,true);
 gallery.addEventListener('error',schedule,true);
 media.addEventListener('change',refresh);
 return ()=>{
  observer?.disconnect();view.cancelAnimationFrame(frame);
  view.removeEventListener('scroll',schedule);view.removeEventListener('resize',refresh);media.removeEventListener('change',refresh);
  gallery.removeEventListener('scroll',schedule);gallery.removeEventListener('load',schedule,true);gallery.removeEventListener('error',schedule,true);
  if(edge.parentElement===app)edge.remove();
 };
}
function mapRouteLink(store,language,destination){
 if(!destination||!store?.id||!root.location||!['https:','http:'].includes(root.location.protocol))return '';
 const current=new URL(root.location.href);
 let target;try{target=new URL(destination);}catch{return '';}
 if(target.username||target.password)return '';
 if(target.protocol==='https:'||(current.protocol==='http:'&&target.protocol==='http:'))return target.href;
 if(target.protocol!=='mallmate-route:'||target.port)return '';
 if(target.hostname==='practice'&&['','/'].includes(target.pathname)){
  const library=new URL('mallmate-route://practice');
  library.searchParams.set('lang',language);
  return library.href;
 }
 if(target.hostname!=='route'||
   !/^\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(target.pathname))return '';
 const back=new URL('/',current);
 back.searchParams.set('screen','map');
 back.searchParams.set('store',store.id);
 back.searchParams.set('lang',language);
 if(current.searchParams.get('nav')==='on')back.searchParams.set('nav','on');
 target.search='';
 target.hash='';
 target.searchParams.set('lang',language);
 target.searchParams.set('return',back.href);
 return target.href;
}
function detail({store,name,source,reason=''}){
 if(!store)return unavailable();
 const photos=store.photos||[];
 const language=root.MallMateUILanguage?.language()||'en';
 const actions='<div class="detail-actions"><button class="primary" data-show-location>View store location</button></div>';
 const hours=Adapter.hoursLabel(store,language);
 const review=root.MallMateStoreReviewHighlights;
 const rating=review?.summary(store.reviewHighlights,language)||'';
 const comments=review?.section(store.reviewHighlights,language,{dining:store.category!=='shops'})||'';
 const dishes=featuredDishes(store.featuredDishes,language);
 return `<article class="store-detail${rating||comments?' has-review-highlights':''}" aria-labelledby="store-detail-title"><div class="store-hero ${photos.length?'has-photos':'no-photos'}"><button class="link back-link" data-store-back data-go="${source==='chat'?'chat':'browse'}" aria-label="Back">${UI.icon('back')}</button>${photos.length?'<div class="store-hero-safe-edge" aria-hidden="true"></div>':''}${Gallery.markup(photos)}</div><div class="store-detail-content"><h1 id="store-detail-title" data-no-localize translate="no">${h(name)}</h1>${reason?`<p class="detail-reason" data-no-localize translate="no">${h(reason)}</p>`:''}<div class="detail-facts">${store.floor?`<span>${h(store.floor)}</span>`:''}${store.priceKnown?`<span>RMB ${store.min}-${store.max}</span>`:''}${hours?`<span data-no-localize translate="no">${h(hours)}</span>`:''}</div>${rating}${dishes}${storeEvents(store.storeEvents,language)}${comments}${actions}</div></article>`;
}
function location({store,markup,navigationDestination,navigationDestinations}){
 const language=root.MallMateUILanguage?.language()||'en';
 const destination=store?.id&&Object.hasOwn(navigationDestinations??{},store.id)
  ?navigationDestinations[store.id]:navigationDestination;
 const route=mapRouteLink(store,language,destination);
 const betaMessage=language==='zh'
  ?'AR 导航目前为内测功能。若未打开，请联系开发者。'
  :'AR navigation is in beta. If the app doesn’t open, contact the developer.';
 const opensLibrary=route.startsWith('mallmate-route://practice?');
 const label=opensLibrary?(language==='zh'?'打开 RouteWalk':'Open RouteWalk'):(language==='zh'?'去这里':'Go here');
 const action=route?`<footer class="indoor-route-actions"><p class="indoor-route-status" role="status" data-no-localize data-map-navigation-status data-message="${h(betaMessage)}"></p><a class="primary" data-no-localize data-map-navigation href="${h(route)}">${label}</a></footer>`:'';
 return `<section class="indoor-page" aria-label="Mall map">${store?`<button class="link indoor-back back-link" data-store-back data-go="detail" aria-label="Store details">${UI.icon('back')}</button>`:''}<div id="indoor-map-host">${markup}</div>${action}<span class="indoor-viewport-edge top" aria-hidden="true"></span><span class="indoor-viewport-edge bottom" aria-hidden="true"></span></section>`;
}

const api={directory,detail,location,unavailable,bindFeaturedPhotos,bindDetailSafeEdge};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateShopperPages=api;
})(typeof window!=='undefined'?window:globalThis);
