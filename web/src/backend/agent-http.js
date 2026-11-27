'use strict';
const crypto=require('node:crypto');
function failure(error,aborted){
 if(aborted)return {code:'CANCELLED',retryable:false};
 const status=error?.providerStatus;
 if(status===402)return {code:'PROVIDER_BALANCE',retryable:false,providerStatus:402};
 if(status===401||status===403)return {code:'PROVIDER_AUTH',retryable:false,providerStatus:status};
 if(status===429)return {code:'PROVIDER_BUSY',retryable:true,providerStatus:429};
 if(error?.code==='AGENT_VALIDATION')return {code:'AGENT_VALIDATION',retryable:true};
 if(error?.code==='AGENT_NO_PROGRESS')return {code:'AGENT_NO_PROGRESS',retryable:true};
 if(error?.reviewGate)return {code:'AGENT_REVIEW_CHECK',retryable:true};
 return {code:'AGENT_FAILED',retryable:true};
}
async function streamTurn(req,res,{input,AI,loadCatalogue,publicStores,manifest,tracking,diagnostic=value=>console.error(JSON.stringify(value))}){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),60000),requestId=crypto.randomUUID();let seq=0;
 const close=()=>{if(!res.writableEnded)controller.abort();};res.on('close',close);
 res.writeHead(200,{'Content-Type':'application/x-ndjson; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','X-Accel-Buffering':'no'});res.flushHeaders?.();
 let terminalResult;
 function emit(event){if(event.type==='result')terminalResult=event.result;if(!res.destroyed&&!res.writableEnded)res.write(JSON.stringify({...event,requestId,seq:++seq})+'\n');}
 async function track(method,value){
  try{await tracking?.[method]?.(value,requestId);}catch{try{diagnostic({event:'recommendation_tracking_failed',requestId});}catch{}}
 }
 try{
  emit({type:'status',text:/[\u3400-\u9fff]/.test(input.text)?'正在查找合适的选择…':'Finding suitable options…'});
  const result=await AI.agentTurn(input,{loadCatalogue,publicStores,manifest,emit,signal:controller.signal});
  if(result||terminalResult)await track('finish',result||terminalResult);
 }catch(error){
  const info=failure(error,controller.signal.aborted);
  // Log correlation and an allowlisted category, never provider bodies, user text or credentials.
  const progressReason=info.code==='AGENT_NO_PROGRESS'?(error.validationReason||error.message):null;
  try{diagnostic({event:'agent_turn_failed',at:new Date().toISOString(),stage:'recommendation',requestId,...info,...(typeof progressReason==='string'?{validationReason:progressReason.slice(0,500)}:{})});}catch{}
  const zh=/[\u3400-\u9fff]/.test(input.text);
  const text=error?.reviewGate
   ?(zh?'暂时查不到店铺评论，可以先浏览店铺。':'Store reviews are temporarily unavailable. You can still browse stores.')
   :(zh?'这次查找没有完成，请重试或浏览店铺。':'Could not finish this search. Please retry or browse stores.');
  emit({type:'error',...info,text});
  await track('fail',info.code);
 }finally{clearTimeout(timer);res.off('close',close);emit({type:'done'});if(!res.destroyed&&!res.writableEnded)res.end();}
}
module.exports={streamTurn,failure};
