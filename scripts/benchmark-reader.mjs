import {performance} from 'node:perf_hooks';
import {renderMarkdown} from '../WebReader/markdown.mjs';
import {TypesetCache} from '../WebReader/typeset-cache.mjs';

// Measures HTML generation and retained payloads, not WebKit layout or total process memory.
const cache = new TypesetCache();
const math = String.raw`$$
\begin{aligned}
P(A\mid B)&=\frac{P(B\mid A)P(A)}{P(B)}\\
E[X]&=\int_{-\infty}^{\infty}xf(x)\,dx
\end{aligned}
$$`;
for (const count of [100, 500, 1000, 2500]) {
  const content = '# Probability\n\n' + Array.from({length:count}, (_v,i) => `## Example ${i}\n\n${math}`).join('\n\n');
  const id = `math-${count}`, baseURL = 'reader://library/example/example.md';
  const start = performance.now();
  const result = renderMarkdown(content, baseURL);
  const entry = cache.put(id, content, baseURL, result);
  console.log(JSON.stringify({formulas:count, inputBytes:Buffer.byteLength(content), htmlBytes:Buffer.byteLength(result.html),
    firstMS:performance.now()-start, estimatedEntryBytes:entry.cost, cached:cache.get(id,content,baseURL)!==null,
    retainedBytes:cache.bytes, budgetBytes:cache.maxBytes, entries:cache.entries.size}));
}
