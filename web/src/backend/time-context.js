'use strict';
const TIME_ZONE='Asia/Shanghai';
function create(value=Date.now()){
 const date=new Date(value);if(!Number.isFinite(date.getTime()))throw Error('Invalid context time');
 const p=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:TIME_ZONE,year:'numeric',month:'2-digit',day:'2-digit',weekday:'long',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(date).map(x=>[x.type,x.value]));
 return {iso:date.toISOString(),local:`${p.year}-${p.month}-${p.day} ${p.weekday} ${p.hour}:${p.minute}:${p.second}`,timeZone:TIME_ZONE};
}
function parse(value){
 if(typeof value!=='string')throw Error('Use an ISO datetime with an explicit timezone');
 const m=value.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::(\d{2})(?:\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/);
 if(!m)throw Error('Use an ISO datetime with an explicit timezone');
 const date=new Date(value);if(!Number.isFinite(date.getTime()))throw Error('Invalid requested time');
 const zone=m[4],offset=zone==='Z'?0:(zone[0]==='-'?-1:1)*(Number(zone.slice(1,3))*60+Number(zone.slice(4)));
 if(new Date(date.getTime()+offset*60000).toISOString().slice(0,19)!==`${m[1]}T${m[2]}:${m[3]||'00'}`)throw Error('Invalid requested time');
 return date;
}
const format=time=>`Current local date and time: ${time.local} (${TIME_ZONE}, UTC+08:00).`;
module.exports={TIME_ZONE,create,parse,format};
