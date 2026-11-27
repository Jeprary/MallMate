'use strict';
const developerMode=new URLSearchParams(location.search).get('mode')==='developer';
const navigationMode=new URLSearchParams(location.search).get('nav');
const showBottomNavigation=navigationMode==='on'||(developerMode&&navigationMode!=='off');
const prepareMicrophoneAtEntry=new URLSearchParams(location.search).get('mic')==='entry';
const M=window.MallMateModel;
const catalogue=window.MallMateCatalogue.create();
const feedbackRuntime=window.MallMateCardFeedbackSession?.create();
window.MallMateVoiceTurnSession=window.MallMateVoiceTurn?.create();
window.MallMateRouteMotion=window.MallMatePageTransition?.create(document);
const resultReveal=window.MallMateResultReveal?.create(document);
const voiceCues=window.MallMateVoiceCues?.create();
window.addEventListener('pagehide',()=>voiceCues?.dispose());
window.addEventListener('pageshow',event=>{if(event.persisted&&page==='chat')voiceCues?.prepare();});
let directoryState={query:'',facet:'all',scrollY:0};
let chatScrollY=0,detailScroll=null,storeBackPending=false;
const storePages=new Set(['detail','map']);
const arReturnPrefix='mallmate-ar-return:';
const arReturnLifetimeMs=60*60*1000;
const arReturnHash=/^#return-([0-9a-f-]{36})$/;
const recommendationPosition={ids:[],index:0};let recommendationFocus=null;
function freshState(){return {...M.fresh(),stores:[],selected:null};} let KEY='mallmate-no-user',currentUser=null;
let state=freshState();
let disposeIndoor=null,disposeBottomNav=null,disposeFullTurn=null,chatDraft='',chatEpoch=0,voiceController=null,voiceView=null,speechLanguage=(navigator.languages?.[0]||navigator.language||'en-US'),swipeDisposers=[];
const names={browse:'Browse stores',chat:'Chat',detail:'Store detail',map:'Store location',arrival:'Arrival & feedback',merchant:'Merchant overview',editor:'Edit store',settings:'Settings'};
let agentProgress='',agentPendingText='',agentAbort=null,agentToolEvent=null;
let localSpeechReady=false,acceptsWebmOpus=false;let aiConfigured=false,aiProvider='',aiBusy=false,aiMode='rules'; let remoteFeedback=[],merchantStoreIds=[],merchantLoading=false; let page=new URLSearchParams(location.search).get('screen')||'chat';if(!names[page])page='chat';let editing='coffee',notice='',error='';
const h=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const category=c=>({all:'All stores',cafe:'Coffee & dessert',food:'Food',shops:'Shopping'}[c]);
const icon=s=>({cafe:'☕',food:'◉',shops:s.id==='books'?'▤':'◈'}[s.category]);
function save(){try{window.MallMateVisit.save({local:localStorage,session:sessionStorage,key:KEY,state:feedbackRuntime?.persist(state)||state});}catch(e){notice='This visit could not be saved. Keep this tab open.';}}

function record(type,id=state.selected,extra={}){state.events.push({type,storeId:id,budgetMax:state.context.max,time:new Date().toISOString(),dataBasis:'declared budget, local demo interaction',...extra});save();}
function chatPosition(){return {scrollY:chatScrollY,cardIndex:recommendationPosition.index};}
function applyChatPosition(position){
 if(!position)return;
 chatScrollY=Number.isFinite(position.scrollY)&&position.scrollY>=0?position.scrollY:0;
 recommendationPosition.index=Number.isInteger(position.cardIndex)&&position.cardIndex>=0?position.cardIndex:0;
}
function setStoreHistory(next,previous,returning){
 const current=history.state?.mallMateStoreView;
 const entering=storePages.has(next)&&state.selected&&['chat','browse','detail'].includes(previous)&&next!==previous;
 if(!entering&&!returning)return;
 const url=new URL(location.href);
 if(storePages.has(next)&&state.selected){
  url.searchParams.set('screen',next);url.searchParams.set('store',state.selected);
 }else{
  url.searchParams.delete('screen');url.searchParams.delete('store');
 }
 const view={page:next,storeId:storePages.has(next)?state.selected:null,source:state.source,back:returning?current?.back:previous};
 if(returning){
  history.replaceState({...history.state,mallMateStoreView:view},'',url);
  return;
 }
 history.scrollRestoration='manual';
 const origin=current?.page===previous?current:{page:previous,storeId:storePages.has(previous)?state.selected:null,source:state.source};
 history.replaceState({...history.state,mallMateStoreView:previous==='chat'?{...origin,position:chatPosition()}:origin},'');
 history.pushState({...history.state,mallMateStoreView:view},'',url);
}
function go(next,{fromHistory=false,returning=false}={}){
 if(!names[next])return;
 if(next==='settings'&&!developerMode)next='chat';
 if(['merchant','editor'].includes(next)&&(!developerMode||currentUser?.guest)){if(developerMode)authScreen();else go('settings');return;}
 const previous=page,entry=history.state?.mallMateStoreView;
 if(fromHistory&&next==='chat')applyChatPosition(entry?.position);
 if(returning&&entry?.page===previous&&entry.back===next){
  if(!storeBackPending){storeBackPending=true;history.back();}
  return;
 }
 const animate=previous!==next&&['chat','browse','detail','map'].includes(previous)&&['chat','browse','detail','map'].includes(next);
 const commit=()=>{
  if(previous==='chat'&&next!=='chat'){
   chatScrollY=document.querySelector('#app .discovery-content')?.scrollTop||0;
   if(feedbackRuntime?.target()||feedbackRuntime?.retainsCards()){invalidatePending();save();}
  }
  if(previous==='browse')directoryState.scrollY=document.querySelector('#app .screen')?.scrollTop||0;
  if(previous==='detail'&&next==='map')detailScroll={storeId:state.selected,documentY:window.scrollY,screenY:document.querySelector('#app .screen')?.scrollTop||0};
  if(next!=='chat')recommendationFocus=null;
  if(!fromHistory&&(storePages.has(next)||returning))setStoreHistory(next,previous,returning);
  page=next;notice='';error='';render();
  const screen=document.querySelector('#app .screen');
  const savedDetail=previous==='map'&&next==='detail'&&detailScroll?.storeId===state.selected?detailScroll:null;
  if(screen)screen.scrollTop=next==='browse'?directoryState.scrollY:savedDetail?.screenY||0;
  window.scrollTo(0,savedDetail?.documentY||0);
  if(next==='chat'&&previous!=='chat'){
   const content=document.querySelector('#app .discovery-content');
   if(content)content.scrollTop=chatScrollY;
  }
  if(next==='merchant')refreshMerchant();
 };
 const detailMotion=next==='detail'?'enter':previous==='detail'?'leave':null;
 if(window.MallMateRouteMotion)window.MallMateRouteMotion.navigate(commit,{animate,detailMotion,retire:()=>{const voice=voiceView,indoor=disposeIndoor;voice?.invalidate();voiceView=null;disposeIndoor=null;return ()=>{voice?.dispose();indoor?.();};}});else commit();
}
window.addEventListener('popstate',event=>{
 storeBackPending=false;
 const view=event.state?.mallMateStoreView;
 if(!view||!['chat','browse','detail','map'].includes(view.page))return;
 if(storePages.has(view.page)){
  if(view.storeId&&!state.stores.some(item=>item.id===view.storeId))return;
  state.selected=view.storeId;state.source=view.source;state.navigation=null;
 }
 go(view.page,{fromHistory:true});
});
function store(){return state.stores.find(s=>s.id===state.selected)||null;}
function chips(){const c=state.context;return `<div class="context"><span>${category(c.category)}</span><span>RMB ${c.min}-${c.max}</span><span>${c.time} min</span><span>${c.origin==='entrance'?'Main entrance':'Atrium'}</span>${c.quiet?'<span>Quiet place</span>':''}</div>`;}
function contextForm(){const c=state.context;return `<form id="context-form"><div class="fields"><div><label for="purpose">Visit purpose</label><select id="purpose" name="purpose">${[['browse','Look around'],['shopping','Shopping'],['food','Food'],['drink','Drink'],['rest','Take a break'],['entertainment','Things to do'],['facility','Find facilities']].map(([value,label])=>`<option value="${value}" ${value===(discovery().intent?.kind||({all:'browse',cafe:'drink',food:'food',shops:'shopping'}[c.category]))?'selected':''}>${label}</option>`).join('')}</select></div><div><label for="origin">Starting point</label><select name="origin" id="origin"><option value="entrance" ${c.origin==='entrance'?'selected':''}>Main entrance</option><option value="atrium" ${c.origin==='atrium'?'selected':''}>Central atrium</option></select></div><div><label for="minimum">Budget min (RMB)</label><input id="minimum" name="min" type="number" min="0" max="10000" step="0.01" value="${c.min}" required></div><div><label for="maximum">Budget max (RMB)</label><input id="maximum" name="max" type="number" min="0" max="10000" step="0.01" value="${c.max}" required></div><div><label for="available">Time (minutes)</label><input id="available" name="time" type="number" min="1" max="240" value="${c.time}" required></div><label class="check"><input type="checkbox" name="quiet" ${c.quiet?'checked':''}>Quiet place</label></div><button class="secondary" type="submit">Apply context</button></form>`;}
// Display translation only: original catalogue names and IDs remain the binding identity.
function displayName(s){
 if(window.MallMateUILanguage?.language()!=='zh'&&s.nameEn)return s.nameEn;
 const clean=s.name.replace(/·/g,' ').replace(/[（(]([^（）()]*)[）)]$/,(suffix,place)=>/太仓/.test(place)&&/万达/.test(place)?'':suffix).trim();if(window.MallMateUILanguage?.language()==='zh')return clean;return /^雍哲港式餐厅(?:[（(]太仓万达店[）)])?$/.test(s.name)?'Yongzhe Hong Kong Restaurant':clean;}
function discovery(){return state.discovery||(state.discovery={intent:null,clarificationsUsed:0,excludedTerms:[],excludedStoreIds:[],action:'idle',options:[],budgetSpecified:false});}
function exclusionLabel(term){return window.MallMateConversation.expandExcludedTerms([term]).find(t=>/[a-z]/i.test(t))||term;}
function selectedCardStore(selection){
 const store=state.stores.find(s=>s.id===selection.storeId);
 const cover=store?.photos?.find(photo=>photo.url===selection.coverPhotoUrl);
 return cover?{...store,photo:cover}:store;
}
function chatMatches(){const d=discovery();if(d.providerMode==='model'){const blocked=new Set(d.excludedStoreIds||[]);return (d.selections||[]).map(selectedCardStore).filter(s=>s&&(feedbackRuntime?.retainsCards()||(!blocked.has(s.id)&&!window.MallMateCandidates.excluded(s,d.excludedTerms)&&(!d.budgetSpecified||(Number.isFinite(s.min)&&Number.isFinite(s.max)&&s.max<=state.context.max&&s.min>=state.context.min))&&(!d.quietRequired||s.quiet===true))));}return window.MallMateCandidates.recommend(state.stores,state.context,d);}
function recommendationPresentation(d=discovery(),previous=null){return window.MallMateRecommendationPresentation?.resolve(d.presentation,(d.selections||[]).length,previous)||(d.presentation||((d.selections||[]).length>1?'compare':(d.selections||[]).length===1?'focus':previous||'compare'));}
function focusedRecommendation(){const shown=chatMatches().slice(0,3);if(recommendationPresentation()==='focus')return shown[recommendationPosition.index]?.id||null;const id=typeof document!=='undefined'?document.activeElement?.closest?.('[data-recommendation]')?.dataset.recommendation:null;return shown.some(s=>s.id===id)?id:null;}
function chatBody(){return window.MallMateDiscoveryUI.home({draft:chatDraft,userName:currentUser?.guest?'':currentUser?.displayName||currentUser?.username||'',busy:aiBusy,progress:agentProgress,toolEvent:agentToolEvent,pendingText:agentPendingText,supplementing:window.MallMateVoiceTurnSession?.isSupplementing(),messages:state.messages,discovery:discovery(),matches:chatMatches(),nameOf:displayName,exclusionOf:exclusionLabel,canReplace:aiMode==='ai'&&aiConfigured&&!!window.MallMateAgentClient,retryStoreId:feedbackRuntime?.retryStoreId(),emptyMessage:window.MallMateIntent.emptyMessage(discovery().intent)});}
function invalidatePending({keepText=false,keepTurn=false}={}){state=feedbackRuntime?.persist(state)||state;chatEpoch++;aiBusy=false;agentAbort?.abort();agentAbort=null;agentProgress='';agentToolEvent=null;if(!keepText)agentPendingText='';if(!keepTurn)window.MallMateVoiceTurnSession?.reset();feedbackRuntime?.clear();}
function cancelPendingTurn({supplement=false}={}){
 if(!agentPendingText)return;
 invalidatePending({keepText:true,keepTurn:true});chatDraft='';error='';
 const adding=supplement&&window.MallMateVoiceTurnSession?.beginSupplement();
 if(adding&&voiceView){
  document.querySelector('.discovery-home')?.classList.remove('is-waiting');
  voiceView.start();
  return;
 }
 render({retainVoice:true});
}
function updateAgentProgress(event){
 if(event.type==='tool_start'||event.type==='tool_status')agentToolEvent=event;
 else if(event.type==='message'||event.type==='status'){agentToolEvent=null;agentProgress=event.text;}
 else return;
 const bubble=document.getElementById('voice-context');
 if(page!=='chat'||!bubble)return;
 bubble.innerHTML=window.MallMateDiscoveryUI.turnContent({busy:true,progress:agentProgress,toolEvent:agentToolEvent,pendingText:agentPendingText});
 bubble.hidden=!bubble.childElementCount;
 window.MallMateUILanguage?.apply(bubble);
}
function replaceStore(id){
 if(aiBusy||aiMode!=='ai'||!aiConfigured||!window.MallMateAgentClient||!feedbackRuntime||!chatMatches().some(s=>s.id===id))return;
 const retry=feedbackRuntime.retry(id),feedback=feedbackRuntime.begin(state,{action:'replace_store',storeId:id});
 const name=displayName(state.stores.find(s=>s.id===id));
 return send(retry?.text||(window.MallMateUILanguage?.language()==='zh'?'换一家：':'Try another place: ')+name,{source:retry?.source||'card',cardFeedback:feedback,focusedStoreId:id});
}
function showOtherOptions(){
 if(aiBusy)return;invalidatePending();
 if(aiMode==='ai'){feedbackRuntime?.hold(state);return send(window.MallMateUILanguage?.language()==='zh'?'换一批选择':'Show other options',{source:'card',excludeCurrent:true});}
 const d=discovery(),shown=chatMatches().slice(0,3);d.excludedStoreIds=[...new Set([...d.excludedStoreIds,...shown.map(s=>s.id)])];d.undoSelections=d.selections;d.lastSkippedId=shown.at(-1)?.id;d.lastSkippedIds=shown.map(s=>s.id);save();render();
}
function syncComposer(listening=false){const form=document.getElementById('chat-form');if(!form)return;form.dataset.inputMode=listening?'listening':chatDraft.trim()?'text':'empty';const button=form.querySelector('.send-button');if(button)button.hidden=!chatDraft.trim()||listening;}
function bindFullTurn(){
 const turn=document.getElementById('voice-context');
 const trigger=document.querySelector('[data-read-turn]');
 if(!turn||!trigger||typeof window.HTMLDialogElement?.prototype.showModal!=='function')return;
 const refresh=()=>{trigger.hidden=turn.hidden||turn.scrollHeight-turn.clientHeight<=1;};
 const resize=new ResizeObserver(refresh);
 const content=new MutationObserver(refresh);
 resize.observe(turn);
 content.observe(turn,{childList:true,characterData:true,subtree:true,attributeFilter:['hidden']});
 let dialog;
 trigger.onclick=()=>{
  const label=key=>window.MallMateUILanguage?.text(key)||key;
  const fullTurn=turn.cloneNode(true);
  fullTurn.removeAttribute('id');
  fullTurn.removeAttribute('aria-live');
  dialog=document.createElement('dialog');
  dialog.className='full-turn-dialog';
  dialog.setAttribute('aria-label',label('Full conversation turn'));
  const close=document.createElement('button');
  close.className='link';
  close.autofocus=true;
  close.textContent=label('Close');
  close.onclick=()=>dialog.close();
  dialog.append(close,fullTurn);
  const opened=dialog;
  opened.addEventListener('close',()=>{opened.remove();if(dialog===opened)dialog=null;},{once:true});
  turn.parentElement.append(opened);
  opened.showModal();
 };
 refresh();
 return ()=>{resize.disconnect();content.disconnect();dialog?.close();dialog?.remove();};
}
function bindVoice(){
 const toggle=document.getElementById('voice-toggle');if(!toggle)return;
 voiceCues?.prepare();
 let phase='idle',voiceFocus=null,voiceRun=0,stopCued=false,endVoiceHold=null;
 const status=document.getElementById('voice-status');
 const caption=document.getElementById('voice-preview'),composer=document.getElementById('chat-form');
 const clearCaption=()=>{if(caption){caption.textContent='';caption.hidden=true;}composer?.removeAttribute?.('data-voice-preview');};
 const wave=window.MallMateVoiceWave?.mount(toggle),cues=voiceCues;
 const stopCue=()=>{if(!stopCued){stopCued=true;cues?.play('stop');}};
 function present(next,message=''){
  const previous=phase;
  phase=next;
  if(toggle.dataset.voiceState!==next){toggle.dataset.voiceState=next;wave?.state(next);}
  if(previous==='starting'&&next!=='starting')cues?.endWait();
  if(next==='listening'&&previous!=='listening')cues?.play('start');
  const recording=next==='listening',processing=next==='transcribing'||next==='thinking';
  const label=recording?'Finish':next==='starting'?'Starting microphone…':next==='transcribing'?'Transcribing…':next==='thinking'?'Thinking…':state.messages.length?'Continue speaking':'Speak';
  toggle.disabled=next==='transcribing';toggle.querySelector('.voice-label').textContent=label;
  toggle.setAttribute('aria-label',next==='thinking'?'Continue speaking':next==='starting'?'Cancel':label);toggle.setAttribute('aria-pressed',String(recording));
  toggle.setAttribute('aria-busy',String(processing||next==='starting'));
  const languageSwitch=document.querySelector('[data-ui-language]');if(languageSwitch)languageSwitch.disabled=processing||next==='starting'||recording;
  status.hidden=!message||!['error','unsupported'].includes(next);status.textContent=window.MallMateDiscoveryUI?.voiceMessage(message)||message;
  syncComposer(recording||processing);window.MallMateUILanguage?.apply(document.querySelector('.composer'));
 }
 present(aiBusy?'thinking':'idle');
 if(new URLSearchParams(location.search).get('voiceDebug')==='1'){
  const debug=document.createElement('pre');debug.id='voice-diagnostic';debug.style.cssText='white-space:pre-wrap;font-size:12px;max-height:220px;overflow:auto';
  try{debug.textContent=sessionStorage.getItem('mallmate-voice-diagnostic')||'No speech error captured in this tab yet.';}catch{}
  status.after(debug);navigator.permissions?.query({name:'microphone'}).then(p=>{status.dataset.microphonePermission=p.state;debug.textContent+='\nMicrophone permission: '+p.state;}).catch(()=>{status.dataset.microphonePermission='unavailable';});
 }
 const setup=audioContext=>{
  const run=++voiceRun;let finalReceived=false,submitted=false,hasPreview=false;voiceController?.dispose();
  const voice=window.MallMateSpeechTransport==='websocket'?window.MallMateQwenStreamingVoice:window.MallMateLocalVoice;
  voiceController=(localSpeechReady?voice:window.MallMateVoice).create({
   lang:speechLanguage,maxRecordingSeconds:window.MallMateSpeechMaxRecordingSeconds,acceptsWebmOpus,
   ...(voice===window.MallMateQwenStreamingVoice?{audioContext}:{}),
   ...(prepareMicrophoneAtEntry&&voice===window.MallMateQwenStreamingVoice&&navigator.mediaDevices?{media:window.MallMateEntryMicrophone}:{}),
   onLevel:sample=>{if(run===voiceRun)wave?.level(sample);},
   ...(localSpeechReady?{onPreview:preview=>{
    if(run!==voiceRun||page!=='chat'||finalReceived)return;
    const text=window.MallMateDiscoveryUI?.voiceCaption(preview?.text)||'';
    if(!text)return;
    hasPreview=true;
    if(caption){caption.textContent=text;caption.hidden=false;composer?.setAttribute?.('data-voice-preview','true');}
   }}:{}),
   onText:text=>{
    if(run!==voiceRun||page!=='chat'||submitted)return;finalReceived=true;clearCaption();chatDraft=String(text||'');
    const field=document.getElementById('need');if(field)field.value=chatDraft;
    const bubble=document.getElementById('voice-context');if(bubble&&!bubble.closest('.is-new')){bubble.hidden=false;const line=document.createElement('p');line.className='turn-user';line.setAttribute('data-no-localize','');line.setAttribute('translate','no');line.textContent=window.MallMateVoiceTurnSession?.preview(chatDraft)||chatDraft;bubble.replaceChildren(line);}
   },
   onState:s=>{
    if(run!==voiceRun||page!=='chat')return;
    const next=s.status==='listening'&&s.message==='Starting microphone…'?'starting':s.status;
    if(['idle','error','unsupported'].includes(next)){finalReceived=true;if(next!=='error'||!hasPreview)clearCaption();}
    if(next==='listening'){
     const bubble=document.getElementById('voice-context');if(bubble)bubble.hidden=!window.MallMateVoiceTurnSession?.isSupplementing();
    }else{
     if(next==='transcribing'||next==='idle'&&phase==='listening')stopCue();
     if(['idle','error'].includes(next)){const bubble=document.getElementById('voice-context');if(bubble)bubble.hidden=!bubble.children.length;}
    }
    if(s.diagnostics){
     s.diagnostics.microphonePermission=status.dataset.microphonePermission||'unknown';try{sessionStorage.setItem('mallmate-voice-diagnostic',JSON.stringify(s.diagnostics));}catch{}
     status.dataset.voiceDiagnostic=JSON.stringify(s.diagnostics);const debug=document.getElementById('voice-diagnostic');if(debug)debug.textContent=JSON.stringify(s.diagnostics,null,2);
    }
    if(next==='error'&&['no_speech','no-speech'].includes(s.diagnostics?.errorCode)){
     if(resumeInterruptedTurn())return;
     if(hasPreview){present('error','Voice input could not be confirmed. Tap to retry.');return;}
     clearPreview();present('idle');return;
    }
    present(next,s.message||'');
   },
   onComplete:()=>{
    if(run!==voiceRun||page!=='chat'||submitted||aiBusy||!chatDraft.trim())return;
    const turn=window.MallMateVoiceTurnSession?.submission(chatDraft,{focusedStoreId:voiceFocus})||{text:chatDraft,options:{source:'voice',focusedStoreId:voiceFocus}};
    if(turn.text.length>1500){present('error',window.MallMateUILanguage?.text('Keep the addition shorter.')||'Keep the addition shorter.');return;}
    submitted=true;send(turn.text,turn.options);
   }
  });
 };
 const clearPreview=()=>{
  clearCaption();chatDraft='';const supplement=window.MallMateVoiceTurnSession?.isSupplementing();if(!supplement)agentPendingText='';
  const field=document.getElementById('need');if(field)field.value='';const bubble=document.getElementById('voice-context');
  if(bubble){if(!supplement){bubble.replaceChildren();bubble.hidden=true;}else{const line=document.createElement('p');line.className='turn-user';line.setAttribute('data-no-localize','');line.setAttribute('translate','no');line.textContent=agentPendingText;bubble.replaceChildren(line);bubble.hidden=false;}}
 };
 const start=()=>{
  present('starting');
  resultReveal?.settleVoiceControl();
  voiceFocus=focusedRecommendation();clearPreview();error='';document.querySelector('.screen>.error')?.remove?.();stopCued=false;cues?.reset();
  const audioContext=cues?.prime();cues?.beginWait();setup(audioContext);
  if(localSpeechReady){try{sessionStorage.removeItem('mallmate-voice-diagnostic');}catch{}const debug=document.getElementById('voice-diagnostic');if(debug)debug.textContent=window.MallMateSpeechTransport==='websocket'?'Qwen streaming speech recognition':'Local speech recognition';}
  voiceController.start();
 };
 const resumeInterruptedTurn=()=>{
  const original=window.MallMateVoiceTurnSession?.cancelSupplement();if(!original)return false;
  voiceRun++;voiceController?.cancel();clearPreview();
  send(original.text,original.options);return true;
 };
 const cancel=()=>{
  voiceRun++;stopCue();voiceController?.cancel();
  if(resumeInterruptedTurn())return;
  clearPreview();present('idle');
 };
 toggle.onpointerdown=event=>{
  if(event.button!==0||endVoiceHold||!resultReveal?.holdVoiceControl())return;
  const events=['pointerup','pointercancel','blur'];
  const release=next=>{if(next.type==='blur'||next.pointerId===event.pointerId)endVoiceHold?.();};
  endVoiceHold=()=>{
   for(const type of events)window.removeEventListener(type,release,true);
   endVoiceHold=null;resultReveal.releaseVoiceControl();
  };
  for(const type of events)window.addEventListener(type,release,true);
 };
 toggle.onclick=()=>{
  if(phase==='transcribing')return;
  if(aiBusy){cancelPendingTurn({supplement:true});return;}
  if(phase==='starting'){cancel();return;}
  if(phase==='listening'){
   if(!localSpeechReady||window.MallMateSpeechTransport!=='websocket'){stopCue();present('transcribing','Transcribing…');}
   voiceController?.stop();return;
  }
  start();
 };
 document.querySelector('[data-cancel-supplement]')?.addEventListener('click',cancel);
 toggle.onkeydown=event=>{if(event.key==='Escape'&&(['starting','listening','transcribing'].includes(phase)||window.MallMateVoiceTurnSession?.isSupplementing())){event.preventDefault();cancel();}};
 voiceView={start,
  sync(){if(!['starting','listening','transcribing'].includes(phase))present(aiBusy?'thinking':'idle');},
  invalidate(){voiceRun++;clearCaption();},
  dispose(){voiceRun++;endVoiceHold?.();cues?.endWait();clearCaption();wave?.dispose();}
 };
}
function card(s){return window.MallMateDiscoveryUI.card(s,{name:displayName(s)});}

function merchant(){const min=state.amountMin??0,max=state.amountMax??10000,events=M.eventsInRange(state.events,min,max);return `<span class="eyebrow">Merchant demo</span><h1>Store manager</h1><span class="badge">Demo catalogue</span><p class="muted">Only demo stores created by this local account can be edited here. Older stores remain visible to shoppers but are not assigned to an owner.</p><button class="secondary" data-go="browse">Open shopper view</button><h2>Store catalogue</h2><button class="secondary" data-action="add-store">＋ Add a demo store to Softr</button>${merchantLoading?'<p>Loading your stores…</p>':state.stores.filter(s=>merchantStoreIds.includes(s.id)).map(s=>`<div class="card"><div class="row"><strong data-no-localize>${h(s.name)}</strong><button class="link" data-edit="${s.id}">Edit</button></div><p>${category(s.category)}<br>RMB ${s.min}-${s.max}<br>${h(s.hours)}</p></div>`).join('')||'<p class="small">No owned demo stores yet. Create one using this account.</p>'}<h2>All feedback from Softr</h2><p class="small">All signed-in local demo accounts can see all feedback, including entries for stores they do not manage. Refresh to update.</p>${remoteFeedback.length?remoteFeedback.slice().reverse().map(f=>`<div class="box"><strong data-no-localize>${h(f.storeName||state.stores.find(s=>s.id===f.storeId)?.name||'Store not linked')}</strong><p>${h(f.rating)}<br><span data-no-localize>${h(f.comment)}</span></p><span class="small">${h(f.createdAt||'')}</span></div>`).join(''):'<p class="small">No feedback in Softr yet, or loading.</p>'}<h2>Feedback you submitted</h2><p class="small">Your own demo feedback recorded in this browser after a successful save. This is a local history; all shared database feedback is shown above.</p>${state.events.filter(e=>e.type==='feedback').slice(-12).reverse().map(e=>`<div class="box"><strong data-no-localize>${h(state.stores.find(s=>s.id===e.storeId)?.name||'Store no longer available')}</strong><p>${h(e.rating||'')}<br><span data-no-localize>${h(e.comment||'')}</span></p><span class="small">${h(e.time||'')}</span></div>`).join('')||'<p class="small">No feedback submitted from this browser account.</p>'}<h2>Declared-budget activity</h2><p class="small">Filter local actions by the visitor's selected budget maximum. These are not purchases, income or physical visitor counts.</p><form id="amount-form"><div class="fields"><div><label for="amount-min">Amount min (RMB)</label><input id="amount-min" name="min" type="number" min="0" value="${min}" required></div><div><label for="amount-max">Amount max (RMB)</label><input id="amount-max" name="max" type="number" min="0" value="${max}" required></div></div><button class="secondary">Filter demo activity</button></form><div class="metrics">${[['Selections','store_selected'],['Routes','navigation_start'],['Feedback','feedback']].map(([name,type])=>`<div><strong>${events.filter(e=>e.type===type).length}</strong>${name}</div>`).join('')}</div><h2>Recent local events</h2><table><thead><tr><th>Action</th><th>Store</th><th>Budget max</th></tr></thead><tbody>${events.slice(-6).reverse().map(e=>`<tr><td>${h(e.type.replaceAll('_',' '))}</td><td data-no-localize>${h(state.stores.find(s=>s.id===e.storeId)?.name||'-')}</td><td>RMB ${e.budgetMax}</td></tr>`).join('')}</tbody></table>${events.length?'':'<p class="small">No matching activity. Try a shopper journey.</p>'}<button class="secondary" data-action="export">Export local demo data</button>`;}
function body(){const s=store();switch(page){
 case'browse':return window.MallMateShopperPages.directory({items:window.MallMateCandidates.directory(state.stores,directoryState),query:directoryState.query,facet:directoryState.facet,nameOf:displayName});
 case'chat':return chatBody();
 case'settings':if(!developerMode)return chatBody();return window.MallMateDiscoveryUI.settings({developerMode,guest:currentUser?.guest,contextForm:contextForm(),aiMode,aiConfigured,aiProvider});
 case'detail':return window.MallMateShopperPages.detail({store:s,name:s?displayName(s):'',source:state.source,reason:state.source==='chat'?(discovery().selections||[]).find(item=>item.storeId===s?.id)?.reason||'':''});
 case'map':return locationBody();
 case'arrival':if(!s)return window.MallMateShopperPages.unavailable();if(!developerMode)return `<h1>You've arrived!</h1><p data-no-localize>${h(s.name)}</p><button class="primary" data-go="chat">Find another place</button>`;return `<div class="detailArt">✓</div><h1>You've arrived!</h1><p data-no-localize>${h(s.name)}</p><span class="badge">MANUAL ARRIVAL CONFIRMATION</span><form id="feedback-form"><h2>Was this recommendation useful?</h2><p class="small">Feedback is visible to other signed-in demo accounts.</p><label for="rating">Your rating</label><select name="rating" id="rating"><option value="helpful">Helpful</option><option value="not-helpful">Not for me</option></select><label for="comment">Optional comment</label><textarea id="comment" name="comment" maxlength="300" placeholder="Tell us what should change"></textarea><button class="primary">Send feedback</button></form><button class="secondary" data-go="merchant">See merchant activity</button><button class="secondary" data-go="browse">Explore more stores</button><p class="notice">Feedback is labelled DEMO and saved with the selected store, visit and context. Arrival is manually confirmed; no purchase is recorded.</p>`;
 case'merchant':return merchant();
 case'editor':{const s=state.stores.find(s=>s.id===editing)||{id:'new',name:'',category:'cafe',min:20,max:50,hours:'10:00-22:00',quiet:false};return `<button class="link back-link" data-go="merchant" aria-label="Store manager">${window.MallMateDiscoveryUI.icon('back')}</button><h1>${editing==='new'?'Add demo store':'Edit listing'}</h1><span class="badge">Demo listing</span><p class="small">Keep the store ID and route location. Shopper recommendations read the same catalogue.</p><form id="edit-form"><label for="store-name">Store name</label><input id="store-name" name="name" maxlength="45" value="${h(s.name)}" required><label for="store-category">Category</label><select id="store-category" name="category">${['cafe','food','shops'].map(c=>`<option value="${c}" ${c===s.category?'selected':''}>${category(c)}</option>`).join('')}</select><div class="fields"><div><label for="price-min">Offer price min (RMB)</label><input id="price-min" name="min" type="number" min="0" max="10000" step="0.01" value="${s.min}" required></div><div><label for="price-max">Offer price max (RMB)</label><input id="price-max" name="max" type="number" min="0" max="10000" step="0.01" value="${s.max}" required></div></div><label for="hours">Opening hours (HH:MM-HH:MM)</label><input name="hours" id="hours" value="${h(s.hours)}" required><button class="primary">Save changes</button></form><p class="notice">The demo saves name, category, price and hours to the Stores table. Quiet is currently not saved; new stores are marked DEMO. Ownership is enforced only by the local demo server; this is not Softr role protection.</p>`;}
}}
function locationBody(){
 const s=store();
 if(state.selected&&!s)return window.MallMateShopperPages.unavailable();
 const {navigationDestination,navigationDestinations}=catalogue.peek()??{};
 return window.MallMateShopperPages.location({store:s,markup:window.MallMateIndoorMap.markup(),navigationDestination,navigationDestinations});
}
function updateChatRegions(app,markup){
 const draft=document.createElement('template');draft.innerHTML=markup;
 const screen=app.querySelector('.phone>.screen'),nextScreen=draft.content.querySelector('.phone>.screen');
 const home=screen.querySelector('.discovery-home'),next=nextScreen.querySelector('.discovery-home');
 home.className=next.className;
 home.querySelector('.discovery-content').replaceWith(next.querySelector('.discovery-content'));
 const dock=home.querySelector('.assistant-dock'),nextDock=next.querySelector('.assistant-dock');
 dock.querySelector('#voice-context').replaceWith(nextDock.querySelector('#voice-context'));
 dock.querySelector('.clarification-options')?.remove();
 const choices=nextDock.querySelector('.clarification-options');
 if(choices)dock.querySelector('#chat-form').before(choices);
 for(const message of screen.querySelectorAll(':scope>.error,:scope>.success'))message.remove();
 home.before(...nextScreen.querySelectorAll(':scope>.error,:scope>.success'));
}
function render({retainVoice=false}={}){
 const app=document.getElementById('app');
 const reuseVoice=retainVoice&&page==='chat'&&voiceView&&!!app.querySelector('.discovery-home #chat-form');
 const revealBefore=resultReveal?.capture();disposeFullTurn?.();disposeFullTurn=null;
 const oldContent=document.querySelector('.discovery-content'),scrollTop=oldContent?.scrollTop||0;
 const focused=document.activeElement?.closest?.('[data-recommendation]');
 if(focused&&page==='chat')recommendationFocus={index:Math.max(0,Array.from(document.querySelectorAll('[data-recommendation]')).indexOf(focused)),replace:document.activeElement?.hasAttribute('data-replace-store')};
 if(!reuseVoice){
  disposeBottomNav?.();disposeBottomNav=null;
  voiceView?.dispose();voiceView=null;voiceController?.dispose();voiceController=null;
 }
 swipeDisposers.forEach(fn=>fn());swipeDisposers=[];
 if(recommendationPosition.reset){
  recommendationPosition.ids=[];recommendationPosition.index=0;recommendationPosition.mode=null;recommendationPosition.reset=false;recommendationFocus=null;
 }else if(recommendationFocus)recommendationPosition.index=recommendationFocus.index;
 const focus=document.activeElement?.id==='need'?{start:document.activeElement.selectionStart,end:document.activeElement.selectionEnd}:null;
 disposeIndoor?.();disposeIndoor=null;document.title='MallMate | '+names[page];
 const markup=window.MallMateShell.markup({page,source:state.source,content:body(),developerMode,user:currentUser,error,notice,bottomNavigation:showBottomNavigation});
 if(reuseVoice)updateChatRegions(app,markup);
 else app.innerHTML=markup;
 bind({reuseVoice});
 document.documentElement.lang=window.MallMateUILanguage?.language()||'en';
 window.MallMateUILanguage?.apply(app);
 if(page==='chat'){
  const content=document.querySelector('.discovery-content');if(content)content.scrollTop=scrollTop;
  if(recommendationFocus&&!aiBusy){
   const cards=document.querySelectorAll('[data-carousel-card]'),card=cards[Math.min(recommendationFocus.index,cards.length-1)];
   const target=feedbackRuntime?.target()?document.getElementById('voice-toggle'):card?.querySelector(recommendationFocus.replace?'[data-replace-store]':'[data-store]');
   target?.focus({preventScroll:true});recommendationFocus=null;
  }
  if(focus){const field=document.getElementById('need');field?.focus({preventScroll:true});field?.setSelectionRange(focus.start,focus.end);}
  disposeFullTurn=bindFullTurn();
 }
 resultReveal?.reveal(revealBefore);
 if(page==='map'&&(!state.selected||store()))disposeIndoor=window.MallMateIndoorMap.mount(document.getElementById('indoor-map-host'),store());
}
function attempt(fn){error='';notice='';try{fn();}catch(e){error=e.message;render();}}
async function send(text,{source='text',cardFeedback,excludeCurrent=false,focusedStoreId}={}){
 text=String(text||'').trim();if(!text||aiBusy)return;voiceController?.cancel();const previousDraft=chatDraft;chatDraft=text;agentPendingText=text;error='';notice='';
 const focused=focusedStoreId===undefined?focusedRecommendation():focusedStoreId;window.MallMateVoiceTurnSession?.begin(text,{source,cardFeedback,excludeCurrent,focusedStoreId:focused});
 if(aiMode==='ai'&&!aiConfigured){error='Configure AI in settings or use offline recommendations.';render();return;}
 const epoch=++chatEpoch,context={...state.context},history=state.messages.slice(-8),d=discovery(),batch=JSON.stringify((d.selections||[]).map(s=>s.storeId)),feedback=cardFeedback||feedbackRuntime?.target();
 let committed=false,revealedCards=false;
 const current=()=>epoch===chatEpoch&&state.discovery===d&&batch===JSON.stringify((d.selections||[]).map(s=>s.storeId));
 const input={text,source,context,history,...(Object.hasOwn(d,'needs')?{needs:d.needs}:{}),...(Object.hasOwn(d,'requirements')?{requirements:d.requirements}:{}),presentation:recommendationPresentation(d),...(focused&&(d.selections||[]).some(s=>s.storeId===focused)?{focusedStoreId:focused}:{}),currentStoreIds:(d.selections||[]).slice(0,3).map(s=>s.storeId),intent:d.intent,clarificationsUsed:d.clarificationsUsed,excludedTerms:d.excludedTerms,excludedStoreIds:excludeCurrent?[...new Set([...(d.excludedStoreIds||[]),...(d.selections||[]).map(s=>s.storeId)])]:d.excludedStoreIds||[],budgetSpecified:d.budgetSpecified,timeSpecified:d.timeSpecified,quietRequired:d.quietRequired,...(feedback?{cardFeedback:feedback}:{})};agentProgress='';agentToolEvent=null;agentPendingText=text;aiBusy=true;render({retainVoice:true});
 try{
  let result;if(aiMode==='ai'){if(window.MallMateAgentClient){agentAbort=new AbortController();result=await window.MallMateAgentClient.send(input,{signal:agentAbort.signal,onEvent:event=>{if(current())updateAgentProgress(event);}});}else {if(feedback)throw Error('Store replacement is unavailable. Please retry.');result=await api('/api/ai/chat',{method:'POST',body:JSON.stringify(input)});}if(result.providerMode!=='model')result=window.MallMateConversation.applyPolicy(input,result);}
  else result=window.MallMateConversation.decide(input);
  if(!current())return;
  const applied=(!feedback&&result.action==='ask'||excludeCurrent&&(result.action!=='recommend'||!result.selections?.length))?{selections:d.selections||[],pending:null,changed:false}:feedbackRuntime?feedbackRuntime.apply(d.selections||[],result,feedback):{selections:result.selections||[],pending:null,changed:true};
  let stores=state.stores;if(result.action==='recommend'){const data=await catalogue.load();if(!current())return;stores=data.records.map(normalizeRecord);if(!stores.length)throw Error('No stores available. Please try again later.');}
  if(!current())return;
  const nextContext=M.validContext(result.context);
  if(feedback&&applied.changed&&applied.selections.some(s=>!stores.some(store=>store.id===s.storeId)))throw Error('The new store is unavailable. Please retry.');
  const memory={};if(Object.hasOwn(result,'needs'))memory.needs=window.MallMateNeeds.clean(result.needs);if(Object.hasOwn(result,'requirements'))memory.requirements=window.MallMateRequirements.clean(result.requirements);
  revealedCards=result.action==='recommend'&&applied.selections.some(selection=>!d.selections?.some(previous=>previous.storeId===selection.storeId));
  committed=true;state.stores=stores;state.context=nextContext;state.discovery={...d,...memory,providerMode:result.providerMode||'rules',selections:applied.selections||[],presentation:!applied.changed||feedback&&result.cardUpdate?.action==='replace_store'?recommendationPresentation(d):recommendationPresentation({presentation:result.presentation,selections:applied.selections},d.presentation),catalogueVersion:result.catalogueVersion||null,timeSpecified:result.timeSpecified===true,quietRequired:result.quietRequired===true,intent:result.intent,clarificationsUsed:result.clarificationsUsed,excludedTerms:result.excludedTerms,action:result.action,options:result.options||[],budgetSpecified:result.providerMode==='model'?result.budgetSpecified:d.budgetSpecified||window.MallMateCandidates.hasBudget(text)||result.context.min!==context.min||result.context.max!==context.max};
  if(!['Show other options','换一批选择'].includes(text)){state.discovery.undoSelections=null;state.discovery.lastSkippedId=null;state.discovery.lastSkippedIds=[];}
  if(feedback&&result.cardUpdate?.action==='replace_store'&&result.cardUpdate.status==='applied')state.discovery.excludedStoreIds=[...new Set([...(d.excludedStoreIds||[]),feedback.storeId])];
  if(excludeCurrent&&applied.changed)state.discovery.excludedStoreIds=[...input.excludedStoreIds];
  if(applied.changed&&!(feedback&&result.cardUpdate?.action==='replace_store'))recommendationPosition.reset=true;
  feedbackRuntime?.accept(applied);
  state.messages.push({role:'user',text,source},{role:'agent',text:result.reply});state.navigation=null;
  window.MallMateVoiceTurnSession?.reset();if(chatDraft===text)chatDraft='';save();
 }catch(e){if(current()){error=e.message;notice='';if(source==='card'&&(feedback||excludeCurrent))chatDraft=previousDraft;feedbackRuntime?.fail(input);}}
 finally{if(epoch===chatEpoch){if(!committed&&!current()){feedbackRuntime?.clear();save();}aiBusy=false;agentProgress='';agentToolEvent=null;if(committed||!current())agentPendingText='';agentAbort=null;render({retainVoice:true});if(committed&&revealedCards&&page==='chat')voiceCues?.play('success');}}
}

function bind({reuseVoice=false}={}){
 window.MallMateShopperPages?.bindFeaturedPhotos(document);
 const disposeSafeEdge=window.MallMateShopperPages?.bindDetailSafeEdge(document);
 if(disposeSafeEdge)swipeDisposers.push(disposeSafeEdge);
 const language=document.querySelector('[data-ui-language]');if(language)language.onclick=event=>{window.MallMateUILanguage?.setLanguage(event.currentTarget.dataset.uiLanguage);render();};
 document.querySelector('[data-cancel-pending]')?.addEventListener('click',()=>cancelPendingTurn());
 document.querySelector('[data-amend-turn]')?.addEventListener('click',()=>cancelPendingTurn({supplement:true}));const gallery=document.querySelector('.store-gallery');if(gallery)swipeDisposers.push(window.MallMateGallery.mount(gallery));document.querySelectorAll('.gallery-slide img').forEach(img=>{const fail=()=>{img.hidden=true;img.parentElement.classList.add('photo-failed');};window.MallMatePhotoDisplay.watch(img,fail);});document.querySelectorAll('.store-cover img').forEach(img=>{const fail=()=>{img.hidden=true;img.closest('.store-cover').classList.add('photo-failed');};window.MallMatePhotoDisplay.watch(img,fail);});document.querySelectorAll('[data-go]').forEach(b=>b.onclick=()=>{if(b.hasAttribute('data-map-overview')){state.selected=null;state.navigation=null;}go(b.dataset.go,{returning:b.hasAttribute('data-store-back')});});document.querySelectorAll('[data-directory-facet]').forEach(b=>b.onclick=()=>{directoryState.facet=b.dataset.directoryFacet;directoryState.scrollY=0;render();});document.querySelectorAll('[data-store]').forEach(b=>b.onclick=()=>{if(aiBusy&&b.closest?.('.recommendations'))return;state.source=page;state.selected=b.dataset.store;state.navigation=null;record('store_selected');go('detail');});document.querySelectorAll('[data-route-store]').forEach(b=>b.onclick=()=>attempt(()=>{const id=b.dataset.routeStore;if(!chatMatches().some(s=>s.id===id))throw Error('Store is not in current recommendations.');state.selected=id;state.source='chat';record('store_selected');state.navigation=null;record('store_location_viewed');go('map');}));document.querySelectorAll('[data-prompt]').forEach(b=>b.onclick=()=>send(window.MallMateUILanguage?.text(b.dataset.prompt)||b.dataset.prompt,{source:'card'}));document.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>{editing=b.dataset.edit;go('editor');});
 document.querySelector('[data-show-location]')?.addEventListener('click',()=>{record('store_location_viewed');go('map');});
 const navigationLink=document.querySelector('[data-map-navigation]');
 if(navigationLink?.protocol==='mallmate-route:')swipeDisposers.push(bindMapNavigation(navigationLink));
 document.getElementById('search-form')?.addEventListener('submit',e=>{e.preventDefault();directoryState.query=String(new FormData(e.target).get('query')||'').trim();directoryState.scrollY=0;render();});
 document.getElementById('context-form')?.addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.target);attempt(()=>{invalidatePending();const intent=window.MallMateIntent.clean({kind:f.get('purpose'),topic:discovery().intent?.kind===f.get('purpose')?discovery().intent.topic:null});state.context=M.validContext({...state.context,category:window.MallMateIntent.category(intent)||'all',min:Number(f.get('min')),max:Number(f.get('max')),time:Number(f.get('time')),origin:f.get('origin'),quiet:f.has('quiet')});state.navigation=null;discovery().intent=intent;discovery().budgetSpecified=true;discovery().providerMode='rules';discovery().selections=[];discovery().undoSelections=null;discovery().quietRequired=false;discovery().timeSpecified=false;discovery().action='recommend';save();notice='Preferences updated.';if(page==='settings')page='chat';render();});});
 const bottomNav=document.querySelector('.phone>.nav');if(!reuseVoice&&bottomNav&&window.MallMateBottomNav)disposeBottomNav=window.MallMateBottomNav.mount(bottomNav,{onSelect:id=>{if(id==='map'){state.selected=null;state.navigation=null;}go(id);}});
 if(reuseVoice)voiceView.sync();else bindVoice();
 document.querySelectorAll('[data-replace-store]').forEach(b=>b.onclick=()=>replaceStore(b.dataset.replaceStore));
 if(document.querySelector('.recommendations-comparison'))recommendationPosition.mode='compare';
 const recommendationTrack=document.querySelector('.recommendations-track');if(recommendationTrack&&window.MallMateRecommendationCarousel)swipeDisposers.push(window.MallMateRecommendationCarousel.mount(recommendationTrack,{position:recommendationPosition}));
 document.querySelectorAll('[data-remove-exclusion]').forEach(b=>b.onclick=()=>{invalidatePending();if(aiMode==='ai'){send('Remove exclusion for '+b.dataset.removeExclusion,{source:'card'});return;}discovery().excludedTerms=discovery().excludedTerms.filter(t=>t!==b.dataset.removeExclusion);save();render();});
 document.querySelectorAll('[data-refine]').forEach(b=>b.onclick=()=>{if(b.dataset.refine==='different'){showOtherOptions();}else{chatDraft=window.MallMateUILanguage?.language()==='zh'?'我的预算不超过 ':'My budget is under ';render();document.getElementById('need')?.focus();}});
 document.getElementById('need')?.addEventListener('input',e=>{voiceController?.cancel();chatDraft=e.target.value;syncComposer();});
 const chatForm=document.getElementById('chat-form');if(chatForm)chatForm.onsubmit=e=>{e.preventDefault();send(new FormData(e.target).get('need'));};
 document.getElementById('ai-key-form')?.addEventListener('submit',async e=>{e.preventDefault();const form=e.target,b=form.querySelector('button');b.disabled=true;try{await api('/api/ai/config',{method:'POST',body:JSON.stringify({key:new FormData(form).get('key'),provider:new FormData(form).get('provider')})});aiConfigured=true;aiProvider=new FormData(form).get('provider')==='course'?'Course DeepSeek':'DeepSeek';aiMode='ai';error='';notice='Key saved locally. Send a message to test the live connection.';render();}catch(err){error=err.message;render();}});
 document.getElementById('edit-form')?.addEventListener('submit',async e=>{e.preventDefault();const f=new FormData(e.target),form=e.target,button=form.querySelector('button[type=submit],button.primary');button.disabled=true;try{const data={name:f.get('name'),category:f.get('category'),min:Number(f.get('min')),max:Number(f.get('max')),hours:f.get('hours')};M.editStore([{...data,id:'check'}],'check',{...data,quiet:false});await api(editing==='new'?'/api/stores':'/api/stores/'+encodeURIComponent(editing),{method:editing==='new'?'POST':'PATCH',body:JSON.stringify(data)});catalogue.invalidate();await refreshStores();page='merchant';error='';notice='Saved to Softr. The same database records appear in the shopper view.';await refreshMerchant();}catch(e){error=e.message;render();}});
 document.getElementById('amount-form')?.addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.target);attempt(()=>{const min=Number(f.get('min')),max=Number(f.get('max'));M.eventsInRange(state.events,min,max);state.amountMin=min;state.amountMax=max;save();render();});});
 document.getElementById('feedback-form')?.addEventListener('submit',async e=>{e.preventDefault();const form=e.target,button=form.querySelector('button.primary'),f=new FormData(form);if(!state.navigation||!state.arrival){error='Start a route and confirm arrival first.';render();return}if(state.events.some(x=>x.type==='feedback'&&x.arrival===state.arrival)){error='Feedback already saved for this arrival.';render();return}button.disabled=true;try{state.journeyKey=state.journeyKey||crypto.randomUUID();save();await api('/api/feedback',{method:'POST',body:JSON.stringify({key:state.journeyKey,storeId:state.selected,context:state.context,mode:state.navigation.mode,rating:f.get('rating'),comment:f.get('comment')})});record('feedback',state.selected,{rating:f.get('rating'),comment:f.get('comment'),arrival:state.arrival});notice='Demo feedback saved to Softr with store, visit and context.';error='';render()}catch(err){button.disabled=false;let m=document.getElementById('feedback-error');if(!m){m=document.createElement('p');m.id='feedback-error';m.className='error';form.prepend(m)}m.textContent=err.message+'; try again. Your entered feedback is retained.'}});
 document.querySelectorAll('[data-action]').forEach(b=>b.onclick=()=>attempt(()=>{switch(b.dataset.action){case'login':authScreen();break;case'logout':signOut();break;case'toggle-ai':aiMode=aiMode==='ai'?'rules':'ai';render();break;case'add-store':editing='new';go('editor');break;case'arrive':state.arrival=Date.now();state.journeyKey=crypto.randomUUID();record('arrival_confirmed');go('arrival');break;case'undo-skip':{invalidatePending();const d=discovery();d.excludedStoreIds=d.excludedStoreIds.filter(id=>!(d.lastSkippedIds||[d.lastSkippedId]).includes(id));if(d.undoSelections)d.selections=d.undoSelections;d.undoSelections=null;d.lastSkippedId=null;d.lastSkippedIds=[];save();render();break;}case'clear-chat':invalidatePending();chatEpoch++;aiBusy=false;state.discovery=null;chatDraft='';state.context=M.fresh().context;state.messages=[];state.navigation=null;save();render();break;case'reset':{invalidatePending();chatEpoch++;aiBusy=false;chatDraft='';const stores=state.stores;state=freshState();state.stores=stores;state.selected=null;save();page='browse';notice='Local demo context reset; Softr records were not deleted.';render();break;}case'export':{const data={scope:'local demo only, not real customer evidence',stores:state.stores,events:state.events},url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'})),a=document.createElement('a');a.href=url;a.download='MallMate_Local_Demo_Data.json';a.click();URL.revokeObjectURL(url);break;}}}));
}

const overlay=document.createElement('div');overlay.id='connection-overlay';overlay.style.display='none';document.body.appendChild(overlay);
function connectionScreen(message,askToken=false){voiceController?.dispose();voiceController=null;voiceView?.dispose();voiceView=null;if(!developerMode||currentUser?.guest)askToken=false;overlay.style.display='grid';overlay.innerHTML=`<div class="connection-panel"><div class="brand">Mall<span>Mate</span></div><h1>Softr database connection</h1><p>${h(message)}</p>${askToken?`<form id="token-form"><label for="token">Softr API token</label><input id="token" name="token" type="password" autocomplete="off" required><button class="primary">Connect on this computer</button></form><p class="small">The token is saved in this Mac’s Keychain and used only by the local server.</p>`:'<button class="secondary" id="retry">Retry connection</button>'+(!developerMode?'':currentUser?.guest?'<button class="link" id="connection-login">Sign in to manage settings</button>':'<button class="link" id="configure">Configure token</button>')}</div>`;window.MallMateUILanguage?.apply(overlay);document.getElementById('connection-login')?.addEventListener('click',()=>authScreen());document.getElementById('retry')?.addEventListener('click',()=>startConnected());document.getElementById('configure')?.addEventListener('click',()=>connectionScreen('Paste your Softr API token to connect the existing Stores table.',true));document.getElementById('token-form')?.addEventListener('submit',async e=>{e.preventDefault();let f=new FormData(e.target);try{await api('/api/config',{method:'POST',body:JSON.stringify({token:f.get('token')})});await startConnected()}catch(err){connectionScreen(err.message,true)}});}
async function api(url,options={}){if(currentUser?.guest&&/^\/api\/(?:stores$|ai\/(?:status|chat)$)/.test(url))url=url.replace('/api/','/api/public/');let r=await fetch(url,{...options,headers:{'Content-Type':'application/json'}}),data=await r.json();if(!r.ok)throw Error(data.error||'Database request failed');return data;}
function val(fields,name){let k=Object.keys(fields).find(k=>k.toLowerCase().replace(/[^a-z]/g,'')===name.toLowerCase().replace(/[^a-z]/g,''));let v=fields[k];if(v&&typeof v==='object')v=v.name??v.value??v.label??(Array.isArray(v)?v[0]:undefined);return v}
function normalizeRecord(r){return window.MallMateStoreAdapter.normalizeRecord(r);}
async function refreshMerchant(){merchantLoading=true;render();try{merchantStoreIds=(await api('/api/merchant/stores')).storeIds;await refreshFeedback()}catch(e){merchantStoreIds=[];remoteFeedback=[];error=e.message}finally{merchantLoading=false;if(page==='merchant')render()}}
async function refreshFeedback(){try{const x=await api('/api/feedback');remoteFeedback=x.records;if(page==='merchant')render()}catch(e){remoteFeedback=[];if(page==='merchant'){error='Could not load Softr feedback: '+e.message;render()}}}
async function refreshStores(){window.MallMateIndoorMap.preload().catch(()=>{});const data=await catalogue.load();state.stores=data.records.map(normalizeRecord);state.navigation=null;save()}
function applyUser(user){invalidatePending();chatDraft='';aiBusy=false;currentUser=user;window.MallMatePublicMode=!!user.guest;KEY='mallmate-local-user-'+user.username;state=freshState();try{Object.assign(state,window.MallMateVisit.load({local:localStorage,session:sessionStorage,key:KEY,fresh:freshState}));}catch{notice='Saved visit could not be restored. Starting a new visit.';}page='chat';directoryState={query:'',facet:'all',scrollY:0};remoteFeedback=[];merchantStoreIds=[];}

function authScreen(register=false,message=''){if(!developerMode){go('settings');return;}voiceController?.dispose();voiceController=null;voiceView?.dispose();voiceView=null;overlay.style.display='grid';overlay.innerHTML=`<div class="connection-panel"><div class="brand">Mall<span>Mate</span></div><h1>${register?'Create your account':'Welcome back'}</h1><p>This demo account is stored on this computer.</p>${message?`<p class="error">${h(message)}</p>`:''}<form id="auth-form"><label for="username">Username</label><input id="username" name="username" autocomplete="username" pattern="[A-Za-z0-9_]{3,24}" minlength="3" maxlength="24" required><label for="password">Password</label><input id="password" name="password" type="password" autocomplete="${register?'new-password':'current-password'}" minlength="8" maxlength="128" required><button class="primary">${register?'Create account & sign in':'Sign in'}</button></form><button class="secondary" id="auth-switch">${register?'Already registered? Sign in':'New here? Create an account'}</button><p class="small">Accounts and password hashes are stored on this computer. This is not a Softr account; each signed-in local account can manage only its own newly created demo stores.</p></div>`;const back=document.createElement('button');back.className='link';back.textContent='Continue browsing';back.onclick=()=>{overlay.style.display='none';if(currentUser)render();else startConnected();};overlay.querySelector('.connection-panel').appendChild(back);window.MallMateUILanguage?.apply(overlay);document.getElementById('auth-switch').onclick=()=>authScreen(!register);document.getElementById('auth-form').onsubmit=async e=>{e.preventDefault();const f=new FormData(e.target),b=e.target.querySelector('button');b.disabled=true;try{const result=await api('/api/auth/'+(register?'register':'login'),{method:'POST',body:JSON.stringify({username:f.get('username'),password:f.get('password')})});applyUser(result.user);await startConnected(true)}catch(err){authScreen(register,err.message)}}}
async function signOut(){voiceController?.dispose();voiceController=null;voiceView?.dispose();voiceView=null;chatEpoch++;chatDraft='';aiBusy=false;try{await api('/api/auth/logout',{method:'POST',body:'{}'});applyUser({username:'guest',guest:true});await startConnected(true);}catch(e){error='Could not sign out. Try again.';render();}}

function bindMapNavigation(link){
 const status=link.previousElementSibling;
 let timer=0;
 const clear=()=>{clearTimeout(timer);status.textContent='';};
 const onVisibilityChange=()=>{if(document.hidden)clear();};
 const onClick=()=>{
  clear();
  attachArReturn(link);
  // A custom URL scheme provides no result to the page. Offer help if it stays visible.
  timer=setTimeout(()=>{
   if(!document.hidden&&status.isConnected)status.textContent=status.dataset.message;
  },1000);
 };
 link.addEventListener('click',onClick);
 document.addEventListener('visibilitychange',onVisibilityChange);
 window.addEventListener('pagehide',clear);
 return ()=>{
  clear();
  link.removeEventListener('click',onClick);
  document.removeEventListener('visibilitychange',onVisibilityChange);
  window.removeEventListener('pagehide',clear);
 };
}
function attachArReturn(link){
 if(!currentUser?.guest||state.source!=='chat'||!discovery().selections?.length)return;
 const target=new URL(link.href),returnUrl=target.searchParams.get('return');
 if(target.protocol!=='mallmate-route:'||!returnUrl)return;
 try{
  const callback=new URL(returnUrl);
  if(callback.origin!==location.origin)return;
  const visit=sessionStorage.getItem(KEY+':visit:v1');
  if(!visit)return;
  const now=Date.now(),token=crypto.randomUUID();
  // Store only the visit being handed off, and remove the copy as soon as it is restored.
  for(const key of Object.keys(localStorage).filter(key=>key.startsWith(arReturnPrefix))){
   const raw=localStorage.getItem(key);
   try{if(!raw||JSON.parse(raw)?.expires<=now)localStorage.removeItem(key);}
   catch{localStorage.removeItem(key);}
  }
  localStorage.setItem(arReturnPrefix+token,JSON.stringify({
   storeId:state.selected,visit,position:chatPosition(),detailScroll,expires:now+arReturnLifetimeMs
  }));
  callback.hash='return-'+token;
  target.searchParams.set('return',callback.href);
  link.href=target.href;
 }catch{}
}
function restoreArReturn(selected){
 const token=location.hash.match(arReturnHash)?.[1];
 if(!token||!currentUser?.guest||!selected)return false;
 const key=arReturnPrefix+token,url=new URL(location.href);
 try{
  const handoff=JSON.parse(localStorage.getItem(key));
  if(!handoff||handoff.storeId!==selected.id||!(handoff.expires>Date.now())||typeof handoff.visit!=='string')return false;
  const restored=window.MallMateVisit.load({local:localStorage,session:{getItem:()=>handoff.visit},key:KEY,fresh:freshState});
  if(!restored.discovery.selections.some(item=>item.storeId===selected.id))return false;
  Object.assign(state,{context:restored.context,messages:restored.messages,discovery:restored.discovery,source:'chat'});
  applyChatPosition(handoff.position);
  if(handoff.detailScroll?.storeId===selected.id)detailScroll=handoff.detailScroll;
  localStorage.removeItem(key);
 }catch{return false;}
 url.hash='';
 const base=new URL(url);
 base.searchParams.delete('screen');base.searchParams.delete('store');
 history.scrollRestoration='manual';
 history.replaceState({mallMateStoreView:{page:'chat',storeId:null,source:'chat',position:chatPosition()}},'',base);
 base.searchParams.set('screen','detail');base.searchParams.set('store',selected.id);
 history.pushState({mallMateStoreView:{page:'detail',storeId:selected.id,source:'chat',back:'chat'}},'',base);
 history.pushState({mallMateStoreView:{page:'map',storeId:selected.id,source:'chat',back:'detail'}},'',url);
 return true;
}
function restoreStoreView(){
 const params=new URLSearchParams(location.search),screens=params.getAll('screen');
 if(screens.length!==1||!['detail','map'].includes(screens[0]))return;
 const languages=params.getAll('lang');
 if(languages.length===1&&['en','zh'].includes(languages[0]))window.MallMateUILanguage?.setLanguage(languages[0]);
 const ids=params.getAll('store'),id=ids.length===1?ids[0]:null;
 const selected=screens.length===1&&id&&id.length<=200?state.stores.find(item=>item.id===id):null;
 const entry=history.state?.mallMateStoreView;
 if(screens[0]==='map'&&restoreArReturn(selected)){state.source='chat';}
 else if(entry?.storeId===selected?.id&&entry?.source)state.source=entry.source;
 else if(state.selected!==selected?.id)state.source='browse';
 state.selected=selected?.id??null;state.navigation=null;page=selected?screens[0]:'detail';save();
}
async function startConnected(knownUser=false){try{if(!knownUser){if(developerMode){const x=await api('/api/auth/me');applyUser(x.user||{username:'guest',guest:true});if(!x.user){authScreen();return;}}else applyUser({username:'guest',guest:true});}const stores=refreshStores();if(page==='chat')voiceCues?.prepare();await stores;restoreStoreView();try{const speech=await api('/api/public/speech/status');localSpeechReady=speech.configured===true;acceptsWebmOpus=speech.inputAudioFormats?.includes('webm-opus')===true;window.MallMateSpeechTransport=speech.transport;window.MallMateSpeechMaxRecordingSeconds=speech.maxRecordingSeconds;}catch{localSpeechReady=false;acceptsWebmOpus=false;window.MallMateSpeechTransport=null;window.MallMateSpeechMaxRecordingSeconds=undefined;}try{const a=await api('/api/ai/status');aiConfigured=a.configured;aiProvider=a.provider;aiMode=aiConfigured?'ai':'rules'}catch{aiConfigured=false}overlay.style.display='none';error='';notice='';render();if(!developerMode&&typeof window!=='undefined')window.MallMateArrival?.mount({onEnter:()=>{go('chat');if(prepareMicrophoneAtEntry&&localSpeechReady&&window.MallMateSpeechTransport==='websocket')return window.MallMateEntryMicrophone?.prepare();}});}catch(e){if(!currentUser&&developerMode)authScreen(false,e.message);else connectionScreen(e.message,/token/i.test(e.message))}}
startConnected();
