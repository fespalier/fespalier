// Replays the flows `fsp maestro` wrote, in Chromium, against a web build served locally.
//
//   node check.mjs <flows-dir> [--timeout <ms>]
//
// For every `*.yaml` in the folder whose first line says `fsp maestro` wrote it, the steps run the
// way Maestro would run them in a fresh browser: `launchApp` opens the flow's `url:`, `openLink`
// opens the link, and `extendedWaitUntil` / `assertVisible` wait for an element whose Flutter
// semantics identifier (`Semantics(identifier:)`, the DOM attribute `flt-semantics-identifier`)
// is the step's `id:`. Every request that is not to this machine is aborted, so a CDN cannot make
// the check flaky.
//
// This is not Maestro: it checks what fespalier answers for (the identifier reaches the web DOM,
// `ensureWebSemantics()` works, the link opens the route, the page builds in time). The browser
// is the Chromium build Playwright's pinned version installs (ci/web-routes/package-lock.json).
//
// Exit codes: 0 every flow passed, 1 a flow failed, 2 usage or no flows.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { chromium } from 'playwright';
import { parseAllDocuments } from 'yaml';

const MARKER = '# Written by `fsp maestro`';
// Maestro's own default for a wait that names no timeout.
const DEFAULT_TIMEOUT = 30000;

/** A step this check does not replay (it is not one `fsp maestro` writes). */
class Unsupported extends Error {}

const usage = () => {
  console.error('usage: node check.mjs <flows-dir>');
  process.exit(2);
};

const args = process.argv.slice(2);
if (args.length !== 1 || args[0].startsWith('-')) usage();
const dir = args[0];

const isLocal = (url) => {
  try {
    const { protocol, hostname } = new URL(url);
    if (protocol === 'data:' || protocol === 'blob:') return true;
    return ['localhost', '127.0.0.1', '[::1]', '::1'].includes(hostname);
  } catch {
    return false;
  }
};

const selector = (id) => `[flt-semantics-identifier="${id.replace(/["\\]/g, '\\$&')}"]`;

/** `{file, url, steps}` for a flow, or `{file, skip}` / `{file, error}`. */
const load = (file) => {
  const text = readFileSync(join(dir, file), 'utf8');
  const docs = parseAllDocuments(text);
  const broken = docs.flatMap((d) => d.errors);
  if (broken.length > 0) return { file, error: `${file} is not valid YAML: ${broken[0].message}` };
  const [head, body] = docs.map((d) => d.toJS());
  if (!head || head.url === undefined) {
    return { file, error: `${file} is not a web flow (it has appId:)` };
  }
  const steps = Array.isArray(body) ? body : [];
  const run = steps.find((s) => s && typeof s === 'object' && 'runFlow' in s);
  if (run) {
    const target = typeof run.runFlow === 'string' ? run.runFlow : run.runFlow?.file;
    return {
      file,
      skip: `skipped ${file}: it runs ${target} first (a sign-in), which this check does not`,
    };
  }
  return { file, url: String(head.url), steps };
};

const files = readdirSync(dir)
  .filter((f) => f.endsWith('.yaml'))
  .sort()
  .filter((f) => readFileSync(join(dir, f), 'utf8').startsWith(MARKER));
if (files.length === 0) {
  console.error(`no flow written by fsp maestro in ${dir}`);
  process.exit(2);
}

const flows = files.map(load);
let failed = false;
let ran = 0;
const browser = await chromium.launch();
console.log(`chromium ${browser.version()} (playwright, pinned in package-lock.json)`);

try {
  for (const flow of flows) {
    if (flow.error) {
      console.error(`FAIL: ${flow.error}`);
      failed = true;
      continue;
    }
    if (flow.skip) {
      console.log(flow.skip);
      continue;
    }

    // A fresh context is a fresh profile: what `launchApp` means for a web flow.
    const context = await browser.newContext();
    await context.route('**/*', (route) =>
      isLocal(route.request().url()) ? route.continue() : route.abort(),
    );
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));

    let link = flow.url;
    let timeout = DEFAULT_TIMEOUT;
    let problem = null;
    try {
      for (const step of flow.steps) {
        if (step === 'launchApp') {
          await page.goto(flow.url);
          // Flutter's engine boots after `load`: a link opened before it listens would be lost.
          await page.locator('flt-glass-pane').first().waitFor({ state: 'attached', timeout });
        } else if (step && typeof step === 'object' && 'openLink' in step) {
          link = typeof step.openLink === 'string' ? step.openLink : step.openLink.link;
          await page.goto(link);
        } else if (step && typeof step === 'object' && 'extendedWaitUntil' in step) {
          const wait = step.extendedWaitUntil;
          const id = wait?.visible?.id;
          if (typeof id !== 'string') throw new Unsupported(JSON.stringify(step));
          timeout = wait.timeout ?? DEFAULT_TIMEOUT;
          try {
            // `attached`, not `visible`: a semantics node is a transparent overlay, and Flutter
            // takes an offstage page out of the tree, so being in the DOM is "shown".
            await page.locator(selector(id)).first().waitFor({ state: 'attached', timeout });
          } catch {
            problem = `${flow.file}: ${id} did not appear within ${timeout} ms after ${link}`;
            break;
          }
          console.log(`ok: ${flow.file}: ${link} shows ${id}`);
        } else {
          throw new Unsupported(JSON.stringify(step));
        }
      }
    } catch (e) {
      problem =
        e instanceof Unsupported
          ? `${flow.file}: this check does not run the step ${e.message}`
          : `${flow.file}: ${String(e.message).split('\n')[0]}`;
    }
    ran += 1;
    if (problem) {
      failed = true;
      console.error(`FAIL: ${problem}`);
      for (const message of errors) console.error(`  page error: ${message}`);
    }
    await context.close();
  }
} finally {
  await browser.close();
}

if (ran === 0 && !failed) {
  console.error(`no web flow to run in ${dir}`);
  process.exit(2);
}
process.exit(failed ? 1 : 0);
