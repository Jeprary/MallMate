// Compatibility/analytics only. This count never permits or blocks a question.
(function(root){
 'use strict';
 function count(value){const number=Number(value);return Number.isSafeInteger(number)&&number>=0?number:0;}
 function increment(value){const number=count(value);return number<Number.MAX_SAFE_INTEGER?number+1:number;}
 const api={count,increment};if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MallMateClarificationCount=api;
})(typeof window!=='undefined'?window:globalThis);
