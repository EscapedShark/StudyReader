// Conservative UTF-16 payload estimate; browser object/DOM overhead is separate.
export class TypesetCache {
  constructor({ maxBytes = 8 * 1024 * 1024, maxEntries = 12 } = {}) {
    this.maxBytes = maxBytes;
    this.maxEntries = maxEntries;
    this.entries = new Map();
    this.bytes = 0;
  }
  get(id, content, baseURL, attachments = '') {
    const entry = this.entries.get(id);
    if (!entry || entry.content !== content || entry.baseURL !== baseURL || entry.attachments !== attachments) return null;
    this.entries.delete(id);
    this.entries.set(id, entry);
    return entry;
  }
  put(id, content, baseURL, result, attachments = '') {
    const previous = this.entries.get(id);
    if (previous) { this.bytes -= previous.cost; this.entries.delete(id); }
    const cost = 2 * (content.length + baseURL.length + attachments.length + result.html.length + JSON.stringify(result.outline).length);
    const entry = { content, baseURL, attachments, html: result.html, outline: result.outline, cost };
    // A single oversized article must not defeat the total budget or evict useful small entries.
    if (cost > this.maxBytes || this.maxEntries < 1) return entry;
    while (this.entries.size && (this.bytes + cost > this.maxBytes || this.entries.size >= this.maxEntries)) {
      const oldest = this.entries.keys().next().value;
      this.bytes -= this.entries.get(oldest).cost;
      this.entries.delete(oldest);
    }
    this.entries.set(id, entry);
    this.bytes += cost;
    return entry;
  }
}
