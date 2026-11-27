'use strict';
// Select a human utterance, never classify its language or consult UI preferences.
// Legacy source-less user messages remain eligible; known card labels do not.
function human(value){
 return value&&['voice','text',undefined].includes(value.source)&&typeof value.text==='string'&&value.text.trim();
}
function derive(input={}){
 if(human(input))return Object.freeze({text:input.text,source:input.source??'legacy',origin:'current'});
 const history=Array.isArray(input.history)?input.history:[];
 for(let i=history.length-1;i>=0;i--){
  const message=history[i];
  if(message?.role==='user'&&human(message))return Object.freeze({text:message.text,source:message.source??'legacy',origin:'history'});
 }
 // Bounded request history may no longer contain a human turn. Do not invent
 // a remembered language or promote the current automatic card label to one.
 return Object.freeze({text:null,source:null,origin:'unavailable'});
}
module.exports={derive};
