import { renderMarkdown, foldAnswers } from './markdown.mjs';
import { TypesetCache } from './typeset-cache.mjs';

const article = document.querySelector('article');
let documentID = '', restoring = false, saveTimer, generation = 0;
let preferencesGeneration = 0;
let rendering = false;
let suspended = true, session = '', lastPosition = null, lastCheckpoint = 0;
let lastActivity = null, activitySequence = 0, intentUntil = 0, pendingUserScroll = false, userScrollAt = 0;
let blocks = null;
function post(event, payload, extra = {}) {
  window.webkit?.messageHandlers?.reader?.postMessage({ event, payload, documentID, session, ...extra });
}
function readingIntent() { if (!restoring && !suspended) intentUntil = Date.now() + 1500; }
function clearIntent() { intentUntil = 0; pendingUserScroll = false; }
// Typesetting formulas dominates opening an article, so the last few stay ready to reuse.
// The source text is kept as the key so re-imported material is never served from the cache.
const typesetCache = new TypesetCache();
function typeset(payload) {
  const cached = typesetCache.get(payload.id, payload.content, payload.baseURL);
  if (cached) return cached;
  const result = renderMarkdown(payload.content, payload.baseURL);
  return typesetCache.put(payload.id, payload.content, payload.baseURL, result);
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
  const anchored = candidates.find(el => el.dataset.anchor === position.anchor);
  // Repeated headings/paragraphs are common in study notes. Their text alone cannot identify
  // where the reader stopped: first try the original source block together with its text.
  let block = anchored && (!position.excerpt || excerpt(anchored) === position.excerpt) ? anchored : null;
  if (!block && position.excerpt) {
    const matches = candidates.filter(el => excerpt(el) === position.excerpt);
    const line = Number(position.anchor?.match(/^line-(\d+)$/)?.[1]);
    const distance = el => Number.isFinite(line)
      ? Math.abs(Number(el.dataset.anchor?.slice(5)) - line)
      : Math.abs(scrollY + el.getBoundingClientRect().top - (position.progress || 0) * Math.max(0, document.documentElement.scrollHeight - innerHeight));
    block = matches.reduce((best, el) => !best || distance(el) < distance(best) ? el : best, null);
  }
  block ||= anchored;
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
function checkpoint(expectedSession, suspend = false, cachedOnly = false) {
  if (expectedSession && expectedSession !== session) return null;
  if (restoring && !suspend && !cachedOnly) return null;
  // SwiftUI may detach/resize the shared WebView after leaving a column. Such layout changes
  // are not reading activity and must not overwrite a valid position with a near-zero value.
  if (!restoring && !suspended && !cachedOnly && innerHeight > 1 && article.getBoundingClientRect().width > 1) {
    const position = capturePosition();
    if (position.anchor || position.excerpt) {
      if ((pendingUserScroll || Date.now() <= intentUntil) && JSON.stringify(position) !== JSON.stringify(lastPosition)) {
        lastActivity = { sequence: ++activitySequence, readAt: pendingUserScroll ? userScrollAt : Date.now(), position };
      }
      lastPosition = position;
    }
    pendingUserScroll = false;
  }
  if (suspend) { suspended = true; clearTimeout(saveTimer); }
  if (!lastPosition || !documentID) return null;
  post('position', lastPosition, { activity: lastActivity });
  lastCheckpoint = Date.now();
  return { documentID, session, position: lastPosition, activity: lastActivity };
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
    // Capture the outgoing document before replacing its DOM. Re-rendering the same article
    // can happen when returning from an empty folder; use the retained position in that case.
    checkpoint();
    const saved = !payload.preferSavedPosition && payload.id === documentID && lastPosition ? lastPosition : payload.position;
    const run = ++generation;
    ++preferencesGeneration;
    rendering = true;
    restoring = true;
    clearTimeout(saveTimer);
    clearIntent();
    lastActivity = null;
    activitySequence = 0;
    documentID = payload.id;
    session = payload.session || payload.id;
    suspended = false;
    lastPosition = saved || null;
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
      rendering = false;
      restoring = false;
      post('ready', true);
    } catch (error) {
      if (run !== generation) return;
      article.textContent = `无法排版，以下是原文：\n\n${payload.content}`;
      article.style.whiteSpace = 'pre-wrap';
      blocks = null;
      rendering = false;
      restoring = false;
      post('error', String(error));
    }
  },
  async preferences(prefs) {
    const run = generation, preferenceRun = ++preferencesGeneration;
    // The active render owns restoration until its initial layout has settled.
    if (rendering) {
      applyPreferences(prefs);
      for (const answer of article.querySelectorAll('details.answer')) answer.open = !prefs.foldAnswers;
      return;
    }
    checkpoint();
    const position = capturePosition();
    clearIntent();
    restoring = true;
    applyPreferences(prefs);
    for (const answer of article.querySelectorAll('details.answer')) answer.open = !prefs.foldAnswers;
    await settled();
    if (run !== generation || preferenceRun !== preferencesGeneration) return;
    restorePosition(position);
    await settled();
    if (run !== generation || preferenceRun !== preferencesGeneration) return;
    restoring = false;
  },
  scrollToHeading(id) {
    const target = document.getElementById(id);
    if (target) {
      readingIntent();
      target.closest('details')?.setAttribute('open', '');
      target.scrollIntoView({ behavior: 'auto', block: 'start' });
      checkpoint();
    }
  },
  navigationFinished() { readingIntent(); checkpoint(); },
  save(expectedSession, suspend = false, cachedOnly = false) {
    return checkpoint(expectedSession, suspend, cachedOnly);
  },
  resume(expectedSession) { if (expectedSession === session) { suspended = false; clearIntent(); } },
};
for (const event of ['wheel', 'touchstart', 'touchmove', 'pointerdown']) addEventListener(event, readingIntent, { passive: true });
addEventListener('keydown', event => {
  if (!event.target?.closest?.('input,textarea,[contenteditable]') && ['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End', ' '].includes(event.key)) readingIntent();
});
addEventListener('resize', clearIntent);
addEventListener('scroll', () => {
  clearTimeout(saveTimer);
  if (!restoring && !suspended) {
    if (Date.now() <= intentUntil) {
      pendingUserScroll = true;
      userScrollAt = Date.now();
      intentUntil = userScrollAt + 500; // retain touch/trackpad momentum until scrolling stops
    }
    // Keep a recent checkpoint even during continuous scrolling, with bounded UI updates.
    if (Date.now() - lastCheckpoint >= 200) checkpoint();
    saveTimer = setTimeout(() => checkpoint(), 250);
  }
}, { passive: true });
addEventListener('pagehide', () => checkpoint(undefined, true, true));
document.addEventListener('visibilitychange', () => { if (document.hidden) checkpoint(undefined, false, true); });
document.addEventListener('click', event => {
  const math = event.target.closest?.('.katex');
  if (!math) return;
  const source = math.querySelector('annotation[encoding="application/x-tex"]')?.textContent;
  if (source) post('formula', source);
});
