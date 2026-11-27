(function(root){
 'use strict';
 const M=typeof module!=='undefined'&&module.exports?require('./model.js'):root.MallMateModel;
 const Intent=typeof module!=='undefined'&&module.exports?require('./mall-intent.js'):root.MallMateIntent;
 const Clarifications=typeof module!=='undefined'&&module.exports?require('./clarification-count.js'):root.MallMateClarificationCount;
 const groups=[['火锅','hotpot','hot pot'],['面条','拉面','面食','noodles','noodle','ramen'],['咖啡','coffee','cafe','café'],['奶茶','milk tea','bubble tea'],['海鲜','seafood'],['烧烤','barbecue','bbq'],['寿司','sushi'],['汉堡','burger','burgers'],['甜品','蛋糕','dessert','cake'],['辣','spicy'],['书店','books','bookstore']];
 const escape=s=>s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
 const canonical=term=>{const value=term.trim().toLowerCase();return groups.find(g=>g.includes(value))?.[0]||value;};
 const unique=xs=>[...new Set(xs.filter(x=>typeof x==='string').map(canonical).filter(x=>x&&x.length<=60))].slice(0,60);
 function expandExcludedTerms(terms=[]){return [...new Set(unique(terms).flatMap(term=>groups.find(g=>g[0]===term)||[term]))];}
 function exclusions(text){
  let positiveText=String(text||'');const terms=[];
  // Match bounded negative clauses; numeric limits and noise preferences are handled by Model.interpret.
  const negative=/(?:不想吃|不想喝|不想要|不喜欢|不要吃|不要喝|不要|不吃|不喝|别吃|别喝|排除|除了)([^，。！？,!?；;\n]{1,30})|\b(?:do not want|don't want|don't like|do not like|not interested in|anything but|except|without|no|not)\s+([^,.!?;\n]{1,60})/gi;
  positiveText=positiveText.replace(negative,(whole,zh,en)=>{
   let term=(zh||en||'').split(/但是|不过|但|而是|然后|想要|我要|我想|\b(?:but|instead|and\s+(?:(?:i|we)\s+)?(?:want|would|need|like|prefer|will|can|let))\b/i)[0].trim();
   if(!term||/^(?:超过|多于|低于|安静|要求安静|quiet|more than|less than|under|below|longer|sure|preference|preferences|matter|idea|thanks|thank you)\b/i.test(term)||/^(?:超过|多于|低于|安静|要求安静)/.test(term)||/\d/.test(term))return whole;
   term=term.replace(/(?:了|吧|的店|的)$/,'').replace(/\s+(?:please|thanks)$/i,'').trim();
   if(!term)return whole;
   const matches=groups.filter(g=>g.some(x=>new RegExp(/[a-z]/i.test(x)?'\\b'+escape(x)+'\\b':escape(x),'i').test(term)));
   if(matches.length)terms.push(...matches.map(g=>g[0]));else terms.push(term);
   // Keep any following positive clause so "no noodles, coffee" still resolves correctly.
   const at=whole.indexOf(zh||en);return whole.slice(at+(zh||en).indexOf(term)+term.length).replace(/^(?:了|吧|的店|的)/,'');
  });
  return {excludedTerms:unique(terms),positiveText:positiveText.trim()};
 }
 function extractExcludedTerms(text){return exclusions(text).excludedTerms;}
 function explicitCategory(text){
  if(/\b(?:coffee|cafe|café|drink|drinks|thirsty)\b|咖啡|奶茶|甜品|喝|口渴/.test(text))return 'cafe';
  if(/\b(?:food|eat|meal|lunch|dinner|hungry|noodles?|hotpot|hot pot|restaurant)\b|吃|餐|面条|火锅|饿/.test(text))return 'food';
  if(/\b(?:shops?|shopping|books?|clothes?|gifts?)\b|购物|逛|书|衣服|礼物/.test(text))return 'shops';
  if(/any category|all categories|不限类别|任何店/.test(text))return 'all';
  return null;
 }
 function decide(input={}){return applyPolicy(input);}
 function correction(text,prior){
  let remaining=unique(prior),positiveText=text;
  const clear=/取消所有排除|清空排除|没有忌口|什么都可以吃|\b(?:clear|remove|reset) (?:all )?(?:exclusions|excluded preferences)\b|\bno (?:food )?restrictions\b/i;
  if(clear.test(text)){remaining=[];positiveText=positiveText.replace(clear,'');}
  const removal=/(?:取消排除|别排除|不要排除|不用排除|不再排除)([^，。！？,!?；;\n]{1,30})|\b(?:do not exclude|don't exclude|stop excluding|allow|remove exclusion(?: for)?)\s+([^,.!?;\n]{1,60})/gi;
  positiveText=positiveText.replace(removal,(_whole,zh,en)=>{const target=(zh||en).trim();remaining=remaining.filter(term=>!expandExcludedTerms([term]).some(alias=>target.toLowerCase().includes(alias)));return '';});
  return {remaining,positiveText};
 }
 function applyPolicy(input={},aiResult){
  const text=String(input.text||'').trim(),base={...input.context};M.validContext(base);
  const corrected=correction(text,Array.isArray(input.excludedTerms)?input.excludedTerms:[]);
  const extracted=exclusions(corrected.positiveText),positive=extracted.positiveText.toLowerCase();
  const normalized=positive.replace(/\bno more than\b/g,'under');
  const interpreted=normalized?M.interpret(normalized,base):{context:base,recognised:false};
  const resetCategory=/any category|all categories|不限类别|任何店/.test(positive);
  const vague=/^(?:anything(?: is fine)?|something nice|something|whatever|随便|都行|随意|不限)\s*[.!。！]?$/i.test(positive);
  const detected=resetCategory?{kind:'browse',topic:null}:Intent.detect(positive);
  let intent=detected||Intent.clean(input.intent);
  const explicit=detected?Intent.category(detected):explicitCategory(positive);
  if(explicit&&!detected&&Intent.category(intent)!==explicit)intent={kind:({all:'browse',cafe:'drink',food:'food',shops:'shopping'})[explicit],topic:null};
  let context=aiResult?M.validContext({...aiResult.context}):interpreted.context;
  const aiChanged=!!aiResult&&context.category!==base.category&&!!positive&&!vague&&!detected&&!explicit&&!interpreted.recognised;
  if(aiChanged)intent={kind:({all:'browse',cafe:'drink',food:'food',shops:'shopping'})[context.category],topic:null};
  // A negative food preference must not become a positive category change.
  if(extracted.excludedTerms.length)context={...context,category:explicit||base.category};
  if(explicit)context={...context,category:explicit};
  else if(intent)context={...context,category:Intent.category(intent)};
  const clarificationsUsed=Clarifications.count(input.clarificationsUsed);
  const affirmative=/想|要|改成|来|吃|喝|可以了|\b(?:want|like|prefer|instead|eat|drink|have|now)\b|\bis (?:fine|okay|ok)\b/i.test(positive);
  const retained=corrected.remaining.filter(term=>!affirmative||!expandExcludedTerms([term]).some(alias=>new RegExp(/[a-z]/i.test(alias)?'\\b'+escape(alias)+'\\b':escape(alias),'i').test(positive)));
  const excludedTerms=unique([...retained,...extracted.excludedTerms]);
  const meaningful=intent||interpreted.recognised||explicit||aiChanged||excludedTerms.length||/\d/.test(positive);
  const question='What would you like to do here?';
  const repeatedQuestion=Array.isArray(input.history)&&input.history.some(m=>m?.role==='agent'&&m.text===question);
  const ask=base.category==='all'&&!meaningful&&!repeatedQuestion;
  // This offline fallback avoids repeating its generic question; the live Agent decides its own questions.
  if(ask)return {action:'ask',context:base,intent,reply:question,question,options:[{label:'Look around',value:'Just browsing'},{label:'Shopping',value:'Shopping'},{label:'Food & drink',value:'Something to eat'},{label:'Take a break',value:'Take a break'},{label:'Things to do',value:'Entertainment'},{label:'Find facilities',value:'Find facilities'}],clarificationsUsed:Clarifications.increment(clarificationsUsed),excludedTerms,positiveText:extracted.positiveText};
  // Preserve a known category on vague follow-ups even if the model guesses another one.
  if(!meaningful)context={...context,category:base.category};
  return {action:'recommend',context,intent,reply:'Here are some options.',question:null,options:[],clarificationsUsed,excludedTerms,positiveText:extracted.positiveText};
 }
 const api={decide,applyPolicy,extractExcludedTerms,expandExcludedTerms};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateConversation=api;
})(typeof window!=='undefined'?window:globalThis);
