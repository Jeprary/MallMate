// Guest-facing summaries are curated separately from the Agent's private review evidence.
(function(root){
 'use strict';
 const h=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const validRating=value=>Number.isFinite(value)&&value>=0&&value<=5;
 function score(value){return value.toFixed(1);}
 function ratingLabel(value,zh){return zh?`${score(value)} 分，满分 5 分`:`${score(value)} out of 5`;}
 function summary(data,language){
  if(!validRating(data?.rating))return '';
  const zh=language==='zh';
  const count=Number.isInteger(data.count)&&data.count>0
   ?(zh?`${data.count} 条评价`:`${data.count} ${data.count===1?'review':'reviews'}`):'';
  const rating=score(data.rating);
  const stars=Array.from({length:5},(_,index)=>`<span style="--fill:${Math.round(Math.max(0,Math.min(1,data.rating-index))*100)}%">★</span>`).join('');
  return `<div class="detail-review-score" role="img" aria-label="${h([ratingLabel(data.rating,zh),count].filter(Boolean).join(zh?'，':', '))}" data-no-localize><span class="detail-review-stars" aria-hidden="true">${stars}</span><strong>${rating}</strong>${count?`<span class="detail-review-count">(${h(count)})</span>`:''}</div>`;
 }
 function section(data,language,{dining=true}={}){
  if(!Array.isArray(data?.highlights))return '';
  const zh=language==='zh',dateFormat=new Intl.DateTimeFormat(zh?'zh-CN':'en-US',{year:'numeric',month:'short',timeZone:'UTC'});
  const items=data.highlights.flatMap(review=>{
   const copy=review?.[language];
   if(!copy?.topic||!copy.summary)return [];
   const partial=review.dateLabel?.[language];
   const dateMarkup=Number.isFinite(Date.parse(review.date))
    ?`<time datetime="${h(review.date)}">${h(dateFormat.format(new Date(review.date)))}</time>`
    :partial?`<span>${h(partial)}</span>`:'';
   const scoreMarkup=validRating(review.rating)
    ?`<span role="img" aria-label="${h(ratingLabel(review.rating,zh))}"><span class="detail-review-star" aria-hidden="true">★</span> ${score(review.rating)}</span>`
    :'';
   return `<li><h3>${h(copy.topic)}</h3><p>${h(copy.summary)}</p>${dateMarkup||scoreMarkup?`<div class="detail-review-meta">${dateMarkup}${scoreMarkup}</div>`: ''}</li>`;
  });
  const heading=dining?(zh?'食客怎么说':'Diners say'):(zh?'顾客怎么说':'Shoppers say');
  return items.length?`<section class="detail-review-highlights" aria-labelledby="detail-review-heading" data-no-localize><h2 id="detail-review-heading">${heading}</h2><ul class="detail-review-rail" tabindex="0" aria-labelledby="detail-review-heading">${items.join('')}</ul></section>`:'';
 }
 root.MallMateStoreReviewHighlights={summary,section};
})(typeof window!=='undefined'?window:globalThis);
