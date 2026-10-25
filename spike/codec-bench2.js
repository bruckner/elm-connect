// Time the JSON and binary codecs compiled into spike/codec-harness's Bench2
// worker, and measure the wire bytes of both forms of each input.
//
//   node spike/codec-bench2.js BENCH2.js [ROUNDS] [REPEATS]
//
// For the corpus (every canonical sample of Generated.Codec.Data, all
// messages together and each alone) and one codec.v1.Repeated of 1,000
// leaves, it runs each mode REPEATS times and prints the median time per
// input. The inputs are prepared in `init`, untimed; the time is around the
// `go` port's send, inside which the worker's update runs the rounds. JSON
// times include JSON.parse/stringify (elm/json rides on them); binary times
// start from `Bytes` (elm/http hands an answer over as `new DataView(buffer)`,
// timed alone below) and end at `Bytes` (XHR sends the DataView as it is).
// One process, one program at a time.
import { readFileSync } from 'node:fs';
import { gzipSync } from 'node:zlib';

const [benchPath, roundsArg, repeatsArg] = process.argv.slice(2);
const rounds = Number(roundsArg ?? 50);
const repeats = Number(repeatsArg ?? 11);

const scope = {};
new Function(readFileSync(benchPath, 'utf8')).call(scope);
const Bench = scope.Elm.Bench2;

async function start(message, large) {
  const app = Bench.init({ flags: { message, large } });
  // The worker's subscriptions are in place after the first tick.
  await new Promise((resolve) => setTimeout(resolve, 0));
  let out = null;
  let t1 = 0;
  let resolveRun = null;
  const finish = (x) => {
    t1 = performance.now();
    out = x;
    if (resolveRun) resolveRun();
  };
  app.ports.done.subscribe(finish);
  app.ports.texts.subscribe(finish);
  return {
    // The answer comes inside the send when the worker is idle; the time is
    // taken in the port's callback whichever way it comes.
    async run(mode, r) {
      await new Promise((resolve) => setImmediate(resolve));
      out = null;
      const answered = new Promise((resolve) => { resolveRun = resolve; });
      const t0 = performance.now();
      app.ports.go.send({ mode, rounds: r });
      if (out === null) {
        deferred++;
        await answered;
      }
      resolveRun = null;
      if (out === -1) throw new Error(`${mode}: unknown mode`);
      return { ms: t1 - t0, out };
    },
  };
}

let deferred = 0;
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

async function time(app, mode, r, count) {
  await app.run(mode, 2); // warm up
  const times = [];
  let out;
  for (let i = 0; i < repeats; i++) {
    const res = await app.run(mode, r);
    times.push(res.ms);
    out = res.out;
  }
  return { perInput: (1000 * median(times)) / (r * count), out };
}

const large = JSON.stringify({
  leaves: Array.from({ length: 1000 }, (_, i) => ({ name: `leaf-${i}`, count: i * 7 })),
});

const sizes = (bufs) => ({
  raw: bufs.reduce((n, b) => n + b.length, 0),
  gzip: bufs.reduce((n, b) => n + gzipSync(b).length, 0),
});

console.log(`rounds ${rounds}, repeats ${repeats}, node ${process.version}`);
console.log('| inputs | n | JSON decode µs | binary decode µs | ratio | JSON encode µs | binary encode µs | ratio | JSON raw/gz B | binary raw/gz B |');
console.log('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|');

async function row(label, message, largeInput, r) {
  const app = await start(message, largeInput);
  const bins = (await app.run('wire', 0)).out.map((h) => Buffer.from(h, 'hex'));
  const jsons = largeInput ? [largeInput] : null;
  const n = bins.length;
  const dj = await time(app, 'decodeJson', r, n);
  const db = await time(app, 'decodeBinary', r, n);
  const ej = await time(app, 'encodeJson', r, n);
  const eb = await time(app, 'encodeBinary', r, n);
  if (dj.out !== n * r || db.out !== n * r) throw new Error(`${label}: decoded ${dj.out}/${db.out} of ${n * r}`);
  const jw = jsons ? sizes(jsons.map((t) => Buffer.from(t))) : null;
  const bw = sizes(bins);
  return { label, n, dj, db, ej, eb, jw, bw, app, bins };
}

const data = JSON.parse(process.env.SAMPLES_JSON ?? 'null');
const fmt = (x) => x.toFixed(2);
function print(r, jw) {
  console.log(
    `| ${r.label} | ${r.n} | ${fmt(r.dj.perInput)} | ${fmt(r.db.perInput)} | ${fmt(r.db.perInput / r.dj.perInput)} | ${fmt(r.ej.perInput)} | ${fmt(r.eb.perInput)} | ${fmt(r.eb.perInput / r.ej.perInput)} | ${jw ? `${jw.raw}/${jw.gzip}` : 'n/a'} | ${r.bw.raw}/${r.bw.gzip} |`,
  );
}

const messages = ['*', 'codec.v1.Scalars', 'codec.v1.Optionals', 'codec.v1.Repeated', 'codec.v1.Maps', 'codec.v1.Choice', 'codec.v1.Names', 'codec.v1.Outer', 'codec.v1.Tree', 'codec.v1.WellKnown', 'codec.v1.Wrappers', 'codec.v1.Across', 'codec.v1.Leaf', 'codec.v1.Everything'];
const samples = data ?? {};
for (const m of messages) {
  const r = await row(m === '*' ? 'corpus, all' : m, m, '', rounds);
  print(r, samples[m] ? sizes(samples[m].map((t) => Buffer.from(t))) : null);
}
const big = await row('Repeated, 1,000 leaves', '*', large, Math.max(1, Math.floor(rounds / 10)));
print(big, big.jw);

// The experiments, on the 1,000-leaf input.
const rr = Math.max(1, Math.floor(rounds / 10));
const ex = async (mode) => (await time(big.app, mode, rr, 1)).perInput;
console.log('\nexperiments on the 1,000-leaf input (µs per input):');
console.log(`  encode, generated (delimited copies each leaf): ${fmt(await ex('encodeBinary'))}`);
console.log(`  encode, size function per leaf (no copy):       ${fmt(await ex('encodeSized'))}`);
console.log(`  decode, leaves field, codec built per read:     ${fmt(await ex('decodeInline'))}`);
console.log(`  decode, leaves field, one top-level codec:      ${fmt(await ex('decodeHoisted'))}`);

// The handoff elm/http makes of an arraybuffer answer.
const buf = big.bins[0].buffer.slice(big.bins[0].byteOffset, big.bins[0].byteOffset + big.bins[0].length);
const N = 1e6;
let t0 = performance.now();
let keep = 0;
for (let i = 0; i < N; i++) keep += new DataView(buf).byteLength;
let t1 = performance.now();
console.log(`\nArrayBuffer -> DataView handoff: ${fmt((1000 * (t1 - t0)) / N)} µs (${keep > 0})`);
console.log(`answers that came after the send returned: ${deferred}`);
