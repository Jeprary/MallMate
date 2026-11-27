'use strict';
// Official raw Search API. No arbitrary page fetches, IP localization or client secrets.
// Contract checked against https://api-docs.deepseek.com/guides/search/ (2026-11-12).
function create({getKey,fetcher=fetch}={}){
 if(typeof getKey!=='function'||typeof fetcher!=='function')throw Error('Search provider needs server credentials and fetch');
 async function search({query,limit=3,signal}){
  if(typeof query!=='string'||!query.trim()||query.length>120||!Number.isInteger(limit)||limit<1||limit>3)throw Error('Invalid search request');
  const key=getKey();if(!key)throw Error('Official search is not configured');
  const timeout=AbortSignal.timeout(20000),requestSignal=signal?AbortSignal.any([signal,timeout]):timeout;
  const response=await fetcher('https://api.deepseek.com/v1/tools/search',{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({query:query.trim(),count:limit,need_content:false}),signal:requestSignal,redirect:'error'});
  if(!response.ok)throw Error('Search API request failed ('+response.status+').');
  const data=await response.json();if(!Array.isArray(data.results))throw Error('Search API returned invalid results');
  return {provider:'DeepSeek Search API',results:data.results.slice(0,limit).map(row=>({title:row.title,url:row.url,snippet:row.snippet,publishedDate:row.date??null}))};
 }
 return {search};
}
module.exports={create};
