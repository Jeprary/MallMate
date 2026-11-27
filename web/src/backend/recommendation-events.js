// Anonymous interaction metadata and a durable outbox. Never stores prompts or identity data.
'use strict';
const fs=require('node:fs/promises'),path=require('node:path'),crypto=require('node:crypto');
const COOKIE='mallmate_recommendation',ID=/^[A-Za-z0-9_-]{8,100}$/,TOKEN=/^[a-f0-9]{64}$/;
const CLIENT_TYPES=new Set(['card_browse','replace_store','selection','selection_cancelled','feedback']);
const SERVER_TYPES=new Set(['recommendation','clarification','replacement_applied','replacement_cancelled','turn_failed']);
const hash=value=>crypto.createHash('sha256').update(value).digest('hex');
const stable=value=>JSON.stringify(Object.fromEntries(Object.entries(value).sort(([a],[b])=>a.localeCompare(b))));
const issue=(status,message)=>Object.assign(Error(message),{status});
function preferenceEffect(type){return ({card_browse:'none',replace_store:'temporary',selection:'explicit_selection',selection_cancelled:'retraction',feedback:'evaluation'})[type]||'none';}
function create({root,dataDir,secureCookie=false,loadCatalogue,body,reply,getToken=()=>'',fetcher=fetch,cloudConfig,sink,now=Date.now}={}){
 if(!root||typeof loadCatalogue!=='function')throw Error('Recommendation events need a storage root and catalogue.');
 const storage=dataDir||path.join(root,'.local-data');
 const directory=path.join(storage,'recommendation-sessions'),configFile=path.join(storage,'recommendation-events-cloud.json');
 const queues=new Map(),syncing=new Map(),schemas=new Map();
 const filename=id=>path.join(directory,id+'.json');
 async function read(id){try{return JSON.parse(await fs.readFile(filename(id),'utf8'));}catch(error){if(error.code==='ENOENT')throw issue(404,'Session not found.');throw error;}}
 async function write(session){
  await fs.mkdir(directory,{recursive:true,mode:0o700});const file=filename(session.sessionId),tmp=file+'.'+crypto.randomUUID()+'.tmp';
  const handle=await fs.open(tmp,'wx',0o600);
  try{await handle.writeFile(JSON.stringify(session));await handle.sync();}finally{await handle.close();}
  await fs.rename(tmp,file);const dir=await fs.open(directory,'r');try{await dir.sync();}finally{await dir.close();}
 }
 async function reclaim(lock,observed,priorOwner){
  // Elect one cleaner per inode. A delayed cleaner must never unlink the new
  // live lock that another process acquired after removing the stale one.
  const claim=lock+'.reap-'+observed.dev+'-'+observed.ino;
  // A PID symlink is intentionally dangling. Darwin link() follows that link,
  // so elect the cleaner with a separate atomic symlink instead of a hardlink.
  try{await fs.symlink(String(process.pid),claim);}catch(error){if(['EEXIST','ENOENT'].includes(error.code))return;throw error;}
  try{
   const current=await fs.lstat(lock);let owner;
   try{owner=await fs.readlink(lock);}catch(error){if(error.code!=='EINVAL')throw error;owner=await fs.readFile(lock,'utf8');}
   if(current.dev===observed.dev&&current.ino===observed.ino&&owner===priorOwner)await fs.unlink(lock);
  }catch(error){if(error.code!=='ENOENT')throw error;}
  finally{await fs.unlink(claim).catch(error=>{if(error.code!=='ENOENT')throw error;});}
 }
 async function serial(id,work){
  const previous=queues.get(id)||Promise.resolve(),current=previous.catch(()=>{}).then(async()=>{
   await fs.mkdir(directory,{recursive:true,mode:0o700});const lock=filename(id)+'.lock',started=Date.now();let locked=false;
   while(!locked){
    // The owner is created atomically with the lock, so a process cannot leave
    // an empty newly acquired lock by exiting between open and writing its PID.
    try{await fs.symlink(String(process.pid),lock);locked=true;}
    catch(error){if(error.code!=='EEXIST')throw error;
     try{
      const observed=await fs.lstat(lock);
      let raw;try{raw=await fs.readlink(lock);}catch(e){if(e.code!=='EINVAL')throw e;raw=await fs.readFile(lock,'utf8');}
      const owner=Number(raw);
      if(Number.isSafeInteger(owner)&&owner>0){try{process.kill(owner,0);}catch(e){if(e.code==='ESRCH')await reclaim(lock,observed,raw);}}
      else if(Date.now()-observed.mtimeMs>=5000)await reclaim(lock,observed,raw);
     }catch(e){if(e.code!=='ENOENT')throw e;}
     if(Date.now()-started>5000)throw Error('Session persistence is busy');await new Promise(resolve=>setTimeout(resolve,20));
    }
   }
   try{return await work();}finally{await fs.unlink(lock);}
  });queues.set(id,current);
  try{return await current;}finally{if(queues.get(id)===current)queues.delete(id);}
 }
 function credential(req){
  const authorization=req.headers?.authorization;
  if(authorization){const match=authorization.match(/^Bearer ([a-f0-9]{64})$/);return match?{token:match[1]}:null;}
  const raw=(req.headers?.cookie||'').split(';').map(x=>x.trim()).find(x=>x.startsWith(COOKIE+'='))?.slice(COOKIE.length+1),match=raw?.match(/^([A-Za-z0-9_-]{8,100})\.([a-f0-9]{64})$/);
  return match?{id:match[1],token:match[2]}:null;
 }
 async function authorize(req,id){
  if(!ID.test(id))throw issue(404,'Session not found.');const auth=credential(req);if(!auth||auth.id&&auth.id!==id)throw issue(404,'Session not found.');
  const session=await read(id),actual=hash(auth.token);
  if(!TOKEN.test(session.tokenHash||'')||!crypto.timingSafeEqual(Buffer.from(actual),Buffer.from(session.tokenHash)))throw issue(404,'Session not found.');
  return session;
 }
 function setCookie(res,id,token){
  const value=`${COOKIE}=${id}.${token}; HttpOnly; SameSite=Strict; Path=/api/public${secureCookie?'; Secure':''}`;
  const prior=res.getHeader?.('Set-Cookie');res.setHeader?.('Set-Cookie',prior?[...Array.isArray(prior)?prior:[prior],value]:value);
 }
 async function begin(req,res){
  const auth=credential(req);
  if(auth?.id)try{return {session:await authorize(req,auth.id)};}catch(error){if(error.status!==404)throw error;}
  const sessionId=crypto.randomUUID(),token=crypto.randomBytes(32).toString('hex'),session={schemaVersion:1,sessionId,tokenHash:hash(token),createdAt:new Date(now()).toISOString(),events:[]};
  await serial(sessionId,()=>write(session));setCookie(res,sessionId,token);return {session,token};
 }
 function publicEvent(event){
  const {softrStoreRecordIds,...metadata}=event.data;
  return {...metadata,preferenceEffect:preferenceEffect(event.data.type),cloud:{status:event.cloud.status,...(event.cloud.code?{code:event.cloud.code}:{})}};
 }
 function publicSession(session){return {sessionId:session.sessionId,createdAt:session.createdAt,events:session.events.map(publicEvent),storage:'local-durable',cloud:{saved:session.events.filter(e=>e.cloud.status==='saved').length,pending:session.events.filter(e=>e.cloud.status!=='saved').length}};}
 async function normalize(value,server=false){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!['eventId','type','source','storeIds','outcome','turnId','targetStoreId'].includes(k)))throw issue(400,'Invalid event fields.');
  const {eventId,type,source,storeIds=[],outcome=null,turnId=null,targetStoreId=null}=value;
  if(!ID.test(eventId||'')||!(CLIENT_TYPES.has(type)||server&&SERVER_TYPES.has(type))||!['text','voice','card','system'].includes(source)||!Array.isArray(storeIds)||storeIds.length>100||storeIds.some(id=>typeof id!=='string'||!/^[A-Za-z0-9_-]{1,200}$/.test(id))||new Set(storeIds).size!==storeIds.length||turnId!==null&&!ID.test(turnId))throw issue(400,'Invalid event.');
  if(CLIENT_TYPES.has(type)&&type!=='feedback'&&storeIds.length!==1)throw issue(400,'This operation needs one store.');
  if(type==='feedback'&&!['helpful','not_helpful'].includes(outcome)||type!=='feedback'&&outcome!==null&&!['failed','cancelled','applied','awaiting_answer','no_alternative'].includes(outcome))throw issue(400,'Invalid event outcome.');
  const catalogue=await loadCatalogue(),ids=new Set(catalogue.records.map(r=>r.id));if(targetStoreId!==null&&(typeof targetStoreId!=='string'||!ids.has(targetStoreId))||storeIds.some(id=>!ids.has(id)))throw issue(400,'Unknown published store.');
  const links=new Map((catalogue.softrLinks||[]).map(x=>[x.storeId,x.softrRecordId]));
  return {eventId,type,source,storeIds:[...storeIds],targetStoreId,softrStoreRecordIds:{stores:storeIds.map(id=>links.get(id)||null),target:targetStoreId?links.get(targetStoreId)||null:null},outcome,turnId};
 }
 async function append(id,value,server=false){
  const clean=await normalize(value,server);
  const result=await serial(id,async()=>{
   const session=await read(id),prior=session.events.find(e=>e.data.eventId===clean.eventId);
   // The event body is immutable; a retry must not reuse the ID for another action.
   const equalData=x=>{const {recordedAt,softrStoreRecordIds,...data}=x;return stable(data);};
   if(prior){if(equalData(prior.data)!==equalData(clean))throw issue(409,'Event ID already belongs to another operation.');return {event:publicEvent(prior),duplicate:true};}
   const event={data:{...clean,recordedAt:new Date(now()).toISOString()},cloud:{status:'pending'}};session.events.push(event);await write(session);return {event:publicEvent(event),duplicate:false};
  });
  void flush(id).catch(()=>{});return {...result,storage:'local-durable'};
 }
 async function config(){
  if(cloudConfig!==undefined)return cloudConfig;
  try{return JSON.parse(await fs.readFile(configFile,'utf8'));}catch(error){if(error.code==='ENOENT')return null;throw error;}
 }
 async function cloudRequest(config,route,options={}){
  const key=getToken();if(!key)throw Object.assign(Error('Softr credential unavailable'),{code:'SOFTR_NOT_CONFIGURED'});
  const url=`https://tables-api.softr.io/api/v1/databases/${config.databaseId}/tables/${config.tableId}${route}`;
  const response=await fetcher(url,{method:options.method||'GET',headers:{'Softr-Api-Key':key,'Content-Type':'application/json'},body:options.fields?JSON.stringify({fields:options.fields}):undefined,redirect:'error',signal:AbortSignal.timeout(20000)});
  if(!response.ok)throw Object.assign(Error('Softr write unavailable'),{code:response.status===401||response.status===403?'SOFTR_PERMISSION':'SOFTR_UNAVAILABLE'});
  const data=await response.json();return data;
 }
 async function saveCloud(sessionId,event){
  if(sink)return sink({sessionId,...event.data});
  const c=await config();if(!c||!ID.test(c.tableId||'')||!/^[-a-zA-Z0-9]+$/.test(c.databaseId||''))throw Object.assign(Error('Softr event table not configured'),{code:'SOFTR_TABLE_NOT_CONFIGURED'});
  const key=sessionId+':'+event.data.eventId;let offset=0,found=[];
  for(;;){const page=await cloudRequest(c,`/records?fieldNames=true&limit=100&offset=${offset}`);if(!Array.isArray(page.data))throw Error('Invalid event table records');found.push(...page.data.filter(r=>r.fields?.EventKey===key));offset+=page.data.length;if(!page.data.length||offset>=Number(page.metadata?.total??offset))break;}
  if(found.length>1)throw Object.assign(Error('Duplicate Softr event key'),{code:'SOFTR_EVENT_CONFLICT'});
  const fields={EventKey:key,SessionId:sessionId,EventType:event.data.type,InputSource:event.data.source,StoreKeys:JSON.stringify({stores:event.data.storeIds,target:event.data.targetStoreId}),SoftrStoreRecordIds:JSON.stringify(event.data.softrStoreRecordIds),Outcome:event.data.outcome||'',RecordedAt:event.data.recordedAt,SchemaVersion:1};
  let record=found[0];
  if(!record){
   const schemaKey=c.databaseId+'/'+c.tableId;
   if(!schemas.has(schemaKey)){
    const schema=(await cloudRequest(c,'')).data;
    if(!Array.isArray(schema?.fields))throw Object.assign(Error('Event schema unavailable'),{code:'SOFTR_SCHEMA_MISMATCH'});
    schemas.set(schemaKey,new Map(schema.fields.map(f=>[f.name,f.id])));
   }
   const fieldIds=schemas.get(schemaKey),writeFields={};
   for(const [name,value] of Object.entries(fields)){const id=fieldIds.get(name);if(!id){schemas.delete(schemaKey);throw Object.assign(Error('Event field missing'),{code:'SOFTR_SCHEMA_MISMATCH'});}writeFields[id]=value;}
   record=(await cloudRequest(c,'/records?fieldNames=true',{method:'POST',fields:writeFields})).data;
  }
  if(!record?.id)throw Error('Softr returned no event ID');
  const verify=(await cloudRequest(c,'/records/'+encodeURIComponent(record.id)+'?fieldNames=true')).data;
  if(!verify||Object.entries(fields).some(([name,value])=>name==='RecordedAt'?Date.parse(verify.fields?.[name])!==Date.parse(value):name==='Outcome'?(verify.fields?.[name]||'')!==value:verify.fields?.[name]!==value))throw Object.assign(Error('Softr event readback mismatch'),{code:'SOFTR_READBACK_MISMATCH'});
  return {recordId:record.id};
 }
 function flush(id){
  if(syncing.has(id))return syncing.get(id);
  const work=(async()=>{
   const attempted=new Set();
   for(;;){
    const pending=await serial(id,async()=>(await read(id)).events.filter(e=>e.cloud.status!=='saved'&&!attempted.has(e.data.eventId)));
    if(!pending.length)break;
    for(const event of pending){
     attempted.add(event.data.eventId);let cloud;
     try{const remote=await saveCloud(id,event);if(!remote||typeof remote.recordId!=='string')throw Error('Cloud sink returned no record ID');cloud={status:'saved',recordId:remote.recordId,syncedAt:new Date(now()).toISOString()};}
     catch(error){cloud={status:'pending',code:['SOFTR_TABLE_NOT_CONFIGURED','SOFTR_NOT_CONFIGURED','SOFTR_PERMISSION','SOFTR_EVENT_CONFLICT','SOFTR_READBACK_MISMATCH','SOFTR_SCHEMA_MISMATCH'].includes(error.code)?error.code:'SOFTR_UNAVAILABLE'};}
     await serial(id,async()=>{const current=await read(id),saved=current.events.find(e=>e.data.eventId===event.data.eventId);if(saved){saved.cloud=cloud;await write(current);}});
    }
   }
   return serial(id,async()=>publicSession(await read(id)));
  })().finally(()=>{if(syncing.get(id)===work)syncing.delete(id);});syncing.set(id,work);return work;
 }
 async function startTurn(req,res,input){
  const {session}=await begin(req,res),source=['voice','card','text'].includes(input.source)?input.source:'text';
  return {sessionId:session.sessionId,async finish(result,requestId){
   const card=result.cardUpdate,ids=(result.selections||[]).map(x=>x.storeId);
   let type=result.action==='ask'?'clarification':'recommendation',outcome=null;
   if(card?.action==='keep_current'){type='replacement_cancelled';outcome='cancelled';}
   else if(card?.action==='replace_store'){type=card.status==='applied'?'replacement_applied':'clarification';outcome=card.status;}
   return append(session.sessionId,{eventId:requestId,type,source,storeIds:ids,targetStoreId:input.cardFeedback?.storeId||null,outcome,turnId:requestId},true);
  },fail(code,requestId){return append(session.sessionId,{eventId:requestId,type:'turn_failed',source,storeIds:[],outcome:'failed',turnId:requestId},true);}};
 }
 async function handle(req,res,url){
  const route=url.pathname,base='/api/public/recommendation-sessions';if(route!==base&&!route.startsWith(base+'/'))return false;
  try{
   if(route===base&&req.method==='POST'){const value=await body(req);if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length)throw issue(400,'Session creation takes no user data.');const {session,token}=await begin(req,res);reply(res,201,{sessionId:session.sessionId,...(token?{token}:{}),storage:'local-durable'});return true;}
   const match=route.match(/^\/api\/public\/recommendation-sessions\/([A-Za-z0-9_-]{8,100})(?:\/(events|sync))?$/);if(!match)throw issue(404,'Not found.');
   const id=match[1],session=await authorize(req,id);
   if(!match[2]&&req.method==='GET'){reply(res,200,publicSession(session));return true;}
   if(match[2]==='events'&&req.method==='POST'){const result=await append(id,await body(req));reply(res,result.duplicate?200:201,result);return true;}
   if(match[2]==='sync'&&req.method==='POST'){const value=await body(req);if(Object.keys(value||{}).length)throw issue(400,'Sync takes no user data.');reply(res,200,await flush(id));return true;}
   throw issue(404,'Not found.');
  }catch(error){reply(res,error.status||503,{error:error.status?error.message:'Could not persist recommendation metadata.'});return true;}
 }
 return {handle,startTurn,flush};
}
module.exports={create,COOKIE};
