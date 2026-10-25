// Time the codecs compiled into spike/codec-harness's Bench worker, and
// measure the wire bytes of their inputs.
//
//   node spike/codec-bench.js BENCH.js [ROUNDS] [REPEATS]
//
// For the corpus (every canonical sample of Generated.Codec.Data, all
// messages together and each message alone) and for one codec.v1.Repeated
// of 1,000 leaves, it runs `decode` and `encode` REPEATS times each and
// prints the median time per input. `init` does the work, so the time
// around it is the work's. One process, one program at a time.
import { readFileSync } from 'node:fs';
import { gzipSync } from 'node:zlib';

const [benchPath, roundsArg, repeatsArg] = process.argv.slice(2);
const rounds = Number(roundsArg ?? 50);
const repeats = Number(repeatsArg ?? 11);

const scope = {};
new Function(readFileSync(benchPath, 'utf8')).call(scope);
const Bench = scope.Elm.Bench;

function init(flags) {
  let out = null;
  const t0 = performance.now();
  const app = Bench.init({ flags });
  const t1 = performance.now();
  if (app.ports.done) app.ports.done.subscribe((n) => { out = n; });
  if (app.ports.texts) app.ports.texts.subscribe((xs) => { out = xs; });
  return { ms: t1 - t0, get out() { return out; } };
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

function time(flags, count) {
  init({ ...flags, rounds: 2 }); // warm up
  const times = [];
  for (let i = 0; i < repeats; i++) times.push(init(flags).ms);
  const m = median(times);
  return { median: m, perInput: (1000 * m) / (flags.rounds * count) };
}

function dump(message, large) {
  return new Promise((resolve) => {
    const r = init({ mode: 'dump', message, rounds: 0, large });
    setTimeout(() => resolve(r.out), 0);
  });
}

const large = JSON.stringify({
  leaves: Array.from({ length: 1000 }, (_, i) => ({ name: `leaf-${i}`, count: i * 7 })),
});

const all = await dump('*', '');
const messages = [...new Set(all.map(([m]) => m))];
const wire = (texts) => ({
  raw: texts.reduce((n, t) => n + Buffer.byteLength(t), 0),
  gzip: texts.reduce((n, t) => n + gzipSync(t).length, 0),
});

console.log(`rounds ${rounds}, repeats ${repeats}, node ${process.version}`);
console.log('| inputs | count | decode us/input | encode us/input | raw bytes | gzip bytes (each) |');
console.log('|---|---:|---:|---:|---:|---:|');
const row = (label, flags, texts) => {
  const n = texts.length;
  const d = time({ ...flags, mode: 'decode' }, n);
  const e = time({ ...flags, mode: 'encode' }, n);
  const w = wire(texts);
  console.log(`| ${label} | ${n} | ${d.perInput.toFixed(2)} | ${e.perInput.toFixed(2)} | ${w.raw} | ${w.gzip} |`);
};
row('corpus, all', { message: '*', rounds, large: '' }, all.map(([, t]) => t));
for (const m of messages) {
  row(m, { message: m, rounds, large: '' }, all.filter(([x]) => x === m).map(([, t]) => t));
}
row('Repeated, 1,000 leaves', { message: '*', rounds: Math.max(1, Math.floor(rounds / 10)), large }, [large]);
