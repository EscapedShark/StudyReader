import test from 'node:test';
import assert from 'node:assert/strict';
import { TypesetCache } from '../WebReader/typeset-cache.mjs';

const result = html => ({html,outline:[]});
test('oversized typesetting is returned without exceeding the budget or evicting useful entries', () => {
  const cache = new TypesetCache({maxBytes:200,maxEntries:2});
  cache.put('small','source','reader://a',result('short'));
  const before = cache.bytes;
  const large = cache.put('large','a','reader://a',result('x'.repeat(10000)));
  assert.equal(large.html.length,10000);
  assert.equal(cache.bytes,before);
  assert.equal(cache.get('large','a','reader://a'),null);
  assert.ok(cache.get('small','source','reader://a'));
});
test('cache counts source and outline, respects LRU and rejects changed image bases', () => {
  const cache = new TypesetCache({maxBytes:500,maxEntries:2});
  cache.put('a','s','base',result('a'));
  cache.put('b','s','base',result('b'));
  assert.ok(cache.get('a','s','base'));
  cache.put('c','s','base',result('c'));
  assert.equal(cache.get('b','s','base'),null);
  assert.equal(cache.get('a','s','different'),null);
  cache.put('a','x'.repeat(1000),'base',result('a'));
  assert.equal(cache.get('a','x'.repeat(1000),'base'),null);
  cache.put('outline','s','base',{html:'x',outline:[{title:'x'.repeat(1000)}]});
  assert.equal(cache.get('outline','s','base'),null);
  assert.ok(cache.bytes<=500);
  assert.equal(cache.entries.size,1);
});
test('a changed attachment size table is not served from the cache', () => {
  const cache = new TypesetCache();
  cache.put('a', 's', 'base', result('narrow'), 'fig.png:800,600');
  assert.equal(cache.get('a', 's', 'base', 'fig.png:1600,900'), null);
  assert.equal(cache.get('a', 's', 'base'), null);
  assert.equal(cache.get('a', 's', 'base', 'fig.png:800,600').html, 'narrow');
});
