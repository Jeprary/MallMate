// Local-only bridge to the Softr Database API. No tokens are sent to the frontend.
'use strict';
const http=require('http'),fs=require('fs'),path=require('path'),crypto=require('crypto'), AI=require('./ai.js');
const PublicRuntime=require('./public-runtime');
const publicRuntime=PublicRuntime.config();
if(!publicRuntime)throw Error('Set MALLMATE_PUBLIC_ORIGIN and MALLMATE_DATA_DIR before starting the review server.');
const PORT=Number(process.env.MALLMATE_PORT||process.env.PORT||8766);
const qwenEnabled=process.env.MALLMATE_QWEN_STREAMING==='1';
function qwenCredential(){
 if(!qwenEnabled)return null;
 if(!publicRuntime){
  const key=process.env.DASHSCOPE_API_KEY?.trim();
  delete process.env.DASHSCOPE_API_KEY;
  if(!key)throw Error('DASHSCOPE_API_KEY is required for Qwen streaming.');
  return key;
 }
 const directory=process.env.CREDENTIALS_DIRECTORY;
 if(!directory||!path.isAbsolute(directory))return null;
 try{
  const key=fs.readFileSync(path.join(directory,'dashscope-api-key'),'utf8').trim();
  return /^sk-(?!sp-)[-A-Za-z0-9._~+\/]+=*$/.test(key)?key:null;
 }catch{return null;}
}
const qwenKey=qwenCredential();
const qwenOpus=!!(qwenKey&&publicRuntime&&process.env.MALLMATE_SPEECH_OPUS==='1');
if(qwenOpus)fs.accessSync(require('./qwen-opus-encoder').COMMAND,fs.constants.X_OK);
if(qwenEnabled&&publicRuntime&&!qwenKey)console.warn('Cloud speech disabled: DashScope service credential unavailable.');
const indoorAssets=require('./indoor-assets.js');
const arrivalArtwork=require('./arrival-assets.js').create();
const ROOT=path.resolve(__dirname,'../..');
const DB=process.env.MALLMATE_SOFTR_DATABASE_ID||'';
const STORES=process.env.MALLMATE_SOFTR_STORES_TABLE_ID||'';
const BASE=`https://tables-api.softr.io/api/v1/databases/${DB}/tables/${STORES}`;
const TABLES={};
const dbBase=`https://tables-api.softr.io/api/v1/databases/${DB}/tables/`;
const softrCredentials=require('./softr-credentials.js').create();
function softrServiceCredential(){
 const directory=process.env.CREDENTIALS_DIRECTORY;
 if(!directory||!path.isAbsolute(directory))return '';
 try{return fs.readFileSync(path.join(directory,'softr-api-token'),'utf8').trim();}
 catch(error){if(error.code==='ENOENT')return '';throw error;}
}
const catalogueMode=process.env.MALLMATE_CATALOGUE_SOURCE;
let token=softrServiceCredential()||process.env.SOFTR_API_TOKEN||(publicRuntime||catalogueMode==='snapshot'?'':softrCredentials.read());
if(catalogueMode==='review-softr'&&(!/^[A-Za-z0-9_-]+$/.test(DB)||!/^[A-Za-z0-9_-]+$/.test(STORES)||!token)){
 throw Error('Set the Softr database ID, Stores table ID, and service credential for review-softr mode.');
}
const userFile=path.join(ROOT,'.local-accounts.json'), sessions=new Map(), attempts=new Map();
const ownerFile=path.join(ROOT,'.merchant-owners.json');
function readOwners(){if(!fs.existsSync(ownerFile))return {};const d=JSON.parse(fs.readFileSync(ownerFile,'utf8'));if(!d||Array.isArray(d)||typeof d!=='object')throw Error('Invalid local ownership file.');return d}
function ownedIds(username){const owners=readOwners();return Object.keys(owners).filter(id=>owners[id]===username)}
function addOwner(id,username){if(!/^[a-zA-Z0-9_-]+$/.test(id))throw Error('Invalid created store ID.');const d=readOwners();if(d[id])throw Error('Store ownership already recorded.');d[id]=username;const tmp=ownerFile+'.tmp';fs.writeFileSync(tmp,JSON.stringify(d,null,2),{mode:0o600});fs.renameSync(tmp,ownerFile)}
function owns(username,id){return readOwners()[id]===username}

function reply(res,status,data,headers={}){res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',...headers});res.end(JSON.stringify(data));}
function readUsers(){if(!fs.existsSync(userFile))return [];const users=JSON.parse(fs.readFileSync(userFile,'utf8'));if(!Array.isArray(users))throw Error('Local account file is invalid.');return users;}
function saveUsers(users){const tmp=userFile+'.tmp';fs.writeFileSync(tmp,JSON.stringify(users,null,2),{mode:0o600});fs.renameSync(tmp,userFile);}
function digest(password,salt){return crypto.scryptSync(password,salt,64).toString('hex')}
function readSession(req){const match=(req.headers.cookie||'').match(/(?:^|;\s*)mallmate_session=([a-f0-9]{64})(?:;|$)/);const s=match&&sessions.get(match[1]);if(!s||s.expires<Date.now()){if(match)sessions.delete(match[1]);return null}return s}
function sessionHeader(username){const id=crypto.randomBytes(32).toString('hex');sessions.set(id,{username,expires:Date.now()+12*60*60*1000});return `mallmate_session=${id}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200`}
function validateCredentials(d){let username=String(d.username||'').trim().toLowerCase(),password=String(d.password||'');if(!/^[a-z0-9_]{3,24}$/.test(username))throw Error('Username must have 3–24 letters, numbers, or underscores.');if(password.length<8||password.length>128)throw Error('Password must have 8–128 characters.');return {username,password}}
async function softr(endpoint,opts={}){
 const credential=opts.credential??token;
 if(!credential)throw new Error('Softr API token is not configured.');
 const r=await fetch(BASE+endpoint,{method:opts.method||'GET',headers:{'Softr-Api-Key':credential,'Content-Type':'application/json'},body:opts.body?JSON.stringify(opts.body):undefined,signal:AbortSignal.timeout(15000),redirect:'error'});
 let data;try{data=await r.json()}catch{data={}}
 if(!r.ok)throw new Error(`Softr API returned HTTP ${r.status}. Check token permissions and database access.`);
 return data;
}
async function tableCall(table,endpoint='',opts={}){
 if(!token)throw Error('Softr API token is not configured.');
 const r=await fetch(dbBase+table+endpoint,{method:opts.method||'GET',headers:{'Softr-Api-Key':token,'Content-Type':'application/json'},body:opts.body?JSON.stringify(opts.body):undefined,signal:AbortSignal.timeout(20000)});
 let d={};try{d=await r.json()}catch{}
 if(!r.ok)throw Error(`Softr ${opts.method||'GET'} failed (HTTP ${r.status}): ${String(d.message||'').slice(0,250)}`);
 return d;
}
async function tableRecords(table){let out=[],offset=0;for(let i=0;i<20;i++){const d=await tableCall(table,`/records?limit=100&offset=${offset}&fieldNames=true`);out.push(...d.data);offset+=d.data.length;if(!d.data.length||offset>=Number(d.metadata?.total??offset))break;}return out}
async function allFeedbackRecords(){let out=[],offset=0;for(;;){const d=await tableCall(TABLES.feedback,`/records?limit=100&offset=${offset}&fieldNames=true`),rows=d.data||[];if(!Array.isArray(rows))throw Error('Invalid feedback response.');out.push(...rows);offset+=rows.length;const total=Number(d.metadata?.total);if(!rows.length||(Number.isFinite(total)?offset>=total:rows.length<100))break;}return out;}
async function onceRecord(table,keyField,key,fields){let existing=(await tableRecords(table)).find(r=>r.fields?.[keyField]===key);if(existing)return existing;const d=await tableCall(table,'/records?fieldNames=true',{method:'POST',body:{fields}});return d.data}
async function saveJourney(d,username){
 const key=String(d.key||'');if(!/^[a-zA-Z0-9-]{8,64}$/.test(key))throw Error('Invalid demo journey identifier.');
 if(!/^[a-zA-Z0-9_-]+$/.test(String(d.storeId||'')))throw Error('Invalid store.');
 let c=d.context||{},min=Number(c.min),max=Number(c.max),time=Number(c.time);
 if(!['all','cafe','food','shops'].includes(c.category)||!Number.isFinite(min)||!Number.isFinite(max)||min<0||max<min||max>10000||!Number.isFinite(time)||time<1||time>240||!['entrance','atrium'].includes(c.origin)||!['helpful','not-helpful'].includes(d.rating))throw Error('Invalid context or feedback.');
 const stores=await allStores();if(!stores.some(s=>s.id===d.storeId))throw Error('Store not found in Softr.');
 let user=await onceRecord(TABLES.users,'Userid','DEMO_LOCAL_'+username,{'dOYhF':'DEMO_LOCAL_'+username,'IAZIj':'DEMO local '+username,'dc2A3':'shopper','EyS28':true,'xHVVd':new Date().toISOString()});
 let cf={'9j1mv':'DEMO_CTX_'+key,'TmklP':{id:user.id},'akT64':min,'texdR':max,'9Pskz':time,'L3aJ9':!!c.quiet,'litpQ':c.origin,'nMt5I':true,'67Vbv':new Date().toISOString()};if(c.category!=='all')cf.oJYVo=c.category;
 let ctx=await onceRecord(TABLES.contexts,'Contextid','DEMO_CTX_'+key,cf);
 let vf={'ljbv6':'DEMO_VISIT_'+key,'UKToi':{id:ctx.id},'NgdTw':{id:d.storeId},'ADPe5':d.mode==='ar'?'AR':'2D','MNWgG':'selected','X8ZhY':true,'DM7zm':new Date().toISOString()};
 let visit=await onceRecord(TABLES.visits,'Visitid','DEMO_VISIT_'+key,vf);
 let ff={'8PpZC':'DEMO_FEEDBACK_'+key,'8CR1T':{id:visit.id},'1E0dC':{id:d.storeId},'QTQxg':d.rating,'SwOEE':'DEMO: '+String(d.comment||'').trim().slice(0,250),'4b2AF':true,'iuEfB':new Date().toISOString()};
 let feedback=await onceRecord(TABLES.feedback,'Feedbackid','DEMO_FEEDBACK_'+key,ff);
 const verify=(await tableCall(TABLES.feedback,'/records/'+encodeURIComponent(feedback.id)+'?fieldNames=true')).data;
 const verifyCtx=(await tableCall(TABLES.contexts,'/records/'+encodeURIComponent(ctx.id)+'?fieldNames=true')).data;
 const verifyVisit=(await tableCall(TABLES.visits,'/records/'+encodeURIComponent(visit.id)+'?fieldNames=true')).data;
 if(verify.fields?.Store?.id!==d.storeId||verify.fields?.Visit?.id!==visit.id||verifyCtx.fields?.User?.id!==user.id||verifyVisit.fields?.Context?.id!==ctx.id||verifyVisit.fields?.Store?.id!==d.storeId)throw Error('Saved feedback but a user, context, store or visit link could not be verified.');
 if(verifyVisit.fields?.Status?.label!=='feedback_saved')await tableCall(TABLES.visits,'/records/'+encodeURIComponent(visit.id),{method:'PATCH',body:{fields:{MNWgG:'feedback_saved'}}});
 return {id:feedback.id,visitId:visit.id,contextId:ctx.id};
}
function fieldList(data){let d=data.data||data;return Array.isArray(d.fields)?d.fields:(Array.isArray(d.columns)?d.columns:[])}
async function schema(){let fields=fieldList(await softr(''));if(!fields.length)throw Error('Softr returned no table fields. Check API access.');return fields;}
function field(fields,name){return fields.find(f=>String(f.name||'').replace(/[^a-z]/gi,'').toLowerCase()===name.replace(/[^a-z]/gi,'').toLowerCase())}
async function allStores(){let result=[],offset=0;for(let i=0;i<20;i++){const d=await softr(`/records?limit=100&offset=${offset}&fieldNames=true`),rows=d.data||[];result.push(...rows);offset+=rows.length;if(!rows.length||offset>=Number(d.metadata?.total??offset))break;}return result;}
function body(req){return new Promise((resolve,reject)=>{let raw='';req.on('data',x=>{raw+=x;if(raw.length>16384){reject(Error('Request too large'));req.destroy()}});req.on('end',()=>{try{resolve(JSON.parse(raw||'{}'))}catch{reject(Error('Invalid JSON'))}});req.on('error',reject)})}
function validate(data){const name=String(data.name||'').trim();const lo=Number(data.min),hi=Number(data.max);if(!name||name.length>80||!['cafe','food','shops'].includes(data.category)||!Number.isFinite(lo)||!Number.isFinite(hi)||lo<0||hi<lo||hi>10000)throw Error('Please enter a name, category, and valid price range.');return {name:`${data.demo?'DEMO ':''}${name}`.replace(/^DEMO DEMO /,'DEMO '),category:data.category,min:lo,max:hi,hours:String(data.hours||'10:00-22:00').slice(0,30)};}
async function buildFields(data){let f=await schema(),vals=validate(data),out={};for(const [label,value] of [['Name',vals.name],['Category',vals.category],['Pricemin',vals.min],['Pricemax',vals.max],['Hours',vals.hours]]){const found=field(f,label);if(found?.id)out[found.id]=value;else if(label==='Name')throw Error('Name field was not found in Stores table.');}return out}
const allowed=new Map([["index.html","index.html"],["style.css","src/frontend/style.css"],["model.js","src/shared/model.js"],["app.js","src/frontend/app.js"]]);
const makeCatalogueSource=()=>require('./catalogue-source.js').create({liveRead:allStores,snapshotPath:path.join(ROOT,'assets/catalogue.json'),mode:catalogueMode||'snapshot',localContent:false});
let catalogueSource=makeCatalogueSource();
const recommendationEvents=require('./recommendation-events.js').create({root:ROOT,dataDir:publicRuntime?.dataDir,secureCookie:!!publicRuntime,loadCatalogue:()=>catalogueSource.load(),body,reply,getToken:()=>token,cloudConfig:process.env.MALLMATE_EVENT_SYNC==='softr'?undefined:null});
const routeUuidPath=/^\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
function routeDestination(value){
 if(!value)return '';
 try{
  const url=new URL(value);
  if(url.username||url.password)return '';
  if(url.protocol==='https:'||!publicRuntime&&url.protocol==='http:')return url.href;
  if(url.protocol==='mallmate-route:'&&url.hostname==='practice'&&!url.port&&['','/'].includes(url.pathname)){
   return 'mallmate-route://practice';
  }
  if(url.protocol==='mallmate-route:'&&url.hostname==='route'&&!url.port&&routeUuidPath.test(url.pathname)){
   return url.protocol+'//'+url.hostname+url.pathname;
  }
 }catch{}
 return '';
}
function storeRouteDestinations(setting){
 if(!setting?.trim())return null;
 const error='MALLMATE_STORE_ROUTES must be a JSON object mapping store IDs to route UUIDs.';
 let routes;
 try{routes=JSON.parse(setting);}catch{throw Error(error);}
 if(!routes||typeof routes!=='object'||Array.isArray(routes))throw Error(error);
 return Object.fromEntries(Object.entries(routes).map(([storeId,uuid])=>{
  if(!/^[A-Za-z0-9_-]{1,200}$/.test(storeId)||typeof uuid!=='string'||!routeUuidPath.test('/'+uuid)){
   throw Error(error);
  }
  return [storeId,'mallmate-route://route/'+uuid];
 }));
}
const guestApi=require('./guest-api.js').createGuestApi({
 allStores,loadCatalogue:()=>catalogueSource.load(),indoorAssets,AI,body,reply,recommendationEvents,
 navigationDestination:routeDestination(process.env.MALLMATE_ROUTE_DESTINATION?.trim()),
 navigationDestinations:storeRouteDestinations(process.env.MALLMATE_STORE_ROUTES),
 ...(publicRuntime?{rateLimit:PublicRuntime.capacity.recommendationStartsPerMinute,maxConcurrent:PublicRuntime.capacity.recommendationConcurrent}:{})
});
const localSpeech=publicRuntime?null:require('./local-speech.js').create({root:ROOT,reply});
let qwenSpeech;
const server=http.createServer(async(req,res)=>{
 try{
  const u=new URL(req.url,'http://127.0.0.1:'+PORT);
  if(publicRuntime&&!PublicRuntime.allowed(req.method,u)){req.resume();return reply(res,404,{error:'Not found'});}
  if(publicRuntime&&u.pathname==='/healthz')return reply(res,200,{ok:true});
  if(arrivalArtwork(req,res,u))return;
  if(req.method==='POST'||req.method==='PATCH') {if(req.headers.origin!==(publicRuntime?.origin||'http://127.0.0.1:'+PORT)){req.resume();return reply(res,403,{error:'Invalid request origin.'});}}
  if(qwenSpeech&&req.method==='GET'&&u.pathname==='/api/public/speech/status')return reply(res,200,qwenSpeech);
  if(publicRuntime&&u.pathname==='/api/public/speech/status')return reply(res,200,{configured:false,provider:'disabled',model:''});
  if(publicRuntime&&u.pathname==='/api/public/speech/transcribe'){req.resume();return reply(res,503,{error:'Speech recognition is not configured for this deployment.'});}
  if(qwenSpeech&&req.method==='GET'&&u.pathname==='/api/public/speech/pcm-capture.js'){
   res.writeHead(200,{'Content-Type':'text/javascript; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
   return fs.createReadStream(path.join(ROOT,'src/frontend/qwen-pcm-capture.js')).pipe(res);
  }
  if(localSpeech&&await localSpeech.handle(req,res,u))return;
  if(await recommendationEvents.handle(req,res,u))return;
  if(await guestApi(req,res,u))return;
  if(u.pathname==='/api/auth/me'&&req.method==='GET'){const s=readSession(req);return reply(res,200,{user:s?{username:s.username}:null})}
  if((u.pathname==='/api/auth/register'||u.pathname==='/api/auth/login')&&req.method==='POST'){
   let d=validateCredentials(await body(req)),users=readUsers(),user=users.find(x=>x.username===d.username),register=u.pathname.endsWith('/register');
   if(register){if(user)return reply(res,409,{error:'That username already exists.'});const salt=crypto.randomBytes(16).toString('hex');users.push({username:d.username,salt,hash:digest(d.password,salt),createdAt:new Date().toISOString(),scope:'local classroom demo'});saveUsers(users)}
   else {let a=attempts.get(d.username)||{n:0,until:0};if(a.until>Date.now())return reply(res,429,{error:'Too many attempts. Try again in one minute.'});let actual=digest(d.password,user?.salt||'00000000000000000000000000000000'),expected=user?.hash||'0'.repeat(128);if(!crypto.timingSafeEqual(Buffer.from(actual,'hex'),Buffer.from(expected,'hex'))){a.n++;if(a.n>=5){a.until=Date.now()+60000;a.n=0}attempts.set(d.username,a);return reply(res,401,{error:'Incorrect username or password.'})}attempts.delete(d.username)}
   return reply(res,200,{user:{username:d.username}},{'Set-Cookie':sessionHeader(d.username)})
  }
  if(u.pathname==='/api/auth/logout'&&req.method==='POST'){const match=(req.headers.cookie||'').match(/(?:^|;\s*)mallmate_session=([a-f0-9]{64})(?:;|$)/);if(match)sessions.delete(match[1]);return reply(res,200,{ok:true},{'Set-Cookie':'mallmate_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0'})}
  if(u.pathname.startsWith('/api/')&&u.pathname!=='/api/config'&&!readSession(req))return reply(res,401,{error:'Sign in to the local classroom demo.'});
  if(u.pathname==='/api/indoor-map/manifest'&&req.method==='GET')return reply(res,200,indoorAssets.manifest());
  const indoorFloor=u.pathname.match(/^\/api\/indoor-map\/floors\/([123])$/);
  if(indoorFloor&&req.method==='GET')return reply(res,200,indoorAssets.scene(Number(indoorFloor[1])));
  if(u.pathname==='/api/config'&&req.method==='POST'){if(token&&!readSession(req))return reply(res,401,{error:'Sign in first.'});const d=await body(req);if(typeof d.token!=='string'||d.token.trim().length<10||Buffer.byteLength(d.token)>8192)throw Error('Enter a valid Softr API token.');const candidate=d.token.trim();await softr('/records?limit=1',{credential:candidate});softrCredentials.save(candidate);token=candidate;catalogueSource=makeCatalogueSource();return reply(res,200,{ok:true,credentialStorage:'macOS Keychain'})}
  if(u.pathname==='/api/ai/status'&&req.method==='GET')return reply(res,200,AI.status());
  if(u.pathname==='/api/ai/config'&&req.method==='POST'){const d=await body(req);AI.saveKey(d.key,d.provider);return reply(res,200,AI.status())}
  if(u.pathname==='/api/ai/chat'&&req.method==='POST'){const d=await body(req);const data=await catalogueSource.load();return reply(res,200,await AI.recommend(require('./guest-api').chatInput(d),{records:require('./guest-api').publicStores(data.records),catalogueVersion:data.fetchedAt}))}
  if(u.pathname==='/api/stores'&&req.method==='GET')return reply(res,200,{records:await allStores()});
  if(u.pathname==='/api/merchant/stores'&&req.method==='GET'){let ids=ownedIds(readSession(req).username);return reply(res,200,{storeIds:ids})}
  if(u.pathname==='/api/feedback'&&req.method==='GET'){let rows=await allFeedbackRecords();return reply(res,200,{records:rows.map(r=>({id:r.id,rating:r.fields?.Rating?.label||r.fields?.Rating||'',comment:r.fields?.Comment||'',storeId:r.fields?.Store?.id||'',storeName:r.fields?.['Store name']||'',createdAt:r.fields?.['Recorded at']||r.fields?.Createdat||'',isDemo:r.fields?.Isdemo===true}))})}
  if(u.pathname==='/api/feedback'&&req.method==='POST')return reply(res,200,{saved:await saveJourney(await body(req),readSession(req).username)});
  if(u.pathname==='/api/stores'&&req.method==='POST'){let d=await body(req);const result=await softr('/records',{method:'POST',body:{fields:await buildFields({...d,demo:true})}});const record=result.data||result;if(!record?.id)throw Error('Softr created a store but returned no record ID. Please check the database.');try{addOwner(record.id,readSession(req).username)}catch(e){throw Error('Store was created in Softr but local ownership could not be saved; contact the demo operator.')}catalogueSource.invalidate();return reply(res,200,{record})}
  if(u.pathname.startsWith('/api/stores/')&&req.method==='PATCH'){let id=decodeURIComponent(u.pathname.slice(12));if(!/^[a-zA-Z0-9_-]+$/.test(id))throw Error('Invalid record ID.');if(!owns(readSession(req).username,id))return reply(res,403,{error:'You can edit only demo stores created by this local account.'});let d=await body(req);const result=await softr('/records/'+id,{method:'PATCH',body:{fields:await buildFields(d)}});catalogueSource.invalidate();return reply(res,200,{record:result.data||result})}
  let file=u.pathname==='/'?'index.html':u.pathname.slice(1);if(!allowed.has(file))return reply(res,404,{error:'Not found'});
  let type={'.html':'text/html','.css':'text/css','.js':'text/javascript'}[path.extname(file)];res.writeHead(200,{'Content-Type':type+'; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});fs.createReadStream(path.join(ROOT,allowed.get(file))).pipe(res);
 }catch(e){reply(res,400,{error:e.name==='TimeoutError'?'Connection to Softr timed out.':e.message})}
});
if(qwenKey)qwenSpeech=require('./qwen-streaming-http.js').attach(server,{
 apiKey:qwenKey,origin:publicRuntime?.origin||'http://127.0.0.1:'+PORT,publicPreview:!!publicRuntime,useOpus:qwenOpus,
 recordTiming:publicRuntime?(timing)=>console.info(JSON.stringify({event:'speech_session_timing',...timing})):undefined
});
server.listen(PORT,'127.0.0.1',function(){console.log('MallMate demo: http://127.0.0.1:'+this.address().port+'/');});
