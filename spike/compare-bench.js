// Time elm-connect's and elm-protocol-buffers' generated codecs of the
// reduced codec corpus, compiled together into spike/compare-harness's Bench3
// worker, by codec-bench2.js's method: per input group, each side's app runs
// each mode REPEATS times and the median time per input is printed, ours
// first, then theirs. JSON times include JSON.parse/stringify; binary times
// start and end at `Bytes`. Also prints the bytes each side's encoder writes
// for the same inputs. One process, one program at a time.
//
//   node spike/compare-bench.js BENCH3.js [ROUNDS] [REPEATS]
import { readFileSync } from 'node:fs';
import { gzipSync } from 'node:zlib';

const [benchPath, roundsArg, repeatsArg] = process.argv.slice(2);
const rounds = Number(roundsArg ?? 50);
const repeats = Number(repeatsArg ?? 11);

const scope = {};
new Function(readFileSync(benchPath, 'utf8')).call(scope);
const Bench = scope.Elm.Bench3;

async function start(side, message, large) {
  const app = Bench.init({ flags: { side, message, large } });
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
    async run(mode, r) {
      await new Promise((resolve) => setImmediate(resolve));
      out = null;
      const answered = new Promise((resolve) => { resolveRun = resolve; });
      const t0 = performance.now();
      app.ports.go.send({ mode, rounds: r });
      if (out === null) await answered;
      resolveRun = null;
      if (out === -1) throw new Error(`${mode}: unknown mode`);
      return { ms: t1 - t0, out };
    },
  };
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

async function time(app, mode, r, count) {
  await app.run(mode, 2);
  const times = [];
  let out;
  for (let i = 0; i < repeats; i++) {
    const res = await app.run(mode, r);
    times.push(res.ms);
    out = res.out;
  }
  return { perInput: (1000 * median(times)) / (r * count), out };
}

// codec-bench2.js's 1,000 leaves, with Repeated's other repeated fields
// written as [] (protoc-gen-elm 4.0.4's JSON decoders need every repeated
// field present); the binary is the same.
const large = JSON.stringify({
  doubles: [], floats: [], int32s: [], int64s: [], uint64s: [], fixed32s: [],
  bools: [], strings: [], bytes: [], kinds: [],
  leaves: Array.from({ length: 1000 }, (_, i) => ({ name: `leaf-${i}`, count: i * 7 })),
});
const wire = (hexes) => {
  const bufs = hexes.map((h) => Buffer.from(h, 'hex'));
  return `${bufs.reduce((n, b) => n + b.length, 0)}/${bufs.reduce((n, b) => n + gzipSync(b).length, 0)}`;
};

async function side(name, label, message, largeInput, r) {
  const app = await start(name, message, largeInput);
  const n = (await app.run('wire', 0)).out.length;
  const nj = (await app.run('wireJson', 0)).out.length;
  const dj = nj ? await time(app, 'decodeJson', r, nj) : { perInput: NaN, out: 0 };
  const db = await time(app, 'decodeBinary', r, n);
  const ej = nj ? await time(app, 'encodeJson', r, nj) : { perInput: NaN };
  const eb = await time(app, 'encodeBinary', r, n);
  if (dj.out !== nj * r || db.out !== n * r) throw new Error(`${name} ${label}: decoded ${dj.out}/${db.out} of ${nj * r}/${n * r}`);
  const written = wire((await app.run('encodedWire', 0)).out);
  return { n, nj, dj: dj.perInput, db: db.perInput, ej: ej.perInput, eb: eb.perInput, written };
}

const f = (x) => x.toFixed(2);
console.log(`rounds ${rounds}, repeats ${repeats}, node ${process.version}`);
console.log('| inputs | n (JSON n) | binary decode µs ours / theirs | binary encode µs ours / theirs | JSON decode µs ours / theirs | JSON encode µs ours / theirs | binary written raw/gz B ours / theirs |');
console.log('|---|---:|---:|---:|---:|---:|---:|');
const messages = ['*', 'codec.v1.Scalars', 'codec.v1.Optionals', 'codec.v1.Repeated', 'codec.v1.Maps', 'codec.v1.Choice', 'codec.v1.Names', 'codec.v1.Outer', 'codec.v1.Tree', 'codec.v1.WellKnown', 'codec.v1.Wrappers', 'codec.v1.Across', 'codec.v1.Leaf', 'codec.v1.Everything'];
const rows = messages.map((m) => [m === '*' ? 'corpus, all' : m, m, '', rounds]);
rows.push(['Repeated, 1,000 leaves', '*', large, Math.max(1, Math.floor(rounds / 10))]);
for (const [label, message, largeInput, r] of rows) {
  const o = await side('ours', label, message, largeInput, r);
  const t = await side('epb', label, message, largeInput, r);
  console.log(`| ${label} | ${o.n} (${o.nj}) | ${f(o.db)} / ${f(t.db)} | ${f(o.eb)} / ${f(t.eb)} | ${f(o.dj)} / ${f(t.dj)} | ${f(o.ej)} / ${f(t.ej)} | ${o.written} / ${t.written} |`);
}
