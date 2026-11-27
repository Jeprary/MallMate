'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto'),{spawn}=require('node:child_process'),readline=require('node:readline');
const MAX_BYTES=6*1024*1024;
const formats={'audio/webm':'matroska','audio/ogg':'ogg','audio/wav':'wav','audio/x-wav':'wav','audio/mp4':'mov','audio/x-m4a':'mov','audio/mpeg':'mp3','audio/aac':'aac','audio/flac':'flac'};
function create({root=path.resolve(__dirname,'../..'),reply}={}){
 const home=path.join(root,'.local-speech'),python=path.join(home,'venv/bin/python'),modelRoot=path.join(home,'models'),ffmpeg=process.env.MALLMATE_FFMPEG||'/usr/local/bin/ffmpeg';
 let worker=null,workerSignature='',waiting=null,busy=false,activeDirectory=null;
 function modelPath(dir=modelRoot,depth=0){
  try{
   if(['model.bin','config.json','tokenizer.json'].every(name=>fs.existsSync(path.join(dir,name))))return dir;
   if(depth<6)for(const item of fs.readdirSync(dir,{withFileTypes:true}))if(item.isDirectory()){const found=modelPath(path.join(dir,item.name),depth+1);if(found)return found;}
  }catch{}
  return null;
 }
 function backend(){
  let config={};try{config=JSON.parse(fs.readFileSync(path.join(home,'config.json'),'utf8'));}catch{}
  const selected=(process.env.MALLMATE_SPEECH_PROVIDER||config.provider)==='qwen'
   ?{python:path.join(home,'venv-qwen-arm64/bin/python'),model:path.join(modelRoot,'qwen3-asr-1.7b-bf16'),engine:'qwen',provider:'local-qwen3-asr',name:'Qwen3-ASR-1.7B'}
   :{python,model:modelPath(),engine:'whisper',provider:'local-whisper',name:'Whisper base'};
  return {...selected,python:process.env.MALLMATE_SPEECH_PYTHON||selected.python,model:process.env.MALLMATE_SPEECH_MODEL_PATH||selected.model};
 }
 function status(){const b=backend(),modelReady=b.model&&(b.engine==='qwen'?fs.existsSync(path.join(b.model,'model.safetensors')):modelPath(b.model,6)===b.model);return {configured:!!(fs.existsSync(b.python)&&fs.existsSync(ffmpeg)&&modelReady),provider:b.provider,model:b.name};}
 function stop(){const child=worker;worker=null;workerSignature='';if(child){try{process.kill(-child.pid,'SIGKILL');}catch{child.kill('SIGKILL');}}}
 function fail(message='Speech recognition failed. Please try again.'){
  if(waiting){const task=waiting;waiting=null;clearTimeout(task.timer);task.reject(Error(message));}
 }
 function start(){
  const b=backend(),signature=b.engine+':'+b.model;
  if(worker&&workerSignature===signature)return worker;
  if(worker)stop();
  if(!b.model)throw Error('Local speech model is not ready.');
  const child=spawn(b.python,['-u',path.join(root,'src/backend/local-speech-worker.py'),b.model,ffmpeg,b.engine],{cwd:root,detached:true,stdio:['pipe','pipe','ignore'],env:{...process.env,HF_HUB_OFFLINE:'1',TRANSFORMERS_OFFLINE:'1',HF_HUB_DISABLE_TELEMETRY:'1',PYTHONDONTWRITEBYTECODE:'1'}});
  worker=child;workerSignature=signature;
  const lines=readline.createInterface({input:child.stdout});
  lines.on('line',line=>{
   if(child!==worker||!waiting)return;
   let result;try{result=JSON.parse(line);}catch{return;}
   if(result.id!==waiting.id)return;
   const task=waiting;waiting=null;clearTimeout(task.timer);
   if(result.error){const messages={invalid_audio:'The recording is invalid or could not be decoded.',too_long:'Please record no more than 30 seconds.',no_speech:'No speech was detected. Please try again.',unavailable:'Local speech recognition is unavailable.'};const error=Error(messages[result.error]||'Speech recognition failed. Please try again.');error.code=result.error;error.status=result.error==='unavailable'?503:422;task.reject(error);}
   else if(typeof result.text==='string'&&result.text.trim()&&result.text.length<=5000)task.resolve({text:result.text.trim(),language:typeof result.language==='string'?result.language:'',provider:b.provider});
   else task.reject(Error('Speech recognition returned an invalid result.'));
  });
  child.on('error',()=>{if(child===worker){worker=null;fail('Local speech recognition is unavailable.');}});
  child.on('exit',()=>{lines.close();if(child===worker){worker=null;fail();}});
  child.stdin.on('error',()=>{if(child===worker){fail();stop();}});
  return child;
 }
 function transcribe(file,format,language,owner){
  const child=start(),id=crypto.randomUUID();
  return new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{if(waiting?.id===id){fail('Speech recognition timed out. Please try again.');stop();}},120000);
   waiting={id,owner,resolve,reject,timer};
   child.stdin.write(JSON.stringify({id,file,format,language})+'\n',error=>{if(error&&waiting?.id===id){fail();stop();}});
  });
 }
 function readAudio(req){return new Promise((resolve,reject)=>{
  let size=0,chunks=[],done=false;
  const finish=(error,value)=>{if(done)return;done=true;clearTimeout(timer);req.removeListener('data',data);req.removeListener('end',end);req.removeListener('error',failed);req.removeListener('aborted',aborted);chunks=[];if(error){req.resume();reject(error);}else resolve(value);};
  const bad=(message,status)=>Object.assign(Error(message),{status});
  const data=chunk=>{size+=chunk.length;if(size>MAX_BYTES)return finish(bad('Recording exceeds the 6 MB limit.',413));chunks.push(chunk);};
  const end=()=>finish(size?null:bad('The recording is empty.',400),Buffer.concat(chunks));
  const failed=()=>finish(bad('Recording upload failed.',400)),aborted=()=>finish(bad('Recording upload was cancelled.',400));
  const timer=setTimeout(()=>finish(bad('Recording upload timed out.',408)),30000);
  req.on('data',data);req.on('end',end);req.on('error',failed);req.on('aborted',aborted);
 });}
 async function handle(req,res,url){
  if(req.method==='GET'&&url.pathname==='/api/public/speech/status'){reply(res,200,status());return true;}
  if(req.method!=='POST'||url.pathname!=='/api/public/speech/transcribe')return false;
  if(busy){req.resume();reply(res,429,{error:'Speech recognition is busy. Please try again.'},{'Retry-After':'2'});return true;}
  const format=formats[String(req.headers['content-type']||'').split(';')[0].trim().toLowerCase()];
  const requested=String(url.searchParams.get('lang')||req.headers['x-speech-language']||'auto').toLowerCase();
  // Legacy language hints stay valid, but public transcription always preserves automatic detection.
  const validLanguage=requested==='auto'||/^zh(?:-|$)/.test(requested)||/^en(?:-|$)/.test(requested);
  if(!format||!validLanguage){req.resume();reply(res,400,{error:'Use a supported audio format and auto, zh or en language.'});return true;}
  if(Number(req.headers['content-length'])>MAX_BYTES){req.resume();reply(res,413,{error:'Recording exceeds the 6 MB limit.'});return true;}
  if(!status().configured){req.resume();reply(res,503,{error:'Local speech model is not ready.'});return true;}
  busy=true;let directory,result,responseStatus=200;const owner={cancelled:false};
  const disconnected=()=>{
   if(res.writableFinished)return;
   owner.cancelled=true;
   if(waiting?.owner===owner){fail('Recording request was cancelled.');stop();}
  };
  res.on('close',disconnected);
  try{
   const audio=await readAudio(req);
   if(owner.cancelled)throw Error('Recording request was cancelled.');
   directory=await fs.promises.mkdtemp(path.join(os.tmpdir(),'mallmate-speech-'));activeDirectory=directory;await fs.promises.chmod(directory,0o700);
   const file=path.join(directory,'recording');await fs.promises.writeFile(file,audio,{mode:0o600});
   if(owner.cancelled)throw Error('Recording request was cancelled.');
   result=await transcribe(file,format,null,owner);
  }catch(error){responseStatus=error.status||503;result={error:error.status?error.message:'Local speech recognition failed. Please try again.',code:error.code||'local-service-error'};}
  finally{if(directory)await fs.promises.rm(directory,{recursive:true,force:true}).catch(()=>{});activeDirectory=null;busy=false;res.removeListener('close',disconnected);}
  if(!owner.cancelled&&!res.destroyed)reply(res,responseStatus,result);
  return true;
 }
 function close(){fail();stop();}
 function cleanup(){stop();if(activeDirectory){try{fs.rmSync(activeDirectory,{recursive:true,force:true});}catch{}}}
 process.once('exit',cleanup);
 process.once('SIGTERM',()=>{cleanup();process.exit(143);});
 process.once('SIGINT',()=>{cleanup();process.exit(130);});
 return {handle,status,close};
}
module.exports={create};
