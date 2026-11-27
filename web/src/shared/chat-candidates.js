(function(root){
 'use strict';
 const Conversation=typeof module!=='undefined'&&module.exports?require('./conversation.js'):root.MallMateConversation;
 const Intent=typeof module!=='undefined'&&module.exports?require('./mall-intent.js'):root.MallMateIntent;
 const aliases=[['火锅','hot pot','hotpot'],['面条','面馆','noodles','noodle'],['咖啡','coffee','cafe','café'],['奶茶','milk tea','bubble tea'],['烧烤','barbecue','bbq'],['寿司','sushi'],['辣','spicy'],['海鲜','seafood']];
 function excluded(store,terms){const text=[store.name,store.nameEn,store.amapType||'',...(store.tags||[])].join(' ').toLocaleLowerCase();return Conversation.expandExcludedTerms(terms).some(term=>{const q=String(term).trim().toLocaleLowerCase();if(!q)return false;const group=aliases.find(g=>g.includes(q))||[q];return group.some(t=>text.includes(t));});}
 function entityType(store){return store.entityType||({food:'food',cafe:'drink',shops:'retail'})[store.category]||'unknown';}
 function categoryMatches(store,category){return category==='all'||entityType(store)===({food:'food',cafe:'drink',shops:'retail'})[category];}
 const normalizeSearch=value=>value.normalize('NFKD').replace(/\p{Mark}/gu,'').replace(/[‘’]/g,"'").toLocaleLowerCase();
 function directory(stores,{query='',facet='all'}={}){
  const q=normalizeSearch(String(query).trim()),type=({cafe:'drink',shops:'retail'})[facet]||facet;
  return stores.filter(store=>(type==='all'||entityType(store)===type)&&(!q||normalizeSearch([store.name,store.nameEn,store.amapType,...(store.tags||[])].filter(Boolean).join(' ')).includes(q)));
 }
 function recommend(stores,context,session={}){
  const blocked=new Set(session.excludedStoreIds||[]);
  const sorted=stores.filter(s=>Intent.matches(s,session.intent)&&!blocked.has(s.id)&&categoryMatches(s,context.category)&&!excluded(s,session.excludedTerms||[])&&(!Number.isFinite(s.minutes)||!Number.isFinite(context.time)||s.minutes<=context.time)&&(!session.budgetSpecified||['facility','rest'].includes(session.intent?.kind)||(s.priceKnown!==false&&Number.isFinite(s.min)&&Number.isFinite(s.max)&&s.min<=context.max&&s.max>=context.min)))
   .sort((a,b)=>(context.quiet?Number(!!b.quiet)-Number(!!a.quiet):0)||(Number.isFinite(a.min)?a.min:Infinity)-(Number.isFinite(b.min)?b.min:Infinity)||String(a.id).localeCompare(String(b.id)));
  if(context.category!=='all')return sorted;
  const first=['retail','drink','food','entertainment','facility','unknown'].map(type=>sorted.find(s=>entityType(s)===type)).filter(Boolean),ids=new Set(first.map(s=>s.id));
  return [...first,...sorted.filter(s=>!ids.has(s.id))];
 }
 function hasBudget(text){return /(?:under|below|less than|budget|不超过|低于|最多|预算|以内|小于)\s*(?:rmb\s*|¥\s*|￥\s*)?\d|\d+(?:\.\d+)?\s*(?:元|rmb)?\s*(?:以内|以下)|\d+(?:\.\d+)?\s*[-~到至]\s*\d+/i.test(String(text));}
 const api={recommend,directory,entityType,excluded,hasBudget};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateCandidates=api;
})(typeof window!=='undefined'?window:globalThis);
