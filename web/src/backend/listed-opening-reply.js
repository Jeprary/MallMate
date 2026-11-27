'use strict';

const numberOrScope='(?:only|just|all|both|neither|none|one|two|three|four|five|six|seven|eight|nine|ten|\\d+)';
const places='(?:shops?|stores?|restaurants?|spots?|places?|options?|picks?)';
const englishCount=new RegExp('\\b'+numberOrScope+'\\b(?:\\s+(?:(?:currently|still)\\s+)?open\\s+'+places+'|[^.!?;\\n]{0,64}\\b(?:open\\s+(?:right\\s+)?now|currently\\s+open|(?:listed\\s+(?:as\\s+)?|list\\s+as\\s+)open|(?:'+places+'|of\\s+(?:them|these))\\s+(?:(?:is|are|remain(?:s)?)\\s+)?(?:still\\s+)?open))\\b','i');
const chineseCount=/(?:(?:只有|仅有|只剩|仅剩|全部|[零一二两三四五六七八九十\d]+\s*(?:家|个))[^。！？；\n]{0,28}(?:还开着|开着|营业(?!时间|时段|状态|安排))|都(?:还|仍|在|已|正在)*(?:营业(?!时间|时段|状态|安排)|开着)|(?:营业中|还在营业|还开着)的?[^。！？；\n]{0,18}(?:只有|仅有|只剩|就这))/u;

const clock='(?:\\d{1,2}[:：]\\d{2}|\\d{1,2}\\s*(?:a\\.?m\\.?|p\\.?m\\.?|h(?:ours?)?\\b|点|时)|24[ -]hour|24\\s*\\/\\s*7|midnight|noon|凌晨|午夜|全天|通宵)';
const business='(?:\\b(?:open(?:s|ing)?|clos(?:e[sd]?|ing)|run[s]?|until|listed)\\b|(?:开门|打烊|关门|营业|开到|开至))';
const boundary='[^.!?。！？；\\n]{0,56}';
const scheduleClaim=new RegExp(business+boundary+clock+'|'+clock+boundary+business,'i');
const explicitHours=/\b24[ -]hours?\b|\b24\s*\/\s*7\b|\baround the clock\b|(?:24\s*小时|全天|通宵)营业/iu;
const roundTheClockQuestion=/\b(?:is|are|do|does)\b[^.!?\n]{0,56}\bopen\s+(?:24[ -]hours?|24\s*\/\s*7|around the clock)\b|(?:24\s*小时|全天|通宵)营业(?:的)?[吗么]|(?:是否|是不是)(?:24\s*小时|全天|通宵)营业/iu;
const scheduleRequested=text=>roundTheClockQuestion.test(text)||/hours?\s+(?:of\s+operation)|(?:opening|business|store|closing|trading)\s+hours|(?:what time|when)\b[^.!?\n]{0,64}\b(?:open|close)|营业(?:时间|时段)|(?:几|多少)点[^。！？\n]{0,12}(?:开|关|打烊|营业)|(?:什么时候|何时)[^。！？\n]{0,20}(?:开门|关门|打烊|营业)/iu.test(text);
const openingRequested=text=>scheduleRequested(text)||/\b(?:is|are)\b[^.!?\n]{0,60}\b(?:still )?open\b|(?:还开着|还开门|还营业|在营业|开门了|打烊了)[吗么]|(?:哪家|哪些)[^。！？\n]{0,16}(?:开着|营业)/iu.test(text);
const routineOpen=/^(?:(?:this|that|these|the)\s+[^.!?]{1,40}?\s+(?:are|is)\s+(?:all\s+)?|(?:all|both)(?: of (?:these|them))? are |they(?: are|['’]re) (?:all )?)?(?:(?:listed|marked)(?: as)? open(?: (?:right )?now)?|currently open|open (?:right )?now)[.!。]?$/iu;
const routineOpenChinese=/^(?:按(?:目录|所列)时段[，,]\s*)?(?:这(?:[几三两一]?家(?:店)?|些(?:店|推荐))|所选店铺)?(?:目前|现在)?(?:都|均)?(?:还|仍|正)?(?:在营业|营业中|开着)[。！]?$/u;
const routineOpenOnly=text=>routineOpen.test(text)||routineOpenChinese.test(text);
const localizeSchedule=(display,language)=>language==='zh'?display.replace(/\b(?:Daily|Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b/g,day=>({Daily:'每天',Mon:'周一',Tue:'周二',Wed:'周三',Thu:'周四',Fri:'周五',Sat:'周六',Sun:'周日'})[day]).replace(/24 hours/g,'全天').replace(/ next day/g,'（次日结束）'):display;

function cleanReason(reason){
 reason=reason.replace(/^(?:24\s*小时|全天|通宵)营业\s*[,，;；]\s*(?:随时)?/u,'');
 reason=reason.replace(/[,，;；]\s*(?:(?:营业|开门)(?:到|至)(?:深夜|半夜|午夜|凌晨)|(?:24\s*小时|全天|通宵)营业|(?:stays? )?open (?:late|until midnight|24[ -]hours?|24\s*\/\s*7))(?=[。.!！]|$)/iu,'');
 const isOpeningCopy=value=>routineOpenOnly(value)||scheduleClaim.test(value)||explicitHours.test(value)||englishCount.test(value)||chineseCount.test(value);
 if(!isOpeningCopy(reason))return reason;
 const sentences=new Intl.Segmenter('en',{granularity:'sentence'}).segment(reason);
 return Array.from(sentences,({segment})=>segment.split(/[;；]/u).map(clause=>clause.trim()))
  .flat().filter(clause=>clause&&!isOpeningCopy(clause)).join(' ').trim();
}

function render(reply,statuses,language,scheduleLanguage,schedules=[],answeringHours=false){
 const open=statuses.filter(status=>status==='listed_open').length;
 const closed=statuses.filter(status=>status==='listed_closed').length;
 for(const [field,value] of Object.entries({openingNote:language,scheduleNote:scheduleLanguage})){
  if(value!=null&&(!['en','zh'].includes(value)||!statuses.length))throw Error(field+' must be "en" or "zh" with nonempty selections, or omitted.');
 }
 if(!answeringHours){
  const sentences=new Intl.Segmenter(language||scheduleLanguage||'en',{granularity:'sentence'}).segment(reply);
  reply=Array.from(sentences).filter(({segment})=>!routineOpenOnly(segment.trim())).map(({segment})=>segment).join('').trim();
  if(!reply)throw Error('Write a brief reply that helps the user choose a store.');
 }
 const contradictsContract=value=>englishCount.test(value)||chineseCount.test(value)||scheduleClaim.test(value)||explicitHours.test(value);
 if(contradictsContract(reply)){
  const noteLanguage=scheduleLanguage||language;
  if(!noteLanguage||statuses.includes('unknown')){
   if(englishCount.test(reply)||chineseCount.test(reply))throw Error('Omit the current opening count and any routine open-now statement from reply. Listed status for these picks: '+JSON.stringify({listed_open:open,listed_closed:closed,unknown:statuses.length-open-closed})+'.');
   throw Error('Remove specific opening and closing times from reply. If listed hours matter for the requested visit, use optional scheduleNote="en" or "zh"; the server supplies the selected stores’ actual listed schedules.');
  }
  const sentences=new Intl.Segmenter(noteLanguage,{granularity:'sentence'}).segment(reply);
  reply=Array.from(sentences,part=>part.segment.trim()).filter(sentence=>sentence&&!contradictsContract(sentence)).join(noteLanguage==='zh'?'':' ');
  if(!reply)reply=noteLanguage==='zh'?'可以先看看这些选择。':'Here are some options.';
 }
 const append=(content,note,chinese)=>content+(/[.!?。！？…]$/.test(content)?'':chinese?'。':'.')+(chinese?'':' ')+note+(chinese?'。':'.');
 if(scheduleLanguage){
  const chinese=scheduleLanguage==='zh';
  const items=schedules.map(({name,display})=>name+(chinese?'：':': ')+(display?localizeSchedule(display,scheduleLanguage):chinese?'时段未知':'hours unknown'));
  if(items.length)reply=append(reply,(chinese?'目录时段：':'Listed hours — ')+items.join(chinese?'；':'; '),chinese);
 }
 return reply;
}

module.exports={render,scheduleRequested,openingRequested,cleanReason};
