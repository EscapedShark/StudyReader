import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {parseHTML} from 'linkedom';
import {renderMarkdown,foldAnswers} from '../WebReader/markdown.mjs';
import {TypesetCache} from '../WebReader/typeset-cache.mjs';
import {highlightSearch,clearSearch} from '../WebReader/search.mjs';

const source=(await readFile(new URL('../WebReader/reader.mjs',import.meta.url),'utf8'))
  .replace(/^import[^\n]*\n/gm,'').replace(/^export /gm,'');
const preferences={fontSize:18,theme:'light',foldAnswers:false};
function fixture() {
  const {document,window}=parseHTML('<html><body><article></article></body></html>');
  const messages=[];
  const listeners=new Map();
  const context=vm.createContext({document,window:{webkit:{messageHandlers:{reader:{postMessage:message=>messages.push(message)}}}},
    renderMarkdown,foldAnswers,TypesetCache,highlightSearch,clearSearch,addEventListener:(name,fn)=>listeners.set(name,fn),clearTimeout,
    setTimeout:(fn,delay)=>{const timer=setTimeout(fn,delay);timer.unref();return timer;},
    requestAnimationFrame:fn=>queueMicrotask(fn),NodeFilter:{SHOW_TEXT:4},innerHeight:800,scrollY:0});
  context.scrollTo=(_x,y)=>{context.scrollY=y;};
  Object.defineProperty(document,'fonts',{value:{ready:Promise.resolve()},configurable:true});
  Object.defineProperty(document.documentElement,'scrollHeight',{value:5000});
  window.HTMLElement.prototype.getBoundingClientRect=function(){
    const index=[...document.querySelectorAll('.reading-block')].indexOf(this);
    return {top:Math.max(0,index)*200-context.scrollY,width:600,height:180};
  };
  window.HTMLElement.prototype.scrollIntoView=function(){
    const element=this.closest('[data-source-start]');
    const index=[...document.querySelectorAll('.reading-block')].indexOf(element);
    context.scrollY=Math.max(0,index)*200;
  };
  vm.runInContext(source,context);
  const payload=id=>({id,content:'# '+id+'\n\n'+Array.from({length:20},(_v,i)=>`${id} paragraph ${i}`).join('\n\n'),baseURL:`reader://library/${id}/a.md`,preferences});
  const gate=()=>{let release;document.fonts.ready=new Promise(resolve=>{release=resolve;});return release;};
  return {context,document,window,messages,payload,gate,reader:context.window.Reader,emit:(name,event={})=>listeners.get(name)?.(event)};
}

test('a pending preference restore cannot move the next article',async()=>{
  const f=fixture();
  await f.reader.render(f.payload('A'));
  f.context.scrollY=600;
  const release=f.gate();
  const setting=f.reader.preferences({...preferences,fontSize:20});
  const next=f.reader.render(f.payload('B'));
  release();
  await Promise.all([setting,next]);
  assert.equal(f.context.scrollY,0);
  f.reader.save();
  assert.equal(f.messages.at(-1).documentID,'B');
  assert.equal(f.messages.at(-1).payload.progress,0);
});

test('a search jump waits for layout, records deliberate navigation and rejects stale sessions',async()=>{
  const f=fixture();
  await f.reader.render({...f.payload('A'),session:'A-1'});
  assert.equal(f.reader.save().activity,null);
  assert.equal(await f.reader.revealSearch({query:'paragraph 10',matchedText:'paragraph 10',sourceLine:22},'A-old'),false);
  assert.equal(f.context.scrollY,0);
  assert.equal(await f.reader.revealSearch({query:'paragraph 10',matchedText:'paragraph 10',sourceLine:22},'A-1'),true);
  assert.equal(f.context.scrollY,2200);
  assert.ok(f.reader.save().activity.position.progress>0.5);
  const release=f.gate();
  const pending=f.reader.revealSearch({query:'paragraph 5',sourceLine:12},'A-1');
  const next=f.reader.render({...f.payload('B'),session:'B-1'});
  release();
  await Promise.all([pending,next]);
  assert.equal(f.context.scrollY,0);
  assert.equal(f.document.querySelector('.search-target'),null);
  assert.equal(f.reader.save().activity,null);
});

test('clearing or leaving during a pending search does not move or overwrite the checkpoint',async()=>{
  const f=fixture();
  await f.reader.render({...f.payload('A'),session:'A-1'});
  f.context.scrollY=600;
  f.reader.save();
  const release=f.gate();
  const pending=f.reader.revealSearch({query:'paragraph 10',sourceLine:22},'A-1');
  f.reader.clearSearch();
  release();
  assert.equal(await pending,false);
  assert.equal(f.context.scrollY,600);
  assert.equal(f.document.querySelector('mark'),null);
  const releaseAgain=f.gate();
  const leaving=f.reader.revealSearch({query:'paragraph 10',sourceLine:22},'A-1');
  const saved=f.reader.save('A-1',true);
  releaseAgain();
  assert.equal(await leaving,false);
  assert.deepEqual(f.reader.save('A-1',true,true).position,saved.position);
});
test('overlapping renders only announce the newest article as ready',async()=>{
  const f=fixture();
  const release=f.gate();
  const first=f.reader.render({...f.payload('A'),position:{anchor:'line-4',excerpt:'',offset:0,progress:0.5}});
  const second=f.reader.render(f.payload('B'));
  const third=f.reader.render(f.payload('C'));
  release();
  await Promise.all([first,second,third]);
  assert.deepEqual(f.messages.filter(message=>message.event==='ready').map(message=>message.documentID),['C']);
  assert.equal(f.context.scrollY,0);
});
test('preferences during initial layout preserve the render restoration and latest style',async()=>{
  const f=fixture();
  const release=f.gate();
  const render=f.reader.render({...f.payload('A'),position:{anchor:'line-6',excerpt:'',offset:0,progress:0.3}});
  await f.reader.preferences({...preferences,fontSize:24,theme:'dark'});
  f.reader.save();
  assert.equal(f.messages.filter(message=>message.event==='position').length,0);
  release();
  await render;
  assert.equal(f.document.documentElement.style.getPropertyValue('--reading-size'),'24px');
  assert.equal(f.document.documentElement.dataset.theme,'dark');
  assert.equal(f.context.scrollY,600);
});

test('leaving a column freezes the checkpoint before the WebView layout changes',async()=>{
  const f=fixture();
  await f.reader.render({...f.payload('A'),session:'A-1'});
  f.context.scrollY=2800;
  const saved=f.reader.save('A-1',true);
  assert.ok(saved.position.progress>0.6);
  f.context.scrollY=0;
  f.context.innerHeight=0;
  const hidden=f.reader.save('A-1',true,true);
  assert.deepEqual(hidden.position,saved.position);
  f.context.innerHeight=800;
  await f.reader.render({...f.payload('A'),session:'A-2',position:{anchor:'line-0',excerpt:'',offset:0,progress:0}});
  assert.equal(f.context.scrollY,2800,'Returning to the same article must not reset to a stale position');
});

test('a late save request for the previous article cannot checkpoint the new one',async()=>{
  const f=fixture();
  await f.reader.render({...f.payload('A'),session:'A-1'});
  f.context.scrollY=2200;
  const a=f.reader.save('A-1',true);
  await f.reader.render({...f.payload('B'),session:'B-1'});
  f.context.scrollY=600;
  const count=f.messages.length;
  assert.equal(f.reader.save('A-1',true),null);
  assert.equal(f.messages.length,count);
  f.reader.save('B-1',true);
  await f.reader.render({...f.payload('A'),session:'A-2',position:a.position});
  assert.equal(f.context.scrollY,2200);
});

test('a deliberate scroll back to the top still saves zero progress',async()=>{
  const f=fixture();
  await f.reader.render(f.payload('A'));
  f.context.scrollY=1800;
  assert.ok(f.reader.save().position.progress>0.4);
  f.context.scrollY=0;
  assert.equal(f.reader.save().position.progress,0);
});

test('repeated study headings restore the original block rather than the first matching text',async()=>{
  const f=fixture();
  const payload={...f.payload('A'),content:'# 练习\n\n'+Array.from({length:20},()=> '## 题目\n\n重复的题目说明。').join('\n\n')};
  await f.reader.render(payload);
  f.context.scrollY=2800;
  const saved=f.reader.save(undefined,true).position;
  await f.reader.render(f.payload('B'));
  await f.reader.render({...payload,position:saved});
  assert.equal(f.context.scrollY,2800);
});

test('restoring, passive layout scrolls and font changes never announce reading activity',async()=>{
  const f=fixture();
  await f.reader.render({...f.payload('A'),position:{anchor:'line-8',excerpt:'',offset:0,progress:0.4}});
  assert.equal(f.reader.save().activity,null);
  f.context.scrollY=600;
  f.emit('scroll');
  assert.equal(f.reader.save().activity,null);
  await f.reader.preferences({...preferences,fontSize:24});
  assert.equal(f.reader.save().activity,null);
});

test('user activity is recorded once per movement and a deliberate return to the top supersedes it',async()=>{
  const f=fixture();
  await f.reader.render({...f.payload('A'),session:'A-1'});
  f.emit('wheel');
  f.context.scrollY=2800;
  f.emit('scroll');
  const activity=f.reader.save().activity;
  assert.ok(activity.position.progress>0.6);
  assert.equal(f.reader.save().activity,activity,'Repeated saves retain the original action and timestamp');
  assert.equal(f.reader.save('A-1',true,true).activity,activity);
  f.reader.resume('A-1');
  f.emit('keydown',{key:'Home'});
  f.context.scrollY=0;
  f.emit('scroll');
  const top=f.reader.save().activity;
  assert.ok(top.sequence>activity.sequence);
  assert.equal(top.position.progress,0);
  assert.equal(f.reader.save('A-old'),null);
});

test('an explicitly supplied remote position overrides the same-document WebView cache without echoing',async()=>{
  const f=fixture();
  await f.reader.render({...f.payload('A'),session:'A-1'});
  f.emit('touchmove');
  f.context.scrollY=2800;
  f.emit('scroll');
  f.reader.save('A-1',true);
  await f.reader.render({...f.payload('A'),session:'A-2',preferSavedPosition:true,
    position:{anchor:'line-4',excerpt:'',offset:0,progress:0.1}});
  assert.equal(f.context.scrollY,400);
  assert.equal(f.reader.save().activity,null);
});

test('the reading position tracks scrolling in both directions and skips collapsed blocks',async()=>{
  const f=fixture();
  await f.reader.render(f.payload('A'));
  const anchors=[...f.document.querySelectorAll('.reading-block')].map(el=>el.dataset.anchor);
  assert.ok(anchors.length>10);
  // Answers folded away have no box. The walk has to step over them, not stop on them.
  const collapsed=new Set([3,4,9]);
  f.window.HTMLElement.prototype.getBoundingClientRect=function(){
    const index=[...f.document.querySelectorAll('.reading-block')].indexOf(this);
    if(collapsed.has(index))return{top:0,width:0,height:0};
    return{top:Math.max(0,index)*200-f.context.scrollY,width:600,height:180};
  };
  const expected=y=>{
    let best=-1,distance=Infinity;
    for(let i=0;i<anchors.length;i++){
      if(collapsed.has(i))continue;
      const d=Math.abs(i*200-y-60);
      if(d<distance){best=i;distance=d;}
    }
    return anchors[best];
  };
  const visit=async y=>{
    f.context.scrollY=y;
    f.emit('wheel');
    const saved=f.reader.save();
    assert.equal(saved.position.anchor,expected(y),`scrollY=${y}`);
  };
  for(let y=0;y<=3800;y+=97)await visit(y);       // reading forward
  for(let y=3800;y>=0;y-=53)await visit(y);       // flicking back up
  await visit(3600); await visit(120); await visit(2400);  // outline jumps
  for(const y of [40,240,1440,2440])await visit(y);  // exactly between two blocks: keep the earlier one
});

test('a measured attachment restores the saved position without waiting for it to decode',async()=>{
  const body='\n\n'+Array.from({length:20},(_v,i)=>`paragraph ${i}`).join('\n\n');
  const article=id=>({id,content:'# A\n\n![figure](fig.png)'+body,baseURL:'reader://library/A/a.md',
    preferences,position:{anchor:'line-6',excerpt:'',offset:0,progress:0.5}});
  // Without a size the page height is unknown until the file decodes, so the render waits for it.
  const waiting=fixture();
  let finished=false;
  waiting.reader.render({...article('A'),session:'unmeasured'}).then(()=>{finished=true;});
  await new Promise(resolve=>setTimeout(resolve,300));
  assert.equal(finished,false);
  assert.equal(waiting.document.querySelector('img').getAttribute('width'),null);

  const measured=fixture();
  const started=Date.now();
  await measured.reader.render({...article('A'),session:'measured',imageSizes:{'fig.png':[800,600]}});
  assert.ok(Date.now()-started<400,`took ${Date.now()-started}ms`);
  const image=measured.document.querySelector('img');
  assert.deepEqual([image.getAttribute('width'),image.getAttribute('height')],['800','600']);
  assert.equal(measured.messages.at(-1).event,'ready');
});

test('the MathML twin is only kept rendered while a screen reader is running',async()=>{
  const f=fixture();
  await f.reader.render(f.payload('A'));
  assert.equal(f.document.documentElement.hasAttribute('data-assistive'),false);
  await f.reader.render({...f.payload('B'),assistive:true});
  assert.equal(f.document.documentElement.hasAttribute('data-assistive'),true);
  // Turning VoiceOver off and on again must not need the article to be re-rendered.
  f.reader.assistive(false);
  assert.equal(f.document.documentElement.hasAttribute('data-assistive'),false);
  f.reader.assistive(true);
  assert.equal(f.document.documentElement.hasAttribute('data-assistive'),true);
  // The formula source stays in the DOM either way: copying LaTeX and saved excerpts rely on it.
  const math=renderMarkdown('$$P(A)$$\n');
  assert.ok(math.html.includes('annotation encoding="application/x-tex"'));
});
