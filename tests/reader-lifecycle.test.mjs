import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {parseHTML} from 'linkedom';
import {renderMarkdown,foldAnswers} from '../WebReader/markdown.mjs';
import {TypesetCache} from '../WebReader/typeset-cache.mjs';

const source=(await readFile(new URL('../WebReader/reader.mjs',import.meta.url),'utf8'))
  .replace(/^import[^\n]*\n/gm,'').replace(/^export /gm,'');
const preferences={fontSize:18,theme:'light',foldAnswers:false};
function fixture() {
  const {document,window}=parseHTML('<html><body><article></article></body></html>');
  const messages=[];
  const context=vm.createContext({document,window:{webkit:{messageHandlers:{reader:{postMessage:message=>messages.push(message)}}}},
    renderMarkdown,foldAnswers,TypesetCache,addEventListener(){},clearTimeout,
    setTimeout:(fn,delay)=>{const timer=setTimeout(fn,delay);timer.unref();return timer;},
    requestAnimationFrame:fn=>queueMicrotask(fn),NodeFilter:{SHOW_TEXT:4},innerHeight:800,scrollY:0});
  context.scrollTo=(_x,y)=>{context.scrollY=y;};
  Object.defineProperty(document,'fonts',{value:{ready:Promise.resolve()},configurable:true});
  Object.defineProperty(document.documentElement,'scrollHeight',{value:5000});
  window.HTMLElement.prototype.getBoundingClientRect=function(){
    const index=[...document.querySelectorAll('.reading-block')].indexOf(this);
    return {top:Math.max(0,index)*200-context.scrollY,width:600,height:180};
  };
  vm.runInContext(source,context);
  const payload=id=>({id,content:'# '+id+'\n\n'+Array.from({length:20},(_v,i)=>`${id} paragraph ${i}`).join('\n\n'),baseURL:`reader://library/${id}/a.md`,preferences});
  const gate=()=>{let release;document.fonts.ready=new Promise(resolve=>{release=resolve;});return release;};
  return {context,document,messages,payload,gate,reader:context.window.Reader};
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
