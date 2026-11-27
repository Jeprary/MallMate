// Share one shade between the welcome sheet and the first voice instruction.
(function(root){
 'use strict';
 const seenKey='mallmate-voice-entry-guide-seen',depthKey='mallmate-voice-guide-depth';
 const preview=root.parent!==root&&root.location?.hostname==='127.0.0.1'&&new URLSearchParams(root.location.search).get('shadePreview')==='1';
 function readDepth(){
  try{return setDepth(root.localStorage.getItem(depthKey));}catch{return setDepth(null);}
 }
 function setDepth(value){
  const depth=value!==null&&value!==''&&Number.isFinite(Number(value))?Math.max(50,Math.min(95,Math.round(Number(value)))):72;
  const page=root.document.documentElement;
  page.style.setProperty('--voice-guide-depth',String(depth/100));
  page.toggleAttribute('data-voice-guide-light',depth<68);
  return depth;
 }
 function saveDepth(value){
  const depth=setDepth(value);
  try{root.localStorage.setItem(depthKey,String(depth));return true;}catch{return false;}
 }
 if(root.document)readDepth();
 function prepare(doc=root.document){
  const voiceButton=()=>doc.querySelector('.discovery-home.is-new #voice-toggle');
  if(!voiceButton()?.querySelector('.voice-orb'))return null;
  try{if(!preview&&root.sessionStorage.getItem(seenKey))return null;}catch{}
  const guide=doc.createElement('div'),hint=doc.createElement('p');
  guide.className='voice-entry-guide';
  guide.dataset.phase='arrival';
  if(preview)guide.setAttribute('data-tuning-preview','');
  hint.id='voice-entry-instruction';
  hint.hidden=true;
  hint.textContent=root.MallMateUILanguage?.language()==='zh'?'单击以开始或结束说话':'Tap to start or stop speaking';
  guide.append(hint);
  const viewportEdge=doc.createElement('span');
  viewportEdge.className='voice-guide-viewport-edge';
  viewportEdge.setAttribute('aria-hidden','true');
  let timer=0,button=null,describedBy=null,finished=false;
  function position(){
   const orb=voiceButton()?.querySelector('.voice-orb');
   if(!orb)return;
   const {left,top,bottom,width,height}=orb.getBoundingClientRect();
   guide.style.setProperty('--voice-guide-x',`${left+width/2}px`);
   guide.style.setProperty('--voice-guide-y',`${top+height/2}px`);
   guide.style.setProperty('--voice-guide-label-y',`${root.innerHeight-bottom>58?bottom+26:top-24}px`);
  }
  function remove(){
   if(finished)return;
   finished=true;
   root.clearTimeout(timer);
   root.removeEventListener('resize',position);
   root.removeEventListener('pagehide',remove);
   root.removeEventListener('mallmate:preview-guide-fade',dismiss);
   doc.removeEventListener('pointerdown',dismiss,true);
   doc.removeEventListener('keydown',dismiss,true);
   if(button){
    if(describedBy)button.setAttribute('aria-describedby',describedBy);
    else button.removeAttribute('aria-describedby');
   }
   doc.body.removeAttribute('data-voice-guide');
   doc.documentElement.style.removeProperty('--voice-guide-fade');
   guide.remove();
   viewportEdge.remove();
  }
  function fade(automatic=false){
   if(finished||guide.dataset.phase==='leaving')return;
   root.clearTimeout(timer);
   if(root.matchMedia?.('(prefers-reduced-motion: reduce)').matches){remove();return;}
   const duration=automatic?720:340;
   doc.documentElement.style.setProperty('--voice-guide-fade',`${duration}ms`);
   guide.dataset.phase='leaving';
   guide.addEventListener('transitionend',remove,{once:true});
   timer=root.setTimeout(remove,duration+60);
  }
  function dismiss(){fade();}
  function handoff(){
   if(finished)return;
   doc.body.setAttribute('data-voice-guide','');
   position();
   doc.addEventListener('pointerdown',dismiss,true);
   doc.addEventListener('keydown',dismiss,true);
  }
  function show(){
   if(finished||guide.dataset.phase==='leaving')return;
   button=voiceButton();
   if(!button||button.dataset.voiceState!=='idle'){dismiss();return;}
   try{if(!preview)root.sessionStorage.setItem(seenKey,'1');}catch{}
   describedBy=button.getAttribute('aria-describedby');
   button.setAttribute('aria-describedby',[describedBy,hint.id].filter(Boolean).join(' '));
   hint.hidden=false;
   position();
   guide.dataset.phase='active';
   if(!preview)timer=root.setTimeout(()=>fade(true),3000);
  }
  doc.body.append(guide,viewportEdge);
  position();
  root.addEventListener('resize',position);
  root.addEventListener('pagehide',remove,{once:true});
  if(preview)root.addEventListener('mallmate:preview-guide-fade',dismiss);
  return {handoff,show,dismiss,remove};
 }
 root.MallMateVoiceEntryGuide={prepare,preview,readDepth,setDepth,saveDepth};
})(typeof window!=='undefined'?window:globalThis);
