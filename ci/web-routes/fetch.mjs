// Drives fespalier_dio's browser harness (packages/fespalier_dio/test/browser/harness.dart) in
// Chromium, Firefox and WebKit, for each build, and fails unless every case passed.
//
//   node fetch.mjs <ports.json> [engine ...]
//
// <ports.json> is what packages/fespalier_dio/tool/stream_server.dart wrote (`page`, `api`,
// `dead`); the server serves the dart2js build under /js/ and the dart2wasm one under /wasm/.
// BUILDS (default `js,wasm`) picks the builds. The browsers are the builds Playwright's pinned
// version installs (ci/web-routes/package-lock.json). Every request that is not to this machine is
// aborted. `just fetch-adapter` (scripts/check-fetch-adapter.sh) runs it; CI's `fetch-adapter`
// job too.
//
// Exit codes: 0 every case passed in every engine and build, 1 one failed, 2 usage.
import { readFileSync } from 'node:fs';
import { chromium, firefox, webkit } from 'playwright';

const [portsFile, ...named] = process.argv.slice(2);
if (!portsFile) {
  console.error('usage: node fetch.mjs <ports.json> [chromium|firefox|webkit ...]');
  process.exit(2);
}
const ports = JSON.parse(readFileSync(portsFile, 'utf8'));
const all = { chromium, firefox, webkit };
const engines = named.length ? named : Object.keys(all);
for (const engine of engines) {
  if (!all[engine]) {
    console.error(`unknown engine ${engine}`);
    process.exit(2);
  }
}
const builds = (process.env.BUILDS || 'js,wasm').split(',');
const page = `http://127.0.0.1:${ports.page}`;
const api = `http://127.0.0.1:${ports.api}`;
// The harness takes about 15 s; this is what one page may take.
const PAGE_TIMEOUT = 90000;

const local = (url) => {
  const { hostname } = new URL(url);
  return hostname === '127.0.0.1' || hostname === 'localhost';
};

const failures = [];
const timings = [];
for (const engine of engines) {
  const browser = await all[engine].launch();
  const version = browser.version();
  for (const build of builds) {
    const context = await browser.newContext();
    await context.route('**/*', (route) =>
      local(route.request().url()) ? route.continue() : route.abort(),
    );
    const tab = await context.newPage();
    const errors = [];
    // WebKit reports a CORS refusal as a page error: the two the credentials case expects (a
    // credentialed request to /cors-star, which allows any origin) are not failures.
    tab.on('pageerror', (e) => {
      const text = String(e);
      if (!/\/cors-star\b.*access control checks/.test(text)) errors.push(text);
    });
    const run = `${engine}-${build}-${Date.now() % 100000}`;
    const url = `${page}/${build}/index.html?api=${encodeURIComponent(api)}&dead=${ports.dead}&run=${run}`;
    let rows;
    const started = Date.now();
    try {
      await tab.goto(url);
      await tab.waitForFunction(() => window.fetchDone === true, null, { timeout: PAGE_TIMEOUT });
      rows = JSON.parse(await tab.evaluate(() => window.fetchResult));
    } catch (e) {
      rows = { error: String(e).split('\n')[0] };
    }
    const seconds = ((Date.now() - started) / 1000).toFixed(1);
    await context.close();
    const label = `${engine} ${version} ${build}`;
    if (!Array.isArray(rows)) {
      failures.push(`${label}: ${rows.error}`);
      console.log(`FAIL ${label}: ${rows.error}`);
      continue;
    }
    console.log(`${label} (${seconds} s)`);
    for (const row of rows) {
      const { client, case: name, ok, ms, error, ...rest } = row;
      const detail = ok ? JSON.stringify(rest) : error;
      console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${client.padEnd(4)} ${name.padEnd(12)} ${String(ms).padStart(5)} ms  ${detail}`);
      if (!ok) failures.push(`${label} ${client} ${name}: ${error}`);
      if (ok && name === 'stream') {
        timings.push({ engine, version, build, client, first: rest.first, span: rest.span });
      }
    }
    for (const e of errors) {
      failures.push(`${label}: uncaught ${e}`);
      console.log(`  FAIL uncaught: ${e}`);
    }
  }
  await browser.close();
}

console.log('\nEvent stream timings (first event after it was written / span of the ten):');
for (const t of timings) {
  console.log(`  ${t.engine} ${t.version} ${t.build} ${t.client}: ${t.first} ms / ${t.span} ms`);
}
if (failures.length) {
  console.error(`\nfetch-adapter: ${failures.length} failed:\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log(`\nfetch-adapter: every case passed (${engines.join(', ')}; ${builds.join(', ')})`);
