import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import { renderMarkdown } from '../WebReader/markdown.mjs';
import { highlightSearch, clearSearch } from '../WebReader/search.mjs';

function article(source) {
  const { document } = parseHTML(`<html><body><article>${renderMarkdown(source).html}</article></body></html>`);
  return document.querySelector('article');
}

const python = '# 中文注释\ndef average(scores):\n\treturn sum(scores) / len(scores)\n\nprint("平均分 👩🏽‍💻", average([86, 92, 95]))\n';

test('fenced code highlights common languages and aliases without changing the source text', () => {
  for (const [language, source] of [
    ['python', python], ['py', python], ['Python title="分数.py"', python],
    ['js', 'const title = "学习"; console.log(42);\n'],
    ['ts', 'interface Note { title: string; minutes: number; }\n'],
    ['Swift', 'let title = "学习"\nfunc minutes() -> Int { return 25 }\n'],
    ['c', '#include <stdio.h>\nint main() { printf("学习"); return 0; }\n'],
    ['c++', '#include <iostream>\nint main() { std::cout << "学习" << 42; }\n'],
    ['java', 'public class Note { private int minutes = 25; }\n'],
    ['sh', '# 今日备份\necho "学习"\nfor file in *.md; do cat "$file"; done\n'],
    ['json', '{ "title": "学习", "minutes": 25, "done": true }\n'],
    ['yaml', 'title: 学习\nminutes: 25\ndone: true\n'],
    ['sql', "SELECT title FROM notes WHERE minutes > 25 AND tag = 'study';\n"],
    ['html', '<section class="note"><strong>学习</strong></section>\n'],
    ['css', '.note { color: #287267; padding: 12px; }\n'],
    ['rust', 'fn main() { let minutes: i32 = 25; println!("{}", minutes); }\n'],
  ]) {
    const root = article('```' + language + '\n' + source + '```');
    const code = root.querySelector('pre code');
    assert.ok(code.querySelector('span[class^="hljs-"]'), language);
    assert.equal(code.textContent, source, language);
    assert.equal(code.closest('[data-anchor]').dataset.anchor, 'line-0', language);
  }
});

test('Python uses distinct tokens for keywords, functions, strings, numbers and comments', () => {
  const code = article('```python\n' + python + '```').querySelector('code');
  for (const token of ['keyword', 'title', 'string', 'number', 'comment']) {
    assert.ok(code.querySelector('.hljs-' + token), token);
  }
});

test('unlabelled fences and indented blocks detect code while prose and inline code stay plain', () => {
  for (const source of ['```\n' + python + '```', python.trimEnd().split('\n').map(line => '    ' + line).join('\n')]) {
    const code = article(source).querySelector('pre code');
    assert.ok(code.querySelector('.hljs-keyword'));
    assert.equal(code.textContent, python);
  }
  assert.equal(article('```\n这是一段普通说明文字。\n```').querySelector('code span'), null);
  assert.equal(article('`const title = "学习"`').querySelector('code span'), null);
});

test('explicit plain text and unknown languages remain escaped and do not guess another language', () => {
  const source = python + '<script>alert("x")</script> & <div>原文</div>\n';
  for (const language of ['text', 'txt', 'plaintext', 'none', 'nohighlight', 'unknown-language', '"><img/src=x/onerror=alert(1)>']) {
    const root = article('```' + language + '\n' + source + '```');
    assert.equal(root.querySelector('code').textContent, source, language);
    assert.equal(root.querySelector('code span, script, img, [onerror]'), null, language);
  }
});

test('HTML-looking highlighted code stays inert and code fences do not render math', () => {
  const source = '<script>alert("x")</script>\n<img src=x onerror="alert(1)">\n<style>body{display:none}</style> & $P(A)$\n';
  const root = article('```html\n' + source + '```\n\n```math\nx^2\n```');
  assert.ok(root.querySelector('.hljs-tag'));
  assert.equal(root.querySelector('code').textContent, source);
  assert.equal(root.querySelector('script, img, style, [onerror], code .katex'), null);
  assert.ok(root.querySelector('.katex'), 'Math fences still use the formula renderer');
});

test('large blocks fall back to complete plain text and the next block still highlights', () => {
  for (const [language, count] of [['python', 1500], ['', 200]]) {
    const source = python.repeat(count);
    const root = article('```' + language + '\n' + source + '```\n\n```python\n' + python + '```');
    const [large, next] = root.querySelectorAll('code');
    assert.equal(large.textContent, source);
    assert.equal(large.querySelector('span'), null);
    assert.ok(next.querySelector('.hljs-keyword'));
  }
});

test('search can cross syntax tokens and clearing it preserves the highlighting and source range', () => {
  const root = article('# 代码\n\n```js\nconst title = "学习";\n```');
  const code = root.querySelector('code');
  const before = code.innerHTML;
  const target = highlightSearch(root, { query: 'const title = "学习"', sourceLine: 3 });
  assert.ok(target);
  assert.equal([...code.querySelectorAll('mark')].map(el => el.textContent).join(''), 'const title = "学习"');
  assert.ok(code.querySelector('.hljs-keyword mark'));
  assert.equal(code.closest('[data-source-start]').dataset.sourceStart, '2');
  clearSearch(root);
  assert.equal(code.innerHTML, before);
});
