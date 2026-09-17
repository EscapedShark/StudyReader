import { renderMarkdown, foldAnswers } from './markdown.mjs';

const article = document.querySelector('article');
let documentID = '', restoring = false, saveTimer, generation = 0;
let blocks = null;
function post(event, payload) {
  window.webkit?.messageHandlers?.reader?.postMessage({ event, payload, documentID });
}
// Typesetting formulas dominates opening an article, so the last few stay ready to reuse.
// The source text is kept as the key so re-imported material is never served from the cache.
const typesetCache = new Map();
const typesetLimit = 8_000_000;
let typesetBytes = 0;
function typeset(payload) {
  const cached = typesetCache.get(payload.id);
  if (cached && cached.content === payload.content) {
    typesetCache.delete(payload.id);
    typesetCache.set(payload.id, cached);
    return cached;
  }
  const result = renderMarkdown(payload.content, payload.baseURL);
  const entry = { content: payload.content, html: result.html, outline: result.outline };
  if (cached) { typesetBytes -= cached.html.length; typesetCache.delete(payload.id); }
  typesetCache.set(payload.id, entry);
  typesetBytes += entry.html.length;
  for (const [id, old] of typesetCache) {
    if (typesetBytes <= typesetLimit || typesetCache.size <= 1) break;
    typesetCache.delete(id);
    typesetBytes -= old.html.length;
  }
  return entry;
}
/// Scrolling asks for these several times a second, so the list is collected once per article.
function readingBlocks() {
  if (!blocks) blocks = [...article.querySelectorAll('.reading-block')];
  return blocks;
}
/// Only the first 100 characters are ever kept, so a long table is not flattened on every save.
function excerpt(element) {
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let text = '';
  while (text.trim().length < 100) {
    const node = walker.nextNode();
    if (!node) break;
    text += node.nodeValue;
  }
  return text.trim().slice(0, 100);
}
export function capturePosition() {
  let best = null, bestRect = null, bestDistance = Infinity;
  for (const element of readingBlocks()) {
    const rect = element.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) continue; // inside a collapsed answer
    const distance = Math.abs(rect.top - 60);
    if (distance < bestDistance) { best = element; bestRect = rect; bestDistance = distance; }
    else if (rect.top > 60) break; // blocks run down the page, so nothing below can be closer
  }
  if (!best) return { anchor: '', excerpt: '', offset: 0, progress: 0 };
  return {
    anchor: best.dataset.anchor || '',
    excerpt: excerpt(best),
    offset: -bestRect.top / Math.max(bestRect.height, 1),
    progress: Math.min(1, Math.max(0, scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)))
  };
}
function restorePosition(position) {
  if (!position) { scrollTo(0, 0); return; }
  const candidates = readingBlocks();
  const block = (position.excerpt && candidates.find(el => excerpt(el) === position.excerpt))
    || candidates.find(el => el.dataset.anchor === position.anchor);
  if (block) {
    let parent = block.parentElement;
    while (parent && parent !== article) {
      if (parent.tagName === 'DETAILS') parent.open = true;
      parent = parent.parentElement;
    }
    const rect = block.getBoundingClientRect();
    scrollTo(0, scrollY + rect.top + (position.offset || 0) * rect.height);
  } else {
    scrollTo(0, (position.progress || 0) * Math.max(0, document.documentElement.scrollHeight - innerHeight));
  }
}
function applyPreferences(prefs) {
  document.documentElement.style.setProperty('--reading-size', `${prefs.fontSize || 18}px`);
  document.documentElement.dataset.theme = prefs.theme || 'system';
}
async function settled() {
  await Promise.race([document.fonts.ready, new Promise(resolve => setTimeout(resolve, 2000))]);
  // WebKit can suspend animation frames while the view is offscreen or the app is inactive.
  await Promise.race([
    new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
    new Promise(resolve => setTimeout(resolve, 100))
  ]);
}
window.Reader = {
  async render(payload) {
    const run = ++generation;
    restoring = true;
    clearTimeout(saveTimer);
    documentID = payload.id;
    applyPreferences(payload.preferences);
    try {
      const result = typeset(payload);
      article.style.whiteSpace = '';
      article.innerHTML = result.html;
      foldAnswers(article, payload.preferences.foldAnswers);
      blocks = null;
      const images = [...article.querySelectorAll('img')];
      for (const img of images) {
        img.addEventListener('error', () => {
          const hint = document.createElement('span');
          hint.className = 'image-missing';
          hint.textContent = `图片未导入：${img.alt || '请连同图片所在文件夹一起导入'}`;
          img.replaceWith(hint);
          blocks = null;
        }, { once: true });
      }
      post('outline', result.outline);
      const saved = payload.position;
      if (saved && (saved.excerpt || saved.anchor || saved.progress > 0)) {
        // Landing on the saved spot needs a stable page height, so wait for the attachments.
        await Promise.race([
          Promise.all(images.map(img => img.complete ? Promise.resolve() :
            new Promise(resolve => { img.addEventListener('load', resolve, { once: true }); img.addEventListener('error', resolve, { once: true }); }))),
          new Promise(resolve => setTimeout(resolve, 1500))
        ]);
        await settled();
        if (run !== generation) return;
        restorePosition(saved);
        await settled();
      } else {
        // Opening at the top needs no measurement, so the article shows without that wait.
        scrollTo(0, 0);
        await settled();
      }
      if (run !== generation) return;
      restoring = false;
      post('ready', true);
    } catch (error) {
      article.textContent = `无法排版，以下是原文：\n\n${payload.content}`;
      article.style.whiteSpace = 'pre-wrap';
      blocks = null;
      restoring = false;
      post('error', String(error));
    }
  },
  async preferences(prefs) {
    const position = capturePosition();
    restoring = true;
    applyPreferences(prefs);
    for (const answer of article.querySelectorAll('details.answer')) answer.open = !prefs.foldAnswers;
    await settled();
    restorePosition(position);
    restoring = false;
  },
  scrollToHeading(id) {
    const target = document.getElementById(id);
    if (target) { target.closest('details')?.setAttribute('open', ''); target.scrollIntoView({ behavior: 'auto', block: 'start' }); }
  },
  save() { if (!restoring) post('position', capturePosition()); },
};
addEventListener('scroll', () => {
  clearTimeout(saveTimer);
  if (!restoring) saveTimer = setTimeout(() => window.Reader.save(), 250);
}, { passive: true });
addEventListener('pagehide', () => window.Reader.save());
document.addEventListener('visibilitychange', () => { if (document.hidden) window.Reader.save(); });
document.addEventListener('click', event => {
  const math = event.target.closest?.('.katex');
  if (!math) return;
  const source = math.querySelector('annotation[encoding="application/x-tex"]')?.textContent;
  if (source) post('formula', source);
});
