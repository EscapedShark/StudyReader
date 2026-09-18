import test from 'node:test';
import assert from 'node:assert/strict';
import {parseHTML} from 'linkedom';
import {renderMarkdown,foldAnswers} from '../WebReader/markdown.mjs';
import {highlightSearch,clearSearch} from '../WebReader/search.mjs';

function article(source, fold = false) {
  const {document}=parseHTML(`<html><body><article>${renderMarkdown(source).html}</article></body></html>`);
  const root=document.querySelector('article');
  foldAnswers(root,fold);
  return root;
}

test('source coordinates choose the exact repeated paragraph and unfold its answer',()=>{
  const root=article('# 例题\n\n重复的关键词\n\n## 答案\n\n重复的关键词\n\n## 下一题\n\n其他内容',true);
  const target=highlightSearch(root,{query:'关键词',matchedText:'关键词',sourceLine:6});
  assert.equal(target.textContent,'关键词');
  assert.equal(target.closest('[data-source-start]').dataset.sourceStart,'6');
  assert.equal(target.closest('details').open,true);
  assert.equal(root.querySelectorAll('mark').length,1);
  assert.equal(root.querySelector('p').querySelector('mark'),null,'Do not highlight the earlier identical paragraph');
});

test('Unicode accents, ligatures, combining marks and inline markup stay intact',()=>{
  const root=article('👩🏽‍💻 Un **Café** et Cafe\u0301, conﬁguration.');
  const text=root.textContent;
  highlightSearch(root,{query:'cafe',matchedText:'Café',sourceLine:0});
  assert.deepEqual([...root.querySelectorAll('mark')].map(el=>el.textContent),['Café','Cafe\u0301']);
  assert.ok(root.querySelector('strong mark'));
  highlightSearch(root,{query:'confi',matchedText:'conﬁ',sourceLine:0});
  assert.equal(root.querySelector('mark').textContent,'conﬁ');
  assert.equal(root.textContent,text);
  clearSearch(root);
  assert.equal(root.querySelector('mark'),null);
  assert.equal(root.querySelector('.search-target'),null);
  assert.equal(root.textContent,text);
  assert.equal(root.querySelector('strong').textContent,'Café');
});

test('a phrase can highlight text spanning inline elements without replacing the link',()=>{
  const root=article('开始 [条件](https://example.com)概率 与 **统计** 推断。');
  const link=root.querySelector('a');
  highlightSearch(root,{query:'条件概率',sourceLine:0});
  assert.equal([...root.querySelectorAll('mark')].map(el=>el.textContent).join(''),'条件概率');
  assert.equal(root.querySelector('a'),link);
  assert.equal(link.getAttribute('href'),'https://example.com');
});

test('headings, tight list items, table rows and fenced code have navigable source ranges',()=>{
  for(const [source,line,text] of [
    ['# 标题词',0,'标题词'],
    ['- 列表首项\n- 列表匹配词',1,'匹配词'],
    ['| 列 |\n| --- |\n| 表格匹配词 |',2,'匹配词'],
    ['```swift\nlet value = "代码匹配词"\n```',1,'匹配词'],
    ['## 答案\n\n内容',0,'答案'],
  ]) {
    const root=article(source,true);
    const match=highlightSearch(root,{query:text,sourceLine:line});
    assert.ok(match,source);
    assert.equal(match.textContent,text,source);
  }
});

test('LaTeX-only and link-destination matches highlight the source block without modifying formulas',()=>{
  const root=article('$$\n\\frac{1}{2}\n$$\n\n[参考](https://example.com/target)');
  const math=root.querySelector('.katex').outerHTML;
  assert.ok(highlightSearch(root,{query:'frac',sourceLine:1}));
  assert.equal(root.querySelector('.katex').outerHTML,math);
  assert.equal(root.querySelector('mark'),null);
  assert.ok(root.querySelector('.search-target .katex'));
  assert.ok(highlightSearch(root,{query:'example.com',sourceLine:4}));
  assert.equal(root.querySelector('.search-target').tagName,'P');
});

test('front matter, CRLF and escaped HTML retain the same source coordinate system',()=>{
  const root=article('\uFEFF---\r\ntitle: hidden\r\n---\r\n# 标题\r\n\r\n<script>不能执行</script> & 内容');
  highlightSearch(root,{query:'<script>',sourceLine:2});
  assert.equal(root.querySelector('script'),null);
  assert.equal([...root.querySelectorAll('mark')].map(el=>el.textContent).join(''),'<script>');
  assert.equal(root.querySelector('.search-target').dataset.sourceStart,'2');
});
