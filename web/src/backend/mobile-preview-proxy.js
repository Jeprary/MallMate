// Restricted bridge for a temporary HTTPS tunnel. Private application routes never pass through.
'use strict';
const http=require('node:http'),crypto=require('node:crypto'),{Transform}=require('node:stream');
const COOKIE='__Host-mallmate-preview';
const reads=new Set(['/','/index.html','/style.css','/model.js','/app.js','/assets/arrival/wanda-day.jpg','/api/public/stores','/api/public/ai/status','/api/public/speech/status','/api/public/indoor-map/manifest','/api/public/indoor-map/floors/1','/api/public/indoor-map/floors/2','/api/public/indoor-map/floors/3']);
const writes=new Map([['/api/public/agent/turns',16384],['/api/public/speech/transcribe',6*1024*1024]]);
const sessionBase='/api/public/recommendation-sessions',sessionPath=/^\/api\/public\/recommendation-sessions\/[A-Za-z0-9_-]{8,100}(?:\/(events|sync))?$/;
const recommendationCookie=/^mallmate_recommendation=([A-Za-z0-9_-]{8,100}\.[a-f0-9]{64})$/;
function create({target='http://127.0.0.1:59323',token=crypto.randomBytes(32).toString('hex')}={}){
 const upstream=new URL(target);if(upstream.protocol!=='http:'||upstream.hostname!=='127.0.0.1'||!upstream.port||upstream.pathname!=='/'||upstream.username||upstream.password||upstream.search||upstream.hash)throw Error('Preview target must be an explicit loopback HTTP service.');
 if(!/^[a-f0-9]{64}$/.test(token))throw Error('Invalid preview access token');
 let origin=null,windowStart=Date.now(),posts=0;
 function setOrigin(value){const u=new URL(value);if(u.protocol!=='https:'||!u.hostname.endsWith('.trycloudflare.com')||u.username||u.password||u.port||u.pathname!=='/'||u.search||u.hash)throw Error('Expected a Quick Tunnel HTTPS origin');origin=u.origin;}
 const same=value=>typeof value==='string'&&/^[a-f0-9]{64}$/.test(value)&&crypto.timingSafeEqual(Buffer.from(value),Buffer.from(token));
 const security={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'};
 const server=http.createServer((req,res)=>{
  const reply=(status,error)=>{req.resume();if(res.headersSent)return;res.writeHead(status,{...security,'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify({error}));};
  let url;try{url=new URL(req.url,'http://localhost');}catch{return reply(400,'Invalid request.');}
  if(!origin)return reply(503,'Preview connection is not ready.');
  if(req.method==='GET'&&url.pathname.startsWith('/connect/')){
   if(!same(url.pathname.slice('/connect/'.length)))return reply(404,'Not found.');
   res.writeHead(303,{...security,Location:'/?entry=qr&mall=B02001H9JR', 'Set-Cookie':`${COOKIE}=${token}; Secure; HttpOnly; SameSite=Lax; Path=/`});res.end();return;
  }
  const cookie=(req.headers.cookie||'').split(';').map(p=>p.trim()).find(p=>p.startsWith(COOKIE+'='))?.slice(COOKIE.length+1);
  if(!same(cookie))return reply(404,'Not found.');
  const sessionMatch=url.pathname.match(sessionPath),sessionRoute=url.pathname===sessionBase||!!sessionMatch;
  const read=['GET','HEAD'].includes(req.method)&&reads.has(url.pathname)||req.method==='GET'&&sessionMatch&&!sessionMatch[1],limit=req.method==='POST'?(writes.get(url.pathname)||(sessionRoute&&(url.pathname===sessionBase||sessionMatch?.[1])?16384:null)):null;
  if(!read&&!limit){req.resume();return reply(404,'Not found.');}
  if(limit){
   if(req.headers.origin!==origin){req.resume();return reply(403,'Invalid preview origin.');}
   if(Number(req.headers['content-length'])>limit){req.resume();return reply(413,'Request exceeds the existing service limit.');}
   const time=Date.now();if(time-windowStart>=60000){windowStart=time;posts=0;}if(posts>=12){req.resume();return reply(429,'Too many preview requests.');}posts++;
  }
  const headers={};for(const name of ['content-type','content-length','x-speech-language'])if(req.headers[name]!=null&&(name!=='content-length'||limit))headers[name]=req.headers[name];
  if(sessionRoute||url.pathname==='/api/public/agent/turns'){
   const own=String(req.headers.cookie||'').split(';').map(x=>x.trim()).find(x=>recommendationCookie.test(x));if(own)headers.cookie=own;
  }
  if(limit)headers.origin=upstream.origin;
  let failed=false;
  const outgoing=http.request(new URL(url.pathname+url.search,upstream),{method:req.method,headers},incoming=>{
   if(failed){incoming.resume();return;}
   const forwarded={...security};for(const name of ['content-type','content-length','x-content-type-options','x-accel-buffering'])if(incoming.headers[name]!=null)forwarded[name]=incoming.headers[name];
   if(sessionRoute||url.pathname==='/api/public/agent/turns'){
    const values=incoming.headers['set-cookie']||[],own=(Array.isArray(values)?values:[values]).map(x=>String(x).split(';')[0]).find(x=>recommendationCookie.test(x));
    if(own)forwarded['set-cookie']=own+'; Secure; HttpOnly; SameSite=Strict; Path=/api/public';
   }
   res.writeHead(incoming.statusCode,forwarded);incoming.on('error',()=>res.destroy());incoming.pipe(res);
  });
  outgoing.on('error',()=>{if(!failed){failed=true;reply(502,'Local preview service is unavailable.');if(res.headersSent&&!res.writableEnded)res.end();}});
  res.on('close',()=>{if(!res.writableEnded)outgoing.destroy();});req.on('aborted',()=>outgoing.destroy());
  if(limit){
   let size=0;const bounded=new Transform({transform(chunk,encoding,done){size+=chunk.length;if(size>limit){failed=true;reply(413,'Request exceeds the existing service limit.');outgoing.destroy();req.unpipe(bounded);req.resume();done();}else done(null,chunk);}});
   bounded.on('error',()=>outgoing.destroy());req.pipe(bounded).pipe(outgoing);
  }else outgoing.end();
 });
 return {server,setOrigin,accessPath:'/connect/'+token};
}
module.exports={create};
