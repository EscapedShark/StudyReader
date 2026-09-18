export function clearSearch(root) {
  const parents = new Set();
  for (const mark of root.querySelectorAll('mark.search-highlight')) {
    parents.add(mark.parentNode);
    mark.replaceWith(...mark.childNodes);
  }
  for (const block of root.querySelectorAll('.search-target')) block.classList.remove('search-target');
  for (const parent of parents) parent.normalize();
}

// Keep an index back to the original UTF-16 text when case, accents or PDF ligatures expand.
function folded(text) {
  let value = '', starts = [], ends = [], offset = 0;
  for (const character of text) {
    const normalized = character.normalize('NFKD').replace(/\p{M}/gu, '').toLocaleLowerCase();
    value += normalized;
    for (let i = 0; i < normalized.length; i++) { starts.push(offset); ends.push(offset + character.length); }
    // Include a combining accent that belongs to the preceding character in its highlight.
    if (!normalized && ends.length) ends[ends.length - 1] = offset + character.length;
    offset += character.length;
  }
  return { value, starts, ends };
}

function highlight(block, text) {
  const needle = folded(text).value;
  if (!needle) return;
  const doc = block.ownerDocument;
  const walker = doc.createTreeWalker(block, 4 /* SHOW_TEXT */);
  const nodes = [];
  let node, content = '';
  while ((node = walker.nextNode())) {
    // Never modify KaTeX's visual/assistive copies, or the source used by formula copying.
    if (node.parentElement?.closest('.katex,script,style')) continue;
    nodes.push({ node, start: content.length, end: content.length + node.nodeValue.length });
    content += node.nodeValue;
  }
  const normalized = folded(content), ranges = [];
  let from = 0, index;
  while (ranges.length < 200 && (index = normalized.value.indexOf(needle, from)) !== -1) {
    const start = normalized.starts[index], end = normalized.ends[index + needle.length - 1];
    if (!ranges.length || start >= ranges.at(-1).end) ranges.push({ start, end });
    from = index + needle.length;
  }
  for (const { node, start, end } of nodes) {
    const overlaps = ranges.filter(range => range.start < end && range.end > start);
    if (!overlaps.length) continue;
    const fragment = doc.createDocumentFragment(), value = node.nodeValue;
    let cursor = 0;
    for (const range of overlaps) {
      const lower = Math.max(0, range.start - start), upper = Math.min(value.length, range.end - start);
      fragment.append(doc.createTextNode(value.slice(cursor, lower)));
      const mark = doc.createElement('mark');
      mark.className = 'search-highlight';
      mark.textContent = value.slice(lower, upper);
      fragment.append(mark);
      cursor = upper;
    }
    fragment.append(doc.createTextNode(value.slice(cursor)));
    node.replaceWith(fragment);
  }
}

/// Source lines distinguish repeated paragraphs and locate matches inside lists, tables and
/// folded answers. A source-only match (e.g. LaTeX or a link destination) still marks its block.
export function highlightSearch(root, target) {
  clearSearch(root);
  if (!target || !Number.isInteger(target.sourceLine)) return null;
  let block = null, span = Infinity;
  for (const element of root.querySelectorAll('[data-source-start]')) {
    const start = Number(element.dataset.sourceStart), end = Number(element.dataset.sourceEnd);
    if (start <= target.sourceLine && target.sourceLine < end && end - start <= span) {
      block = element; span = end - start;
    }
  }
  if (!block) return null;
  for (let element = block; element && element !== root; element = element.parentElement) {
    if (element.tagName === 'DETAILS') element.open = true;
  }
  block.classList.add('search-target');
  highlight(block, target.matchedText || target.query || '');
  return block.querySelector('mark.search-highlight') || block;
}
