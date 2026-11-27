// One merchant-card component, with comparison or one-at-a-time browsing.
(function(root){
 'use strict';
 function clean(value){if(value==null)return null;if(!['compare','focus'].includes(value))throw Error('Invalid recommendation presentation');return value;}
 function resolve(value,count=0,previous=null){return clean(value)||(count>0?(count>1?'compare':'focus'):clean(previous)||'compare');}
 const api={clean,resolve};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateRecommendationPresentation=api;
})(typeof window!=='undefined'?window:globalThis);
