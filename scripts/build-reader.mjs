import { build } from 'esbuild';
import { mkdir, cp, copyFile, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const output = new URL('../StudyReader/Resources/Reader/', import.meta.url);
await mkdir(output, { recursive:true });
await build({ entryPoints:['WebReader/reader.mjs'], outfile:fileURLToPath(new URL('reader.js', output)),
  bundle:true, minify:true, format:'iife', target:['safari17'], legalComments:'linked' });
for (const file of ['index.html','reader.css']) await copyFile(`WebReader/${file}`, new URL(file, output));
await copyFile('node_modules/katex/dist/katex.min.css', new URL('katex.min.css', output));
await cp('node_modules/katex/dist/fonts', new URL('fonts', output), { recursive:true });
const licenseFiles = [
  ['markdown-it','node_modules/markdown-it/LICENSE'],
  ['KaTeX','node_modules/katex/LICENSE'],
  ['KaTeX fonts','WebReader/licenses/KaTeX-fonts.txt'],
  ['@mdit/plugin-katex','node_modules/@mdit/plugin-katex/LICENSE'],
  ['@mdit/plugin-tex','node_modules/@mdit/plugin-tex/LICENSE'],
  ['@mdit/helper','node_modules/@mdit/helper/LICENSE'],
  ['entities','node_modules/entities/LICENSE'],
  ['mdurl','node_modules/mdurl/LICENSE'],
  ['uc.micro','node_modules/uc.micro/LICENSE.txt'],
  ['linkify-it','node_modules/linkify-it/LICENSE'],
  ['punycode.js','node_modules/punycode.js/LICENSE-MIT.txt'],
];
const notices=[];
for (const [name,path] of licenseFiles) {
  notices.push(`${name}\n${'='.repeat(name.length)}\n${await readFile(path,'utf8')}`);
}
await writeFile(new URL('THIRD_PARTY_NOTICES.txt',output), notices.join('\n\n'));
console.log('Built offline reader resources.');
