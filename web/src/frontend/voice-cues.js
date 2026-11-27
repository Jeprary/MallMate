// Short local earcons; no downloaded audio or speech synthesis.
(function(root){
 'use strict';
 function create({AudioContext=root.AudioContext||root.webkitAudioContext}={}){
  let context=null,last=null,ready=null,waiting=null;
  function prepare(){
   try{
    if(!context||context.state==='closed')context=new AudioContext();
    return context;
   }catch{}
  }
  function prime(){
   const audio=prepare();
   if(audio&&audio.state!=='running'){
    try{ready=Promise.resolve(audio.resume()).catch(()=>{});}catch{}
   }
   return audio;
  }
  function play(kind){
   if(kind==='stop'&&last!=='start')return;
   if(kind===last)return;last=kind;
   const current=context;
   const emit=()=>{
    try{
     if(context!==current||last!==kind||context?.state!=='running')return;
     const start=context.currentTime;
     if(kind==='success'){note(660,660,start,.025);note(880,880,start+.055,.018);}
     else if(kind==='start'){note(740,740,start,.035);note(940,940,start+.08,.035);}
     else note(520,390,start,.035);
    }catch{}
   };
   if(context?.state==='running')emit();
   else if(kind==='start')ready?.then(emit);
  }
  function note(from,to,start,volume){
   const osc=context.createOscillator(),gain=context.createGain();
   osc.type='sine';osc.frequency.setValueAtTime(from,start);osc.frequency.exponentialRampToValueAtTime(to,start+.07);
   gain.gain.setValueAtTime(0,start);gain.gain.linearRampToValueAtTime(volume,start+.008);gain.gain.exponentialRampToValueAtTime(.0001,start+.075);
   osc.connect(gain);gain.connect(context.destination);osc.onended=()=>{osc.disconnect();gain.disconnect();};osc.start(start);osc.stop(start+.08);
  }
  function beginWait(){
   endWait();
   const wait={};waiting=wait;
   const emit=()=>{
    if(waiting!==wait||context?.state!=='running')return;
    try{
     const start=context.currentTime,osc=context.createOscillator(),gain=context.createGain();
     wait.osc=osc;wait.gain=gain;
     osc.frequency.setValueAtTime(385,start);
     osc.frequency.exponentialRampToValueAtTime(450,start+.55);
     gain.gain.setValueAtTime(0,start);
     gain.gain.linearRampToValueAtTime(.023,start+.018);
     gain.gain.exponentialRampToValueAtTime(.0001,start+.8);
     osc.connect(gain);gain.connect(context.destination);
     osc.onended=()=>{osc.disconnect();gain.disconnect();if(waiting===wait)waiting=null;};
     osc.start(start);osc.stop(start+.82);
    }catch{}
   };
   if(context?.state==='running')emit();else ready?.then(emit);
  }
  function endWait(){
   const wait=waiting;waiting=null;
   if(!wait?.osc)return;
   try{const now=context.currentTime;wait.gain.gain.cancelAndHoldAtTime(now);wait.gain.gain.linearRampToValueAtTime(0,now+.02);wait.osc.stop(now+.025);}catch{try{wait.osc.stop();}catch{}}
  }
  function reset(){endWait();last=null;}
  function dispose(){endWait();try{context?.close()?.catch?.(()=>{});}catch{}context=null;last=null;}
  return {prepare,prime,beginWait,endWait,play,reset,dispose};
 }
 const api={create};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateVoiceCues=api;
})(typeof window!=='undefined'?window:globalThis);
