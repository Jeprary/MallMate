(function(root){
'use strict';
const escape = value => String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const path = '/assets/optimized-photos/';
const photoSizes = {
 card: '(max-width: 750px) calc(50vw - 32px), 185px',
 recommendation: '104px',
 detail: '(max-width: 750px) 100vw, 420px',
 dish: '(max-width: 750px) calc(50vw - 32px), 185px',
 welcome: '(max-width: 460px) 100vw, 460px'
};
function responsive(url, usage) {
 const candidates = root.MallMatePhotoVariants?.[url];
 if (!candidates?.length) return null;
 return {
  src: path + candidates[0][0],
  srcset: candidates.map(([filename, width]) => `${path}${filename} ${width}w`).join(', '),
  sizes: photoSizes[usage]
 };
}
function attributes(url, usage) {
 const photo = responsive(url, usage);
 if (!photo) return `src="${escape(url)}"`;
 return `src="${photo.src}" srcset="${photo.srcset}" sizes="${photo.sizes}" data-original-photo="${escape(url)}"`;
}
function retry(image) {
 const original = image.dataset.originalPhoto;
 if (!original) return false;
 delete image.dataset.originalPhoto;
 image.removeAttribute('srcset');
 image.removeAttribute('sizes');
 image.src = original;
 return true;
}
function watch(image, onFailure) {
 const fail = () => {if (!retry(image)) onFailure();};
 image.addEventListener('error', fail);
 if (image.complete && !image.naturalWidth) fail();
}
root.MallMatePhotoDisplay = {attributes, responsive, watch};
})(typeof window !== 'undefined' ? window : globalThis);
