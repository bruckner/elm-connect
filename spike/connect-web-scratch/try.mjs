// The adapter against the notes server: node try.mjs http://127.0.0.1:18080
import { createStreams } from "./adapter.js";
const baseUrl = process.argv[2];
for (const req of [{ count: 2, intervalMs: 10 }, { count: 2, intervalMs: 10, fail: true }]) {
  await new Promise((resolve) => {
    const s = createStreams((e) => {
      console.log(JSON.stringify(e));
      if (e.kind === "end") resolve();
    }, { baseUrl });
    s.open("w", { service: "notes.v1.NotesService", method: "WatchNotes", body: JSON.stringify(req) });
  });
}
