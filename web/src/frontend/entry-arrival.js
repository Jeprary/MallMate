// Ordinary and QR visits share the same welcome screen.
(function(root){
 'use strict';
 const mall=Object.freeze({id:'B02001H9JR',name:'Taicang Wanda Plaza'});
 const seenKey='mallmate-welcome-seen';
 const mounted=new WeakMap();let sequence=0;
 function resolve(value,{seen=false}={}){
  let url;try{url=new URL(value);}catch{return {kind:'invalid'};}
  const entries=url.searchParams.getAll('entry');
  if(!entries.length){
   const home=['/','/index.html'].includes(url.pathname)&&url.searchParams.get('nav')!=='on'&&!url.searchParams.has('screen')&&url.searchParams.get('mode')!=='developer';
   return home&&!seen?{kind:'mall',mall}:{kind:'none'};
  }
  const malls=url.searchParams.getAll('mall');
  if(entries.length!==1||entries[0]!=='qr'||malls.length!==1||malls[0]!==mall.id)return {kind:'invalid'};
  return {kind:'mall',mall};
 }
 function resolveVisit(url){
  let seen=false;try{seen=root.sessionStorage?.getItem(seenKey)==='1';}catch{}
  return resolve(url,{seen});
 }
 function cleanURL(value){const url=new URL(value);url.searchParams.delete('entry');url.searchParams.delete('mall');return url;}
 function markup(kind,id){
  const title=kind==='mall'?'Taicang Wanda':'This mall entrance is unavailable';
  return `${kind==='mall'?`<img class="arrival-photo" ${root.MallMatePhotoDisplay?.attributes('/assets/arrival/wanda-day.jpg','welcome')||'src="/assets/arrival/wanda-day.jpg"'} alt="Taicang Wanda exterior" width="1166" height="874" decoding="async" fetchpriority="high">`:''}<div class="arrival-content">${kind==='mall'?'<p class="arrival-eyebrow">Welcome to</p>':'<div class="arrival-brand">Mall<span>Mate</span></div>'}<h1 id="${id}">${title}</h1>${kind==='mall'?'':'<p class="arrival-error">Scan the mall entrance code again.</p>'}</div><button type="button" class="arrival-enter" data-arrival-enter autofocus>${kind==='mall'?'Enter mall':'Close'}</button>${kind==='mall'?'<span class="arrival-photo-edge" aria-hidden="true"></span>':''}`;
 }
 function mount({url=root.location?.href,onEnter=()=>{},onDismiss=()=>{},document:doc=root.document}={}){
  const invocation=resolveVisit(url);if(invocation.kind==='none'||!doc?.body)return ()=>{};
  if(mounted.has(doc))return mounted.get(doc);
  const dialog=doc.createElement('dialog'),id='arrival-title-'+(++sequence);
  dialog.className='arrival-sheet'+(invocation.kind==='mall'?' arrival-landing arrival-photo-sheet':'');dialog.setAttribute('aria-labelledby',id);dialog.innerHTML=markup(invocation.kind,id);
  doc.body.appendChild(dialog);
  if(typeof dialog.showModal!=='function'){dialog.remove();return ()=>{};}
  const guide=invocation.kind==='mall'?root.MallMateVoiceEntryGuide?.prepare(doc):null;
  if(guide)dialog.setAttribute('data-shared-voice-backdrop','');
  let finished=false,frame=0,motion=null,pointerExit=false;
  function finish(enter,restoreFocus=true,animate=true){
   if(finished)return;finished=true;
   if(animate)motion?.capture(enter&&invocation.kind==='mall',{reuseBackdrop:Boolean(guide)});
   dialog.removeEventListener('cancel',cancel);dialog.removeEventListener('click',backdrop);dialog.removeEventListener('close',closed);
   const close=dialog.querySelector('[data-arrival-close]');if(close)close.onclick=null;dialog.querySelector('[data-arrival-enter]').onclick=null;
   dialog.close();dialog.remove();mounted.delete(doc);
   if(invocation.kind==='mall'&&restoreFocus&&!root.MallMateVoiceEntryGuide?.preview)try{root.sessionStorage?.setItem(seenKey,'1');}catch{}
   try{if(root.location?.href&&root.history){const next=cleanURL(root.location.href);root.history.replaceState(root.history.state,'',next.pathname+next.search+next.hash);}}catch{}
   let entered;
   try{if(enter&&invocation.kind==='mall')entered=onEnter(mall);else onDismiss();}
   finally{
    if(enter&&animate)guide?.handoff();
    else if(animate)guide?.dismiss();
    else guide?.remove();
    const showGuide=()=>{if(enter&&invocation.kind==='mall'&&guide)Promise.resolve(entered).then(guide.show,guide.show);};
    if(animate){
     motion?.reveal();
     showGuide();
    }else motion?.dispose();
    if(restoreFocus)frame=root.requestAnimationFrame?.(()=>{if(mounted.has(doc))return;const button=doc.querySelector('#voice-toggle');if(root.MallMateArrivalMotion?.restoreFocus)root.MallMateArrivalMotion.restoreFocus(button,{pointer:pointerExit});else button?.focus({preventScroll:true});})||0;
   }
  }
  function cancel(event){event.preventDefault();pointerExit=false;finish(false);}
  function closed(){finish(false);}
  function backdrop(event){const box=dialog.getBoundingClientRect();if(event.target===dialog&&(event.clientX<box.left||event.clientX>box.right||event.clientY<box.top||event.clientY>box.bottom)){pointerExit=event.detail>0;finish(false);}}
  const close=dialog.querySelector('[data-arrival-close]');if(close)close.onclick=()=>finish(false);
  dialog.querySelector('[data-arrival-enter]').onclick=event=>{pointerExit=Boolean(event?.detail>0);finish(true);};
  dialog.addEventListener('cancel',cancel);dialog.addEventListener('click',backdrop);dialog.addEventListener('close',closed);
  const dispose=()=>{if(frame)root.cancelAnimationFrame?.(frame);finish(false,false,false);motion?.dispose();};mounted.set(doc,dispose);
  const photo=dialog.querySelector('.arrival-photo');
  if(photo){
   photo.alt=root.MallMateUILanguage?.text?.('Taicang Wanda exterior')||'Taicang Wanda exterior';
   const imageFailed=()=>{photo.remove();dialog.classList.remove('arrival-photo-sheet');};
   if(root.MallMatePhotoDisplay)root.MallMatePhotoDisplay.watch(photo,imageFailed);
   else photo.addEventListener('error',imageFailed,{once:true});
  }
  root.MallMateArrivalMotion?.prepareFocus(dialog,{document:doc});
  root.MallMateUILanguage?.apply(dialog);dialog.showModal();if(invocation.kind==='mall')motion=root.MallMateArrivalMotion?.create(dialog,{document:doc});return dispose;
 }
 const api={mall,resolve,cleanURL,mount};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateArrival=api;
 if(root.document?.head&&resolveVisit(root.location?.href).kind==='mall'){
  const preload=root.document.createElement('link');
  preload.rel='preload';preload.as='image';
  const photo=root.MallMatePhotoDisplay?.responsive('/assets/arrival/wanda-day.jpg','welcome');
  if(photo){
   preload.imageSrcset=photo.srcset;
   preload.imageSizes=photo.sizes;
  }else preload.href='/assets/arrival/wanda-day.jpg';
  root.document.head.appendChild(preload);
 }
})(typeof window!=='undefined'?window:globalThis);
