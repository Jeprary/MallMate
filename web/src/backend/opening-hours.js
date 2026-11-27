'use strict';
// Listed weekly schedules only. No network, live-status claim or recommendation gate.
const TIME_ZONE='Asia/Shanghai',DAY_MS=86400000;
const weekdays={'日':0,'天':0,'一':1,'二':2,'三':3,'四':4,'五':5,'六':6};
const formatter=new Intl.DateTimeFormat('en-CA',{timeZone:TIME_ZONE,year:'numeric',month:'2-digit',day:'2-digit',weekday:'short',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'});
function instant(value){
 if(value instanceof Date)return Number.isFinite(value.getTime())?new Date(value.getTime()):null;
 if(typeof value==='number')return Number.isFinite(value)&&Number.isFinite(new Date(value).getTime())?new Date(value):null;
 if(typeof value==='string'){
  const match=value.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:\d{2})$/i);
  if(!match||Number(match[2])>23||Number(match[3])>59||Number(match[4]||0)>59)return null;
  const calendar=new Date(match[1]+'T00:00:00Z'),d=new Date(value);
  return Number.isFinite(calendar.getTime())&&calendar.toISOString().slice(0,10)===match[1]&&Number.isFinite(d.getTime())?d:null;
 }
 return null;
}
function days(prefix){
 if(!prefix||/^(?:每天|每日|天天)$/.test(prefix))return [0,1,2,3,4,5,6];
 if(prefix==='周末')return [0,6];
 if(prefix==='工作日')return [1,2,3,4,5];
 const found=new Set(),pattern=/(?:周|星期)([一二三四五六日天])(?:[至到-](?:周|星期)?([一二三四五六日天]))?/g;
 const remainder=prefix.replace(pattern,(_whole,a,b)=>{let day=weekdays[a],end=b==null?day:weekdays[b];for(let i=0;i<7;i++){found.add(day);if(day===end)break;day=(day+1)%7;}return '';}).replace(/[、,\s]/g,'');
 return found.size&&!remainder?[...found]:null;
}
function minute(hour,min,end=false){const h=Number(hour),m=Number(min);return h>=0&&h<=23&&m>=0&&m<=59?h*60+m:end&&h===24&&m===0?1440:null;}
function parse(hours){
 const text=hours.trim().replace(/[：]/g,':').replace(/[–—~～]/g,'-').replace(/[，]/g,',');
 if(!text||text.length>1000)return {reason:'unrecognised_schedule'};
 const schedule=new Map();
 for(const raw of text.split(/[；;]/)){
  const clause=raw.trim();if(!clause)return {reason:'unrecognised_schedule'};
  const first=clause.search(/\d|全天/);if(first<0)return {reason:'unrecognised_schedule'};
  const prefix=clause.slice(0,first).trim(),daySet=days(prefix);if(!daySet)return {reason:'unrecognised_schedule'};
  const body=clause.slice(first).trim(),ranges=[];
  if(/^(?:24小时|全天)$/.test(body))ranges.push([0,1440]);
  else for(const piece of body.split(',')){
   const match=piece.trim().match(/^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})$/);if(!match)return {reason:'unrecognised_schedule'};
   const start=minute(match[1],match[2]),end=minute(match[3],match[4],true);
   if(start==null||end==null||start===end)return {reason:'invalid_hours'};
   ranges.push([start,end<start?end+1440:end]);
  }
  ranges.sort((a,b)=>a[0]-b[0]||a[1]-b[1]);
  for(const day of daySet){
   if(schedule.has(day)&&JSON.stringify(schedule.get(day))!==JSON.stringify(ranges))return {reason:'conflicting_schedule'};
   schedule.set(day,ranges);
  }
 }
 return {schedule};
}
const clock=minutes=>`${String(Math.floor(minutes/60)%24).padStart(2,'0')}:${String(minutes%60).padStart(2,'0')}`;
const dayNames=['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
function dayLabel(days){
 if(days.length===7)return 'Daily';
 const labels=[];
 for(let i=0;i<days.length;i++){
  const first=days[i];let last=first;
  while(days[i+1]===last+1)last=days[++i];
  labels.push(first===last?dayNames[first-1]:`${dayNames[first-1]}–${dayNames[last-1]}`);
 }
 return labels.join(', ');
}
function describeParsed(hours,parsed){
 const base={status:'unknown',hours:typeof hours==='string'?hours:null,timeZone:TIME_ZONE,basis:'listed_hours',liveVerified:false};
 if(!parsed.schedule)return {...base,reason:parsed.reason};
 // ISO weekdays identify the START day. Midnight ends are canonical 00:00
 // with offset 1, so 24:00 and overnight intervals use the same arithmetic.
 const groups=new Map();
 for(const [day,ranges] of parsed.schedule){
  const key=JSON.stringify(ranges),group=groups.get(key)||{weekdays:[],ranges};
  group.weekdays.push(day===0?7:day);groups.set(key,group);
 }
 const grouped=[...groups.values()].map(group=>({...group,weekdays:group.weekdays.sort((a,b)=>a-b)})).sort((a,b)=>a.weekdays[0]-b.weekdays[0]);
 const schedule=grouped.flatMap(({weekdays,ranges})=>ranges.map(([start,end])=>({weekdays:[...weekdays],start:clock(start),end:clock(end),endDayOffset:end>=1440?1:0,allDay:start===0&&end===1440})));
 const displayHours=grouped.map(({weekdays,ranges})=>`${dayLabel(weekdays)} ${ranges.map(([start,end])=>start===0&&end===1440?'24 hours':`${clock(start)}–${clock(end)}${end>=1440?' next day':''}`).join(', ')}`).join('; ');
 return {...base,status:'parsed',weekdayConvention:'ISO-8601',schedule,displayHours};
}
function read(hours){return typeof hours==='string'&&hours.trim()?parse(hours):{reason:'missing_hours'};}
function describe(hours){return describeParsed(hours,read(hours));}
function evaluate(hours,dateOrMs){
 const parsed=read(hours),date=instant(dateOrMs),base={...describeParsed(hours,parsed),status:'unknown',evaluatedAt:date?.toISOString()||null};
 if(!date)return {...base,reason:'invalid_instant'};
 if(!parsed.schedule)return base;
 const parts=Object.fromEntries(formatter.formatToParts(date).map(p=>[p.type,p.value]));
 const midnight=Date.UTC(Number(parts.year),Number(parts.month)-1,Number(parts.day)),weekday={Sun:0,Mon:1,Tue:2,Wed:3,Thu:4,Fri:5,Sat:6}[parts.weekday];
 const wallNow=midnight+Number(parts.hour)*3600000+Number(parts.minute)*60000+Number(parts.second)*1000+date.getUTCMilliseconds();
 const offset=wallNow-date.getTime(),windows=[];
 for(let d=-1;d<=8;d++)for(const [start,end] of parsed.schedule.get((weekday+d+7)%7)||[])windows.push([midnight+d*DAY_MS+start*60000-offset,midnight+d*DAY_MS+end*60000-offset]);
 windows.sort((a,b)=>a[0]-b[0]||a[1]-b[1]);
 const merged=[];for(const window of windows){const previous=merged.at(-1);if(previous&&window[0]<=previous[1])previous[1]=Math.max(previous[1],window[1]);else merged.push([...window]);}
 const time=date.getTime(),active=merged.find(w=>w[0]<=time&&time<w[1]);
 const localDateTime=`${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}`;
 if(active)return {...base,status:'listed_open',localDateTime,nextListedClose:active[1]-time>=7*DAY_MS?null:new Date(active[1]).toISOString()};
 if(!parsed.schedule.has(weekday))return {...base,reason:'unlisted_day',localDateTime};
 const next=merged.find(w=>w[0]>time);
 return {...base,status:'listed_closed',localDateTime,nextListedOpen:next?new Date(next[0]).toISOString():null};
}
module.exports={evaluate,describe,TIME_ZONE};
