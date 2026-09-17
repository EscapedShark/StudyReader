import { renderMarkdown, foldAnswers } from './markdown.mjs';
import { TypesetCache } from './typeset-cache.mjs';

const article = document.querySelector('article');
let documentID = '', restoring = false, saveTimer, generation = 0;
let preferencesGeneration = 0;
let rendering = false;
let suspended = true, session = '', lastPosition = null, lastCheckpoint = 0;
let lastActivity = null, activitySequence = 0, intentUntil = 0, pendingUserScroll = false, userScrollAt = 0;
let lastPosted = null, postedActivity = null;
let blocks = null, blockCursor = 0, excerpts = new WeakMap();
function post(event, payload, extra = {}) {
  window.webkit?.messageHandlers?.reader?.postMessage({ event, payload, documentID, session, ...extra });
}
function readingIntent() { if (!restoring && !suspended) intentUntil = Date.now() + 1500; }
function clearIntent() { intentUntil = 0; pendingUserScroll = false; }
// Typesetting formulas dominates opening an article, so the last few stay ready to reuse.
// The source text is kept as the key so re-imported material is never served from the cache.
const typesetCache = new TypesetCache();
function typeset(payload) {
  const sizes = payload.imageSizes || {};
  // A stable signature: the app hands the table over as a plain object with no promised order.
  const attachments = Object.keys(sizes).sort().map(name => `${name}:${sizes[name]}`).join('|');
  const cached = typesetCache.get(payload.id, payload.content, payload.baseURL, attachments);
  if (cached) return cached;
  const result = renderMarkdown(payload.content, payload.baseURL, sizes);
  return typesetCache.put(payload.id, payload.content, payload.baseURL, result, attachments);
}
/// Scrolling asks for these several times a second, so the list is collected once per article.
function readingBlocks() {
  if (!blocks) blocks = [...article.querySelectorAll('.reading-block')];
  return blocks;
}
/// Anything that changes the blocks or their text drops the measurement shortcuts with them.
function invalidateBlocks() { blocks = null; blockCursor = 0; excerpts = new WeakMap(); }
/// Only the first 100 characters are ever kept, so a long table is not flattened on every save.
/// The text of a block never changes while it is on screen, so each walk is made once.
function excerpt(element) {
  const cached = excerpts.get(element);
  if (cached !== undefined) return cached;
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let text = '';
  while (text.trim().length < 100) {
    const node = walker.nextNode();
    if (!node) break;
    text += node.nodeValue;
  }
  const result = text.trim().slice(0, 100);
  excerpts.set(element, result);
  return result;
}
const READING_LINE = 60;
function laidOutRect(element) {
  const rect = element.getBoundingClientRect();
  return rect.width === 0 && rect.height === 0 ? null : rect; // inside a collapsed answer
}
/// Blocks run down the page in order, so the one at the reading line is found by walking from the
/// previous answer. Measuring the whole article on every scroll tick delayed the frame WebKit was
/// about to paint, and a long article has thousands of blocks above the viewport.
function blockAtReadingLine() {
  const list = readingBlocks();
  if (!list.length) return null;
  const seek = (index, step) => {
    for (let i = index + step; i >= 0 && i < list.length; i += step) {
      const rect = laidOutRect(list[i]);
      if (rect) return { index: i, element: list[i], rect };
    }
    return null;
  };
  const start = Math.min(blockCursor, list.length - 1);
  const rect = laidOutRect(list[start]);
  const from = rect ? { index: start, element: list[start], rect } : seek(start, 1) ?? seek(start, -1);
  if (!from) return null;
  let above = null, below = null;
  if (from.rect.top <= READING_LINE) {
    above = from;
    for (let next = seek(above.index, 1); next; next = seek(above.index, 1)) {
      if (next.rect.top > READING_LINE) { below = next; break; }
      above = next;
    }
  } else {
    below = from;
    for (let previous = seek(below.index, -1); previous; previous = seek(below.index, -1)) {
      if (previous.rect.top <= READING_LINE) { above = previous; break; }
      below = previous;
    }
  }
  // An exact tie keeps the earlier block, the way a scan from the top of the article did.
  const best = !above ? below : !below ? above
    : Math.abs(above.rect.top - READING_LINE) <= Math.abs(below.rect.top - READING_LINE) ? above : below;
  blockCursor = best.index;
  return best;
}
export function capturePosition() {
  const found = blockAtReadingLine();
  if (!found) return { anchor: '', excerpt: '', offset: 0, progress: 0 };
  return {
    anchor: found.element.dataset.anchor || '',
    excerpt: excerpt(found.element),
    offset: -found.rect.top / Math.max(found.rect.height, 1),
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
function samePosition(a, b) {
  return !!a && !!b && a.anchor === b.anchor && a.excerpt === b.excerpt && a.offset === b.offset && a.progress === b.progress;
}
function checkpoint(expectedSession, suspend = false, cachedOnly = false) {
  if (expectedSession && expectedSession !== session) return null;
  if (restoring && !suspend && !cachedOnly) return null;
  // SwiftUI may detach/resize the shared WebView after leaving a column. Such layout changes
  // are not reading activity and must not overwrite a valid position with a near-zero value.
  if (!restoring && !suspended && !cachedOnly && innerHeight > 1 && article.getBoundingClientRect().width > 1) {
    const position = capturePosition();
    if (position.anchor || position.excerpt) {
      if ((pendingUserScroll || Date.now() <= intentUntil) && !samePosition(position, lastPosition)) {
        lastActivity = { sequence: ++activitySequence, readAt: pendingUserScroll ? userScrollAt : Date.now(), position };
      }
      lastPosition = position;
    }
    pendingUserScroll = false;
  }
  if (suspend) { suspended = true; clearTimeout(saveTimer); }
  if (!lastPosition || !documentID) return null;
  // Standing still still checkpoints, and the app already holds that position: skip the message.
  if (!samePosition(lastPosition, lastPosted) || lastActivity !== postedActivity) {
    post('position', lastPosition, { activity: lastActivity });
    lastPosted = lastPosition;
    postedActivity = lastActivity;
  }
  lastCheckpoint = Date.now();
  return { documentID, session, position: lastPosition, activity: lastActivity };
}
function applyPreferences(prefs) {
  document.documentElement.style.setProperty('--reading-size', `${prefs.fontSize || 18}px`);
  document.documentElement.dataset.theme = prefs.theme || 'system';
}
/// Formulas keep their MathML rendered only while a screen reader is running; see reader.css.
function applyAssistive(active) {
  document.documentElement.toggleAttribute('data-assistive', !!active);
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
    lastPosted = null;
    postedActivity = null;
    documentID = payload.id;
    session = payload.session || payload.id;
    suspended = false;
    lastPosition = saved || null;
    applyPreferences(payload.preferences);
    applyAssistive(payload.assistive);
    try {
      const result = typeset(payload);
      article.style.whiteSpace = '';
      article.innerHTML = result.html;
      foldAnswers(article, payload.preferences.foldAnswers);
      invalidateBlocks();
      const images = [...article.querySelectorAll('img')];
      for (const img of images) {
        img.addEventListener('error', () => {
          const hint = document.createElement('span');
          hint.className = 'image-missing';
          hint.textContent = `图片未导入：${img.alt || '请连同图片所在文件夹一起导入'}`;
          img.replaceWith(hint);
          invalidateBlocks();
        }, { once: true });
      }
      post('outline', result.outline);
      // An attachment whose pixel size the app already knows holds its own box, so the page height
      // no longer changes when it decodes. A file that is missing has no size and still waits,
      // because its placeholder is a different height.
      const reserved = images.every(img => img.hasAttribute('width') && img.hasAttribute('height'));
      if (saved && (saved.excerpt || saved.anchor || saved.progress > 0)) {
        // Landing on the saved spot needs a stable page height, so wait for unmeasured attachments.
        if (!reserved) {
          await Promise.race([
            Promise.all(images.map(img => img.complete ? Promise.resolve() :
              new Promise(resolve => { img.addEventListener('load', resolve, { once: true }); img.addEventListener('error', resolve, { once: true }); }))),
            new Promise(resolve => setTimeout(resolve, 1500))
          ]);
        }
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
      invalidateBlocks();
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
  assistive(active) { applyAssistive(active); },
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
