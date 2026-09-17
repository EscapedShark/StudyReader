import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { parseHTML } from 'linkedom';
import { renderMarkdown, stripFrontMatter, localImageURL, foldAnswers } from '../WebReader/markdown.mjs';

function documentFor(html) { return parseHTML(`<html><body><article>${html}</article></body></html>`).document; }

test('probability corpus renders all math styles and retains accessible formula source', async () => {
  const input = await readFile(new URL('../samples/probability/阅读验收样例.md', import.meta.url), 'utf8');
  const result = renderMarkdown(input);
  const document = documentFor(result.html);
  assert.ok(document.querySelectorAll('.katex').length >= 20);
  assert.equal(document.querySelectorAll('.katex-error').length, 0);
  assert.ok(document.querySelector('annotation[encoding="application/x-tex"]'));
  assert.ok(document.querySelector('table'));
  assert.ok(result.outline.some(h => h.title === '括号分隔符'));
  assert.match(document.querySelector('pre').textContent, /\$P\(A \| B\)\$/);
  assert.match(document.body.textContent, /\$10 和 \$20/);
});

test('math syntax protects braces, backslashes and escaped delimiters from markdown', () => {
  const result = renderMarkdown(String.raw`Inline $\{1,2\}$ and \(x^2\).

\[
\begin{cases}1 & x>0 \\ 0 & x\le 0\end{cases}
\]`);
  const document = documentFor(result.html);
  assert.equal(document.querySelectorAll('.katex').length, 3);
  assert.equal(document.querySelectorAll('.katex-error').length, 0);
});

test('untrusted markdown is data: scripts and javascript links do not execute', () => {
  const result = renderMarkdown('<script>alert(1)</script>\n\n[x](javascript:alert(1))\n\n![x](https://example.com/tracker.png)');
  const document = documentFor(result.html);
  assert.equal(document.querySelector('script'), null);
  assert.equal(document.querySelector('a[href^="javascript:"]'), null);
  assert.equal(document.querySelector('img').getAttribute('src'), '');
});

test('local image resolution supports relative assets and refuses another collection', () => {
  const base = 'reader://library/group-1/chapters/lesson.md';
  assert.equal(localImageURL('../assets/图.png', base), 'reader://library/group-1/assets/%E5%9B%BE.png');
  assert.equal(localImageURL('../../group-2/private.png', base), '');
  assert.equal(localImageURL('file:///etc/passwd', base), '');
  assert.equal(localImageURL('data:image/svg+xml,evil', base), '');
});

test('folding answers preserves following sections and does not require raw HTML', () => {
  const result = renderMarkdown('# 标题\n\n## 题目\nQ\n\n### 解答\nA\n\n### 结论\nB\n\n## 下一题\nC');
  const document = documentFor(result.html);
  foldAnswers(document.querySelector('article'), true);
  const answer = document.querySelector('details');
  assert.equal(answer.open, false);
  assert.match(answer.textContent, /解答A/);
  assert.doesNotMatch(answer.textContent, /结论|下一题/);
  assert.equal(document.querySelectorAll('summary').length, 1);
  assert.ok(document.querySelector('#heading-2'));
});

test('optional front matter is stripped without changing normal horizontal rules', () => {
  assert.equal(stripFrontMatter('---\ntitle: A\n---\n# A'), '# A');
  assert.equal(stripFrontMatter('# A\n\n---\nB'), '# A\n\n---\nB');
});

test('unsupported formula stays local and subsequent paragraphs remain readable', () => {
  const result = renderMarkdown('$\\notARealCommand{x}$\n\n仍然可以阅读。');
  assert.match(result.html, /仍然可以阅读/);
  assert.match(result.html, /notARealCommand/);
});
