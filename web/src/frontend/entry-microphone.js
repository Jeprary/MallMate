// Optional advance permission. Only a press on the voice control may claim audio.
(function(root){
 'use strict';
 let pending=null;
 function prepare(){
  const media=root.navigator?.mediaDevices;
  if(!media?.getUserMedia)return;
  if(pending)return pending.settled;
  const attempt={claimed:false};
  attempt.stream=media.getUserMedia({audio:{channelCount:1},video:false}).then(stream=>{
   if(!attempt.claimed)stream.getTracks().forEach(track=>track.stop());
   return stream;
  });
  attempt.settled=attempt.stream.then(clear,clear);
  pending=attempt;
  function clear(){if(pending===attempt)pending=null;}
  return attempt.settled;
 }
 function getUserMedia(constraints){
  if(pending&&!pending.claimed){pending.claimed=true;return pending.stream;}
  return root.navigator.mediaDevices.getUserMedia(constraints);
 }
 root.MallMateEntryMicrophone={prepare,getUserMedia};
})(typeof window!=='undefined'?window:globalThis);
