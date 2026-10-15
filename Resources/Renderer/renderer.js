let renderRevision=0;
const root=document.getElementById('content');
function notifyHeight(){window.webkit?.messageHandlers?.height?.postMessage(Math.min(24000,Math.ceil(root.getBoundingClientRect().height)));}
new ResizeObserver(notifyHeight).observe(root);
window.renderResult=async function(text,format,fontSize,dark,remoteImages){
 const revision=++renderRevision;
 document.body.classList.toggle('dark',dark);document.body.style.fontSize=Math.max(10,Math.min(40,fontSize))+'px';
 document.getElementById('highlightStyle').href=dark?'highlight-dark.css':'highlight-light.css';
 if(format!=='markdown'){root.className='plain';root.textContent=text;notifyHeight();return;}
 root.className='';
 const raw=marked.parse(text,{gfm:true,breaks:true});
 root.innerHTML=DOMPurify.sanitize(raw,{FORBID_TAGS:['style','form','input','button','iframe','object','embed','video','audio'],FORBID_ATTR:['style'],ALLOW_DATA_ATTR:false});
 root.querySelectorAll('a').forEach(a=>{try{if(!['https:','http:','mailto:'].includes(new URL(a.href).protocol))a.removeAttribute('href');}catch{a.removeAttribute('href');}});
 root.querySelectorAll('img').forEach(img=>{const src=img.getAttribute('src')||'';if(!src.startsWith('data:image/')&&(!remoteImages||!src.startsWith('https://'))){const label=document.createElement('span');label.className='image-placeholder';label.textContent=img.alt?'[图片：'+img.alt+']':'[图片]';img.replaceWith(label);}else img.addEventListener('load',notifyHeight,{once:true});});
 root.querySelectorAll('pre code:not(.language-mermaid)').forEach(code=>{try{hljs.highlightElement(code);}catch{}});
 try{renderMathInElement(root,{delimiters:[{left:'$$',right:'$$',display:true},{left:'\\[',right:'\\]',display:true},{left:'$',right:'$',display:false},{left:'\\(',right:'\\)',display:false}],throwOnError:false,trust:false,maxExpand:500});}catch{}
 const diagrams=[...root.querySelectorAll('code.language-mermaid')];
 if(diagrams.length){mermaid.initialize({startOnLoad:false,securityLevel:'strict',htmlLabels:false,flowchart:{htmlLabels:false},theme:dark?'dark':'default',maxTextSize:50000});}
 for(let i=0;i<Math.min(diagrams.length,20);i++){
  const code=diagrams[i];try{const result=await mermaid.render('diagram-'+revision+'-'+i,code.textContent.slice(0,50000));if(revision!==renderRevision)return;const wrap=document.createElement('div');wrap.className='mermaid-render';wrap.innerHTML=DOMPurify.sanitize(result.svg,{USE_PROFILES:{svg:true,svgFilters:true},ADD_TAGS:['foreignObject','div','span','p','br'],ADD_ATTR:['xmlns']});code.parentElement.replaceWith(wrap);}catch{if(revision!==renderRevision)return;code.parentElement.classList.add('error');}
 }
 notifyHeight();
};
document.addEventListener('click',event=>{const a=event.target.closest('a');if(a){event.preventDefault();if(a.href)window.webkit?.messageHandlers?.link?.postMessage({url:a.href,text:a.textContent||""});}});
notifyHeight();
