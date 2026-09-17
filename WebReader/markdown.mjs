import MarkdownIt from 'markdown-it';
import { katex } from '@mdit/plugin-katex';

export function stripFrontMatter(source) {
  return source.replace(/^\uFEFF/, '').replace(/^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)\s*(?:\r?\n|$)/, '');
}

export function localImageURL(source, baseURL) {
  try {
    const base = new URL(baseURL);
    const url = new URL(source, base);
    if (url.protocol !== 'reader:' || url.hostname !== 'library') return '';
    if (url.pathname.split('/')[1] !== base.pathname.split('/')[1]) return '';
    return url.href;
  } catch { return ''; }
}

/// The path an attachment has inside its collection, as the app's size table keys it. Comparing
/// decoded, precomposed text keeps a Chinese file name matching whatever the file system stored.
export function attachmentPath(href) {
  try {
    const url = new URL(href);
    if (url.protocol !== 'reader:' || url.hostname !== 'library') return '';
    return url.pathname.split('/').filter(part => part !== '').slice(1)
      .map(decodeURIComponent).join('/').normalize('NFC');
  } catch { return ''; }
}

let renderer, currentBaseURL = '', currentImageSizes = {};

/// Building the parser and the formula plugin costs more than parsing a short article, so one
/// instance serves every article. The base URL is swapped per call because rendering is synchronous.
function markdown() {
  if (renderer) return renderer;
  const md = new MarkdownIt({ html: false, linkify: false, typographer: false });
  md.use(katex, { delimiters: 'all', mathFence: true, trust: false, throwOnError: false,
    maxExpand: 500, maxSize: 30, output: 'htmlAndMathml' });
  const originalImage = md.renderer.rules.image;
  md.renderer.rules.image = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    const href = localImageURL(token.attrGet('src'), currentBaseURL);
    token.attrSet('src', href);
    token.attrSet('loading', 'eager');
    token.attrSet('decoding', 'async');
    // Stating the pixel size reserves the box before the file decodes, so the article does not
    // jump while reading and a saved position needs no wait. An unknown file simply gets no size.
    const size = currentImageSizes[attachmentPath(href)];
    if (Array.isArray(size) && size.length === 2 && size[0] > 0 && size[1] > 0) {
      token.attrSet('width', String(Math.round(size[0])));
      token.attrSet('height', String(Math.round(size[1])));
    }
    return originalImage(tokens, idx, options, env, self);
  };
  renderer = md;
  return md;
}

export function renderMarkdown(source, baseURL = 'reader://library/sample/document.md', imageSizes = {}) {
  const md = markdown();
  currentBaseURL = baseURL;
  currentImageSizes = imageSizes || {};
  const tokens = md.parse(stripFrontMatter(source), {});
  const outline = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (token.map && token.level === 0 && token.nesting === 1) {
      token.attrSet('data-anchor', `line-${token.map[0]}`);
      token.attrJoin('class', 'reading-block');
    }
    if (token.type === 'heading_open') {
      const inline = tokens[i + 1];
      const title = (inline.children ?? []).map(t => t.nesting === 0 ? t.content : '').join('');
      const id = `heading-${outline.length}`;
      token.attrSet('id', id);
      outline.push({ id, title, level: Number(token.tag.slice(1)) });
    }
  }
  try {
    return { html: md.renderer.render(tokens, md.options, {}), outline };
  } finally {
    // Rendering tokens directly bypasses the plugin's own reset, so macros defined by one
    // article must not carry over into the next.
    md.renderInline('');
  }
}

export function foldAnswers(root, enabled) {
  const headings = [...root.querySelectorAll('h2,h3,h4,h5,h6')];
  for (const heading of headings) {
    if (!/^(?:答案|解答|解析|参考答案|参考解答|解法[一二三四五\d]*)(?:\s*[:：].*)?$/.test(heading.textContent.trim())) continue;
    const level = Number(heading.tagName.slice(1));
    const details = root.ownerDocument.createElement('details');
    details.className = 'answer';
    details.open = !enabled;
    const summary = root.ownerDocument.createElement('summary');
    summary.textContent = heading.textContent;
    summary.id = heading.id;
    if (heading.dataset.anchor) {
      details.dataset.anchor = heading.dataset.anchor;
      details.classList.add('reading-block');
    }
    heading.before(details);
    details.append(summary);
    let next = heading.nextElementSibling;
    while (next && !( /^H[1-6]$/.test(next.tagName) && Number(next.tagName.slice(1)) <= level)) {
      const item = next;
      next = item.nextElementSibling;
      details.append(item);
    }
    heading.remove();
  }
}
