// Visit purposes are independent of the legacy category/AR contract.
(function(root){
'use strict';
const topics={
 toilet:/洗手间|卫生间|厕所|restroom|toilet|washroom/i,
 lift:/电梯|扶梯|elevator|escalator|\blift\b/i,
 parking:/停车|车位|停车场|parking|car park/i,
 nursery:/母婴室|哺乳|育婴|nursing room|baby care/i,
 movie:/电影|影院|影城|cinema|movie/i,
 play:/电玩|游戏厅|游乐|密室|保龄|ktv|卡拉|arcade|amusement|funfair|escape room|bowling|karaoke/i,
 kids:/亲子|儿童乐园|儿童游乐|kids|children|playground/i,
 fitness:/健身|运动馆|滑冰|gym|fitness|skating/i,
 seat:/休息区|休息室|座椅|公共座位|休憩|rest area|lounge|seating|benches/i,
 shoes:/鞋|\b(?:shoes?|sneakers?|footwear|boots?|trainers?)\b/i,
 clothes:/服装|衣服|穿搭|clothing|clothes|fashion/i,
 beauty:/化妆|护肤|美妆|cosmetics|skincare|beauty/i,
 electronics:/手机|数码|电器|电脑|electronics|phone|computer/i,
 books:/书店|图书|买书|bookstore|books/i,
 gift:/礼物|礼品|gift/i
};
const kinds=['browse','shopping','food','drink','rest','entertainment','facility'];
const belongs={facility:['toilet','lift','parking','nursery'],entertainment:['movie','play','kids','fitness'],rest:['seat'],shopping:['shoes','clothes','beauty','electronics','books','gift']};
function clean(value){if(!value||!kinds.includes(value.kind))return null;return {kind:value.kind,topic:value.kind==='rest'?'seat':belongs[value.kind]?.includes(value.topic)?value.topic:null};}
function detect(text){
 text=String(text||'');
 for(const kind of ['facility','entertainment','shopping']){
  if(kind==='entertainment'&&topics.shoes.test(text))return {kind:'shopping',topic:'shoes'};
  for(const topic of belongs[kind])if(topics[topic].test(text))return {kind,topic};
 }
 if(/休息|歇|坐一会|坐坐|坐下|等人|等朋友|\brest\b|sit down|somewhere to sit|take a break|waiting for/i.test(text))return {kind:'rest',topic:'seat'};
 if(/随便逛|逛逛|走走|打发时间|不知道逛|just brows|look around|wander|explor|window shopping/i.test(text))return {kind:'browse',topic:null};
 if(/服务设施|找设施|facilit|amenit/i.test(text))return {kind:'facility',topic:null};
 if(/娱乐|玩一会|玩点|玩什么|entertainment|have fun|something fun/i.test(text))return {kind:'entertainment',topic:null};
 if(/购物|买东西|逛店|\bshopping\b|buy something|\bshops?\b/i.test(text))return {kind:'shopping',topic:null};
 if(/咖啡|奶茶|甜品|喝|口渴|coffee|cafe|café|drink|thirsty/i.test(text))return {kind:'drink',topic:null};
 if(/吃|餐|饿|food|\beat\b|meal|lunch|dinner|hungry|restaurant/i.test(text))return {kind:'food',topic:null};
 return null;
}
function category(intent){return ({browse:'all',shopping:'shops',food:'food',drink:'cafe',rest:'all',entertainment:'all',facility:'all'})[intent?.kind]||null;}
function footwearEvidence(store){
 // Amap's shared apparel parent includes the character 鞋; it does not identify a shoe shop.
 const evidence=[store.amapType,store.rawCategory,...(store.tags||[])].filter(Boolean).join(' ').replace(/服装鞋帽皮具店/g,'');
 return /鞋店|鞋类|鞋品|鞋靴|鞋帽店|运动鞋|皮鞋|女鞋|男鞋|童鞋|体育用品店|\b(?:footwear|shoes?|sneakers?|boots?|trainers?|sportswear|sporting goods|sports goods)\b/i.test(evidence);
}
function matches(store,intent){
 intent=clean(intent);if(!intent)return true;
 const text=[store.name,store.amapType,store.rawCategory,...(store.tags||[])].filter(Boolean).join(' ');
 // Normalized entities require catalogue type evidence, not a brand-name guess.
 if(store.entityType){
  if(['facility','rest'].includes(intent.kind)&&store.entityType!=='facility')return false;
  if(intent.kind==='entertainment'&&store.entityType!=='entertainment')return false;
  if(intent.kind==='shopping'&&store.entityType!=='retail')return false;
  if(intent.kind==='food'&&store.entityType!=='food')return false;
  if(intent.kind==='drink'&&store.entityType!=='drink')return false;
 }
 if(intent.topic==='shoes')return footwearEvidence(store);
 if(intent.topic)return topics[intent.topic].test(text);
 if(intent.kind==='shopping')return ![...belongs.facility,...belongs.entertainment,...belongs.rest].some(t=>topics[t].test(text));
 if(['facility','entertainment'].includes(intent.kind))return store.entityType===intent.kind||belongs[intent.kind].some(t=>topics[t].test(text));
 return true;
}
function emptyMessage(intent){return ({facility:'This facility is not in the verified directory yet.',rest:'No verified resting areas are listed yet.',entertainment:'No matching activities are listed yet.'})[intent?.kind]||'No matches for these preferences';}
const api={clean,detect,category,matches,emptyMessage};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateIntent=api;
})(typeof window!=='undefined'?window:globalThis);
