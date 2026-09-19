import hljs from 'highlight.js/lib/common';

// Guess only common code languages; prose, logs and configuration can otherwise win
// against real code. Explicit fence labels still support every bundled language/alias.
const autoLanguages = ['python', 'javascript', 'typescript', 'swift', 'c', 'cpp', 'java', 'bash', 'json', 'sql', 'xml', 'css'];
const plainLanguages = new Set(['text', 'txt', 'plaintext', 'plain', 'none', 'nohighlight', 'no-highlight']);

export function highlightCode(source, language = '') {
  const name = language.trim().toLowerCase();
  // Large pasted files remain readable without running multiple grammars on the UI thread.
  if (!source.trim() || source.length > 64_000 || plainLanguages.has(name)) return '';
  try {
    if (name) {
      if (!hljs.getLanguage(name)) return '';
      return hljs.highlight(source, { language: name, ignoreIllegals: true }).value;
    }
    if (source.length > 8_000) return '';
    const result = hljs.highlightAuto(source, autoLanguages);
    return result.language && result.relevance >= 3 ? result.value : '';
  } catch {
    // An empty result tells MarkdownIt to escape and display the original code.
    return '';
  }
}
