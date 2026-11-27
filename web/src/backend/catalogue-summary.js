// A compact orientation from already-public catalogue labels, not generated branch claims.
'use strict';
function create(store){
 const content=store.content;
 if(content?.status==='published')return {text:content.text,basis:content.basis,source:content.source,updatedAt:content.updatedAt,origin:content.origin};
 const types=String(store.amapType||'').split(/[;；]/).map(t=>t.trim()).filter(Boolean);
 const category=types.at(-1)||store.rawCategory||null;
 const tags=[...new Set(store.tags||[])].filter(tag=>typeof tag==='string'&&tag.trim()&&!types.includes(tag)&&tag!==store.rawCategory).slice(0,2);
 const parts=[category,...tags].filter(Boolean);
 return parts.length?{text:parts.join(' · '),basis:'listed_type_and_tags'}:null;
}
module.exports={create};
