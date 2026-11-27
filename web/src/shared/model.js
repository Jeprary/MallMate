(function(root){
 'use strict';
 const initialStores=[
  {id:'coffee',name:'Atrium Coffee',category:'cafe',min:22,max:48,minutes:2,floor:'L1',hours:'10:00-22:00',quiet:true,tags:['Coffee','Dessert','Seating'],pos:[265,120]},
  {id:'noodle',name:'Noodle House',category:'food',min:18,max:38,minutes:4,floor:'L1',hours:'10:00-21:00',quiet:false,tags:['Noodles','Quick lunch'],pos:[85,100]},
  {id:'garden',name:'Garden Kitchen',category:'food',min:35,max:68,minutes:3,floor:'L1',hours:'11:00-21:00',quiet:true,tags:['Fresh bowls','Vegetarian'],pos:[265,265]},
  {id:'style',name:'Everyday Studio',category:'shops',min:80,max:300,minutes:3,floor:'L1',hours:'10:00-22:00',quiet:false,tags:['Clothes','Lifestyle'],pos:[85,265]},
  {id:'books',name:'Page and Co',category:'shops',min:15,max:80,minutes:5,floor:'L1',hours:'10:00-21:00',quiet:true,tags:['Books','Gifts'],pos:[265,370]}
 ];
 const origins={entrance:[70,410],atrium:[170,215]};
 function fresh(){return {stores:JSON.parse(JSON.stringify(initialStores)),context:{category:'all',min:0,max:100,quiet:false,time:30,origin:'entrance'},selected:'coffee',messages:[],events:[],navigation:null};}
 function validContext(c){if(!['all','cafe','food','shops'].includes(c.category))throw Error('Choose a valid category.');if(!Number.isFinite(c.min)||!Number.isFinite(c.max)||c.min<0||c.max<c.min||c.max>10000)throw Error('Use a budget between RMB 0 and 10000, with minimum <= maximum.');if(!Number.isFinite(c.time)||c.time<1||c.time>240)throw Error('Time available must be 1-240 minutes.');if(!origins[c.origin])throw Error('Choose a known starting point.');return c;}
 function recommend(stores,c){validContext(c);return stores.filter(s=>(c.category==='all'||s.category===c.category)&&s.min<=c.max&&s.max>=c.min&&(!c.quiet||s.quiet)&&s.minutes<=c.time).sort((a,b)=>a.minutes-b.minutes||a.min-b.min);}
 function interpret(message,current){const text=String(message).trim().toLowerCase();if(!text)throw Error('Describe your need first.');const c={...current};let recognised=false;
  if(/coffee|cafe|café|咖啡|甜品/.test(text)){c.category='cafe';recognised=true;}
  else if(/noodle|meal|lunch|food|dinner|吃|餐|面/.test(text)){c.category='food';recognised=true;}
  else if(/shop|book|cloth|gift|购物|书|衣服|礼物/.test(text)){c.category='shops';recognised=true;}
  if(/any category|all categories|不限类别|任何店/.test(text)){c.category='all';recognised=true;}
  if(/not quiet|no quiet|不用安静|不要求安静/.test(text)){c.quiet=false;recognised=true;}
  else if(/quiet|安静/.test(text)){c.quiet=true;recognised=true;}
  const range=text.match(/(?:rmb\s*|¥\s*|￥\s*)?(\d+(?:\.\d+)?)\s*[-~到至]\s*(\d+(?:\.\d+)?)/);
  const max=text.match(/(?:under|below|less than|budget|不超过|低于|最多|预算|以内|小于)\s*(?:rmb\s*|¥\s*|￥\s*)?(\d+(?:\.\d+)?)/)||text.match(/(\d+(?:\.\d+)?)\s*(?:元|rmb)?\s*(?:以内|以下)/);
  if(range){c.min=Number(range[1]);c.max=Number(range[2]);recognised=true;}else if(max){c.min=0;c.max=Number(max[1]);recognised=true;}
  const time=text.match(/(\d+)\s*(?:minutes?|mins?|分钟)/);if(time){c.time=Number(time[1]);recognised=true;}
  if(/atrium|中庭/.test(text)){c.origin='atrium';recognised=true;}else if(/entrance|入口/.test(text)){c.origin='entrance';recognised=true;}
  validContext(c);return {context:c,recognised};
 }
 function editStore(stores,id,patch){const original=stores.find(s=>s.id===id);if(!original)throw Error('Unknown store.');const min=Number(patch.min),max=Number(patch.max),name=String(patch.name||'').trim(),hours=String(patch.hours||'').trim();if(!name||name.length>45)throw Error('Store name must be 1-45 characters.');if(!['cafe','food','shops'].includes(patch.category))throw Error('Choose a valid store category.');if(!Number.isFinite(min)||!Number.isFinite(max)||min<0||max<min||max>10000)throw Error('Store price minimum must not exceed maximum (RMB 0-10000).');if(!/^\d{2}:\d{2}-\d{2}:\d{2}$/.test(hours))throw Error('Use hours like 10:00-22:00.');const [a,b]=hours.split('-').map(x=>x.split(':').map(Number));if([...a,...b].some((n,i)=>n>(i%2?59:23))||a[0]*60+a[1]>=b[0]*60+b[1])throw Error('Use valid same-day opening and closing times.');return stores.map(s=>s.id===id?{...s,name,min,max,category:patch.category,hours,quiet:!!patch.quiet}:s);}
 function route(stores,c,id,mode='2d'){validContext(c);const s=stores.find(x=>x.id===id);if(!s)throw Error('Unknown destination.');if(!['2d','ar'].includes(mode))throw Error('Unknown navigation mode.');const start=origins[c.origin];const points=[start,[170,start[1]],[170,s.pos[1]],s.pos];const meters=Math.round(points.slice(1).reduce((n,p,i)=>n+Math.hypot(p[0]-points[i][0],p[1]-points[i][1]),0)*.5);return {storeId:id,originId:c.origin,mode,points,meters,simulated:true,category:c.category,budget:[c.min,c.max]};}
 function eventsInRange(events,min,max){if(!Number.isFinite(min)||!Number.isFinite(max)||min<0||min>max)throw Error('Use a valid amount range.');return events.filter(e=>Number.isFinite(e.budgetMax)&&e.budgetMax>=min&&e.budgetMax<=max);}
 const api={initialStores,origins,fresh,validContext,recommend,interpret,editStore,route,eventsInRange};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateModel=api;
})(typeof window!=='undefined'?window:globalThis);
