'use strict';
const path=require('node:path');
const artwork=require('./arrival-assets.js');

const capacity=Object.freeze({
 speechConcurrent:50,
 speechStartsPerMinute:60,
 speechStartsPerDay:600,
 recommendationConcurrent:200,
 recommendationStartsPerMinute:200
});

const reads=new Set(['/','/index.html','/style.css','/model.js','/app.js','/assets/arrival/wanda-day.jpg','/healthz','/api/public/stores','/api/public/ai/status','/api/public/speech/status','/api/public/speech/pcm-capture.js','/api/public/indoor-map/manifest','/api/public/indoor-map/floors/1','/api/public/indoor-map/floors/2','/api/public/indoor-map/floors/3']);
const writes=new Set(['/api/public/agent/turns','/api/public/ai/chat','/api/public/speech/transcribe','/api/public/recommendation-sessions']);
const sessions=/^\/api\/public\/recommendation-sessions\/[A-Za-z0-9_-]{8,100}$/;

function config(env=process.env){
 if(!env.MALLMATE_PUBLIC_ORIGIN)return null;
 const url=new URL(env.MALLMATE_PUBLIC_ORIGIN);
 const loopback=env.MALLMATE_REVIEW_LOCAL==='1'&&url.protocol==='http:'&&url.hostname==='127.0.0.1';
 if((url.protocol!=='https:'&&!loopback)||url.origin!==env.MALLMATE_PUBLIC_ORIGIN)throw Error('Use an exact HTTPS origin for deployment.');
 if(!env.MALLMATE_DATA_DIR||!path.isAbsolute(env.MALLMATE_DATA_DIR))throw Error('MALLMATE_DATA_DIR must be an absolute persistent directory.');
 if(env.MALLMATE_EVENT_SYNC&&env.MALLMATE_EVENT_SYNC!=='local')throw Error('Public mode only supports local durable event storage.');
 if(env.MALLMATE_CATALOGUE_SOURCE==='softr')throw Error('Public mode requires snapshot or softr-published, not the raw Softr table.');
 return {origin:url.origin,dataDir:env.MALLMATE_DATA_DIR};
}

function allowed(method,url){
 const pathname=url.pathname;
 if(url.searchParams.get('mode')==='developer')return false;
 if(method==='GET')return reads.has(pathname)||artwork.includes(pathname)||sessions.test(pathname);
 if(method==='HEAD')return artwork.includes(pathname)||reads.has(pathname)&&!pathname.startsWith('/api/');
 return method==='POST'&&(writes.has(pathname)||pathname.endsWith('/events')&&sessions.test(pathname.slice(0,-7)));
}

module.exports={config,allowed,capacity};
