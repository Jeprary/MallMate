// Arrival presentation only. Business callbacks, URL consumption and dialog ownership stay in entry-arrival.
(function(root){
 'use strict';
 const owners=new WeakMap(),inputs=new WeakMap();
 const easeOut='cubic-bezier(.22,1,.36,1)',easeMove='cubic-bezier(.65,0,.35,1)';
 function inputMode(doc){
  if(inputs.has(doc))return inputs.get(doc);
  const state={keyboard:false};
  const clear=()=>{for(const node of doc.querySelectorAll('[data-entry-initial-focus],[data-entry-pointer-focus]')){node.removeAttribute('data-entry-initial-focus');node.removeAttribute('data-entry-pointer-focus');}};
  const key=()=>{state.keyboard=true;clear();};
  const pointer=()=>{state.keyboard=false;doc.querySelector('.arrival-sheet[open] [data-arrival-enter]')?.setAttribute('data-entry-initial-focus','');};
  doc.addEventListener('keydown',key,true);doc.addEventListener('pointerdown',pointer,true);
  const win=doc.defaultView||root;
  win.addEventListener?.('pagehide',()=>{doc.removeEventListener('keydown',key,true);doc.removeEventListener('pointerdown',pointer,true);inputs.delete(doc);},{once:true});
  inputs.set(doc,state);return state;
 }
 function prepareFocus(dialog,{document:doc=dialog.ownerDocument}={}){
  const button=dialog.querySelector('[data-arrival-enter]');
  if(button&&!inputMode(doc).keyboard)button.setAttribute('data-entry-initial-focus','');
 }
 function restoreFocus(button,{pointer=false}={}){
  if(!button)return;
  inputMode(button.ownerDocument);
  if(pointer){button.setAttribute('data-entry-pointer-focus','');button.addEventListener('blur',()=>button.removeAttribute('data-entry-pointer-focus'),{once:true});}
  else button.removeAttribute('data-entry-pointer-focus');
  button.focus({preventScroll:true});
 }
 function create(dialog,{document:doc=dialog.ownerDocument}={}){
  owners.get(doc)?.dispose();
  const win=doc.defaultView||root,media=win.matchMedia?.('(prefers-reduced-motion: reduce)');
  let animations=[],surfaces=[],start=null,generation=0,disposed=false,sharedBackdrop=false;
  const reduced=()=>Boolean(media?.matches);
  const own=()=>!disposed&&owners.get(doc)===api;
  function resetText(){
   for(const word of dialog.querySelectorAll('.motion-text-word'))Object.assign(word.style,{opacity:'1',transform:'none',clipPath:'none'});
   for(const tile of dialog.querySelectorAll('.motion-word-tile'))tile.style.display='none';
  }
  function cancelAnimations(){for(const animation of animations)animation.cancel();animations=[];}
  function clearSurfaces(){for(const surface of surfaces)surface.remove();surfaces=[];}
  function restoreHeading(){if(owners.get(doc)===api)doc.body.classList.remove('arrival-welcome-open');}
  function cancelVisual(){
   generation++;cancelAnimations();clearSurfaces();resetText();start=null;
   if(!dialog.open||!dialog.isConnected)restoreHeading();
  }
  function animate(element,frames,duration,delay=0,easing=easeOut){
   if(!own()||reduced()||typeof element?.animate!=='function')return null;
   try{const animation=element.animate(frames,{duration,delay,easing,fill:'both'});
    animations.push(animation);animation.finished.catch(()=>{});return animation;
   }catch{return null;}
  }
  function waitForAnimations(callback){
   const token=generation,current=animations.slice();
   Promise.allSettled(current.map(animation=>animation.finished)).then(()=>{if(own()&&token===generation)callback();});
  }
  function dispose(){
   if(disposed)return;
   cancelVisual();restoreHeading();disposed=true;
   doc.removeEventListener('pointerdown',interrupt,true);doc.removeEventListener('keydown',interrupt,true);
   win.removeEventListener?.('resize',onResize);win.removeEventListener?.('pagehide',dispose);
   media?.removeEventListener?.('change',onReduced);
   if(owners.get(doc)===api)owners.delete(doc);
  }
  function interrupt(event){
   if(event.target.closest?.('#voice-toggle')&&(event.type==='pointerdown'||['Enter',' '].includes(event.key)))dispose();
  }
  function onResize(){if(own()){if(dialog.open&&dialog.isConnected)cancelVisual();else dispose();}}
  function onReduced(){if(reduced())onResize();}
  function entrance(){
   if(reduced()||typeof dialog.animate!=='function')return;
   const title=dialog.querySelector('h1'),eyebrow=dialog.querySelector('.arrival-eyebrow');
   animate(dialog,[{opacity:.4},{opacity:1}],1100);
   for(const [index,line] of [eyebrow,title].entries()){
    if(!line)continue;
    const word=doc.createElement('span'),tile=doc.createElement('span');
    word.className='motion-text-word';word.textContent=line.textContent;
    tile.className='motion-word-tile';tile.setAttribute('aria-hidden','true');tile.style.opacity='0';
    line.replaceChildren(word,tile);line.classList.add('motion-text-line');
    const width=Math.min(line.getBoundingClientRect().width,320);
    animate(word,[{clipPath:'inset(0 100% 0 0)',transform:'translateX(-24px)',opacity:0},{clipPath:'inset(0 0% 0 0)',transform:'translateX(0)',opacity:1}],820,index*90+80);
    animate(tile,[{transform:'translateX(0) scale(1)',opacity:1},{offset:.8,transform:`translateX(${Math.max(0,width-24)}px) scale(.7)`,opacity:.5},{transform:`translateX(${width}px) scale(.35)`,opacity:0}],760,index*90+80);
   }
   animate(dialog.querySelector('[data-arrival-enter]'),[{opacity:0,transform:'translateY(8px)'},{opacity:1,transform:'translateY(0)'}],400,580);
  }
  function capture(enter=false,{reuseBackdrop=false}={}){
   sharedBackdrop=reuseBackdrop;
   if(!own()||reduced()||typeof dialog.animate!=='function'||surfaces.length)return;
   start=null;
   if(enter){
    const title=dialog.querySelector('h1');
    const word=title?.querySelector('.motion-text-word')||title;
    if(word){
     const rect=word.getBoundingClientRect(),style=win.getComputedStyle(word);
     // A tap during the welcome entrance starts from whatever is currently on screen.
     start={left:rect.left,top:rect.top,fontFamily:style.fontFamily,fontSize:style.fontSize,fontWeight:style.fontWeight,lineHeight:style.lineHeight,letterSpacing:style.letterSpacing,color:style.color,textShadow:style.textShadow,clipPath:style.clipPath,opacity:Number(style.opacity)*Number(win.getComputedStyle(dialog).opacity)};
    }
   }
   const box=dialog.getBoundingClientRect(),ghost=doc.createElement('div'),dim=doc.createElement('div');
   ghost.className=dialog.className+' entry-motion-ghost';ghost.innerHTML=dialog.innerHTML;
   const original=[dialog,...dialog.querySelectorAll('*')],copies=[ghost,...ghost.querySelectorAll('*')];
   for(let i=0;i<original.length;i++){
    const style=win.getComputedStyle(original[i]);
    for(const key of ['transform','transformOrigin','opacity','clipPath'])copies[i].style[key]=style[key];
    copies[i].removeAttribute('id');
   }
   ghost.removeAttribute('aria-labelledby');ghost.setAttribute('aria-hidden','true');ghost.inert=true;
   if(start)ghost.querySelector('h1').style.visibility='hidden';
   for(const control of ghost.querySelectorAll('button,input,textarea,select')){control.disabled=true;control.removeAttribute('autofocus');}
   Object.assign(ghost.style,{left:box.left+'px',top:box.top+'px',right:'auto',bottom:'auto',width:box.width+'px',height:box.height+'px',opacity:win.getComputedStyle(dialog).opacity,visibility:'hidden'});
   dim.className='entry-motion-dim';dim.setAttribute('aria-hidden','true');dim.style.visibility='hidden';
   if(sharedBackdrop){doc.body.append(ghost);surfaces=[ghost];}
   else{doc.body.append(dim,ghost);surfaces=[dim,ghost];}
  }
  function reveal(){
   if(!own()){return;}
   generation++;cancelAnimations();
   if(reduced()||typeof dialog.animate!=='function'){dispose();return;}
   for(const surface of surfaces){
    surface.style.visibility='visible';
    animate(surface,surface.classList.contains('entry-motion-ghost')?[{opacity:Number(surface.style.opacity),transform:'translateY(0)'},{opacity:0,transform:'translateY(24px)'}]:[{opacity:1},{opacity:0}],240);
   }
   const location=doc.querySelector('.discovery-heading .visit-location');
   const target=location?.querySelector('strong');
   if(start&&target){
    const rect=target.getBoundingClientRect(),style=win.getComputedStyle(target),moving=doc.createElement('span');
    moving.className='arrival-shared-title';moving.textContent=target.textContent;moving.setAttribute('aria-hidden','true');
    Object.assign(moving.style,{left:start.left+'px',top:start.top+'px',fontFamily:start.fontFamily,lineHeight:start.lineHeight,fontSize:start.fontSize,fontWeight:start.fontWeight,letterSpacing:start.letterSpacing,color:start.color,textShadow:start.textShadow});
    doc.body.appendChild(moving);surfaces.push(moving);
    const duration=700, exchange=180, scale=parseFloat(style.fontSize)/parseFloat(start.fontSize);
    animate(moving,[
     {transform:'translate(0,0) scale(1)',color:start.color,textShadow:start.textShadow},
     {transform:`translate(${rect.left-start.left}px,${rect.top-start.top}px) scale(${scale})`,color:style.color,textShadow:'none'}
    ],duration,0,easeMove);
    animate(moving,[{opacity:start.opacity,clipPath:start.clipPath},{offset:.6,opacity:1,clipPath:'inset(0)'},{offset:1-exchange/duration,opacity:1,clipPath:'inset(0)'},{opacity:0,clipPath:'inset(0)'}],duration,0,'linear');
    animate(location,[{opacity:0},{opacity:1}],exchange,duration-exchange,'linear');
    animate(doc.querySelector('.discovery-home .voice-entry'),[{opacity:0},{opacity:1}],300,160,'linear');
    restoreHeading();
   }else{
    restoreHeading();
    animate(doc.querySelector('.discovery-home .voice-entry'),[{opacity:.7,transform:'scale(.97)'},{opacity:1,transform:'scale(1)'}],280);
   }
   waitForAnimations(dispose);
  }
  const api={capture,reveal,dispose};owners.set(doc,api);
  inputMode(doc);doc.body.classList.add('arrival-welcome-open');
  doc.addEventListener('pointerdown',interrupt,true);doc.addEventListener('keydown',interrupt,true);
  win.addEventListener?.('resize',onResize);win.addEventListener?.('pagehide',dispose);
  media?.addEventListener?.('change',onReduced);
  entrance();return api;
 }
 const api={prepareFocus,restoreFocus,create};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateArrivalMotion=api;
})(typeof window!=='undefined'?window:globalThis);
