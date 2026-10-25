// Print the corpus' canonical JSON texts by message, as JSON, for
// codec-bench2.js's wire sizes (SAMPLES_JSON).
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[2], 'utf8');
const out = { '*': [] };
const re = /\{ name = "[^"]*"\n\s*, message = "([^"]+)"\n\s*, canonical = ("(?:[^"\\]|\\.)*")/g;
for (const m of src.matchAll(re)) {
  const text = JSON.parse(m[2].replace(/\\u\{([0-9A-Fa-f]+)\}/g, (_, h) => '\\u' + h.padStart(4, '0')));
  (out[m[1]] ??= []).push(text);
  out['*'].push(text);
}
console.log(JSON.stringify(out));
