// Opens every example's routes in Chromium against its release web build (`just examples-web`).
//
//   node examples.mjs check <example> <build/web dir> [--print]
//
// scripts/check-examples-web.sh builds the example (a throwaway copy, `--no-web-resources-cdn`) and
// runs this. examples.json, next to this file, says per example which URLs to open and the text each
// must show (`urls`), which routes are not opened and why (`skip`), what may be logged or fetched and
// why (`allow`) and the `--dart-define`s of its build (`defines`). cli/tests/examples_web.rs keeps
// `urls` and `skip` in step with `fsp routes --json`: a URL that no route of the tree answers says
// why (`notFound`: the not-found page is the point; `handWritten`: a go_router route of the app's
// own answers it), which only that test reads.
//
// A URL works when, in a fresh browser profile where only the build's own server answers:
//   - Flutter starts (`flutter-view`) and, once its semantics tree is on (the harness clicks the
//     placeholder Flutter puts in every page, so no example needs `semantics_ids`), a node's text
//     contains `expect` within 20 s. `expect` is a text of the page itself, not of its layout (a
//     navigation label is on every page of its tab);
//   - the page then settles: its texts stay as they are for QUIET ms and the network is idle, so
//     an error a moment after the first frame still counts;
//   - the address ends on `at` (the URL's own path, without its query, when the entry gives none),
//     so a URL says where it lands: `at` is for a redirect, a guard or a path the app rewrites;
//   - nothing threw (`pageerror`) and nothing was logged as an error: a release build draws a broken
//     widget as a grey box and prints the exception to the console as errors, so that is where it
//     shows. The browser's own `Failed to load resource` lines are not the app's errors;
//   - nothing was requested from anywhere but the build's own server (and `data:` and `blob:`), not
//     even another port of this machine, unless `allow` says why. Every other request is aborted
//     whether or not it is allowed; `allow` only keeps it from being reported. An `allow` entry that
//     matches nothing in a whole run fails it, so it goes when its reason does.
//
// A URL with `known` ({ "problem": "a substring of the problem", "reason": "what is broken, and the
// fix item or issue that fixes it" }) is reported but does not fail the run. Any other problem of
// that URL still fails, and so does the URL once the problem is gone, so the note cannot outlive
// the bug.
//
// --print also prints every text each page shows (to write an `expect`).
//
// FSP_CHROMIUM=/path/to/chrome uses a Chromium that is already on disk; otherwise Playwright's own
// (`npx --no-install playwright install chromium` in this folder).
//
// Exit codes: 0 every URL passed, 1 one failed (or the example has no URL to check), 2 usage or an
// unknown example.
import { createServer } from "node:http";
import { existsSync, readFileSync, statSync } from "node:fs";
import { extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const SPEC = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("examples.json", import.meta.url)),
    "utf8",
  ),
);
// How long a page has to show its text, and then to settle.
const TIMEOUT = 20000;
// How long a page's texts must stay as they are, after its text appeared, before it counts as settled.
// A second is not enough: an error 2 s after a page was built comes about 1.5 s after its text can be
// read, and a window of 1 s closes before it.
const QUIET = 2000;
// How long to wait for the network to go idle once the texts have settled.
const IDLE = 5000;
const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".css": "text/css",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".svg": "image/svg+xml",
  ".otf": "font/otf",
  ".ttf": "font/ttf",
};

const usage = () => {
  console.error(
    "usage: node examples.mjs check <example> <build/web dir> [--print]",
  );
  process.exit(2);
};

const [mode, name, buildDir, ...rest] = process.argv.slice(2);
if (mode !== "check" || !name || !buildDir) usage();
const entry = SPEC.examples[name];
if (!entry) {
  console.error(`examples.json has no entry for ${name}`);
  process.exit(2);
}
if (!entry.urls?.length) {
  console.error(`examples.json lists no URL to check for ${name}`);
  process.exit(1);
}
const print = rest.includes("--print");

const firstLine = (text) => String(text).split("\n")[0].slice(0, 300);

/** The first stack frame of an uncaught error (`at f (url:line:col)`), or "" when it has none. */
const frameOf = (error) => {
  const frame = String(error.stack ?? "")
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line.startsWith("at "));
  return frame ? ` ${frame.slice(0, 200)}` : "";
};

/** Whether the build's own server (`origin`), or the browser itself (`data:`, `blob:`), answers `url`. */
const isServed = (url, origin) => {
  try {
    const { protocol, origin: requested } = new URL(url);
    return protocol === "data:" || protocol === "blob:" || requested === origin;
  } catch {
    return false;
  }
};

// Which `allow` entries matched something in this run: one that never does is stale.
const used = new Set();
const allowed = (kind, text) => {
  const match = (entry.allow ?? []).find(
    (a) => a[kind] && new RegExp(a[kind]).test(text),
  );
  if (match) used.add(match);
  return match !== undefined;
};

/** Serves the build on 127.0.0.1 at a free port; any path that is not a file is index.html. */
const serve = (dir) =>
  new Promise((done) => {
    const root = resolve(dir);
    const server = createServer((request, response) => {
      const path = decodeURIComponent(
        new URL(request.url, "http://x").pathname,
      );
      let file = join(root, path);
      if (
        !(file === root || file.startsWith(root + sep)) ||
        !existsSync(file) ||
        statSync(file).isDirectory()
      ) {
        file = join(root, "index.html");
      }
      response.writeHead(200, {
        "Content-Type": MIME[extname(file)] ?? "application/octet-stream",
      });
      response.end(readFileSync(file));
    });
    server.listen(0, "127.0.0.1", () => done(server));
  });

/** Every text the semantics tree shows: an `aria-label`, or the text of a node with no children. */
const texts = (page) =>
  page.evaluate(() => [
    ...new Set(
      [...document.querySelectorAll("flt-semantics, flt-semantics *")]
        .map((e) =>
          (
            e.getAttribute("aria-label") ||
            (e.childElementCount === 0 ? e.textContent : "") ||
            ""
          ).trim(),
        )
        .filter(Boolean),
    ),
  ]);

/** Where the app is: the hash route, decoded (`/` when there is none). */
const locationOf = (url) => {
  const hash = new URL(url).hash.slice(1);
  return hash === "" ? "/" : decodeURIComponent(hash);
};

/** A location without its query. */
const pathOf = (location) => location.split("?")[0];

/**
 * Turns the semantics tree on while it is off: a click on the "Enable accessibility" placeholder
 * Flutter puts in the page. The placeholder is not there before the engine has started, so this
 * runs on every poll until the first `flt-semantics` node exists.
 */
const enableSemantics = (page) =>
  page.evaluate(() => {
    if (!document.querySelector("flt-semantics")) {
      document.querySelector("flt-semantics-placeholder")?.click();
    }
  });

/**
 * Opens one URL of the example in a fresh context and checks it. Returns the context (the caller
 * closes it), the page, what went wrong, and the texts it saw.
 */
const open = async (browser, base, url, viewport) => {
  const context = await browser.newContext({
    viewport: { width: viewport.width, height: viewport.height },
    deviceScaleFactor: viewport.deviceScaleFactor,
    colorScheme: "light",
    locale: "en-US",
    timezoneId: "UTC",
  });
  const problems = [];
  await context.route("**/*", (route) => {
    const requested = route.request().url();
    if (isServed(requested, base)) return route.continue();
    if (!allowed("blocked", requested)) problems.push(`fetched ${requested}`);
    return route.abort();
  });
  const page = await context.newPage();
  // Date.now() is fixed (a page that prints a time prints the same one every run); timers run.
  await page.clock.setFixedTime(new Date(SPEC.time));
  page.on("pageerror", (error) =>
    problems.push(`uncaught: ${firstLine(error.message)}${frameOf(error)}`),
  );
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    const text = message.text();
    if (text.startsWith("Failed to load resource") || allowed("console", text))
      return;
    problems.push(`console error: ${firstLine(text)}`);
  });
  let seen = [];
  let at = null;
  try {
    await page.goto(`${base}/#${url.path}`);
    await page
      .locator("flutter-view")
      .first()
      .waitFor({ state: "attached", timeout: 30000 });
    const deadline = Date.now() + TIMEOUT;
    let shown = false;
    for (;;) {
      await enableSemantics(page);
      seen = await texts(page);
      if (seen.some((t) => t.includes(url.expect))) {
        shown = true;
        break;
      }
      if (Date.now() > deadline) {
        problems.push(
          `"${url.expect}" did not appear within ${TIMEOUT} ms; the page shows ${JSON.stringify(seen.slice(0, 15))}`,
        );
        break;
      }
      await page.waitForTimeout(250);
    }
    if (shown) {
      // Settle: the texts stay as they are for QUIET ms (a page that is still loading, or that
      // changes after its first frame, keeps changing them), then the network goes idle. An error
      // a moment after the text appeared is therefore still in the problems.
      const settleBy = Date.now() + TIMEOUT;
      let last = JSON.stringify(seen);
      let since = Date.now();
      for (;;) {
        await page.waitForTimeout(250);
        seen = await texts(page);
        const now = JSON.stringify(seen);
        if (now !== last) {
          last = now;
          since = Date.now();
        } else if (Date.now() - since >= QUIET) {
          break;
        }
        if (Date.now() > settleBy) {
          problems.push(
            `the page was still changing ${TIMEOUT} ms after "${url.expect}" appeared; it shows ${JSON.stringify(seen.slice(0, 15))}`,
          );
          break;
        }
      }
      await page
        .waitForLoadState("networkidle", { timeout: IDLE })
        .catch(() => {});
    }
    at = locationOf(page.url());
    // A URL ends where it was opened unless `at` says where it lands.
    const [want, got] =
      url.at === undefined ? [pathOf(url.path), pathOf(at)] : [url.at, at];
    if (got !== want) problems.push(`ended at ${at}, not ${want}`);
  } catch (error) {
    problems.push(firstLine(error.message));
  }
  return { context, page, problems, seen, at };
};

const main = async () => {
  const server = await serve(buildDir);
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch(
    process.env.FSP_CHROMIUM
      ? { executablePath: process.env.FSP_CHROMIUM }
      : {},
  );
  console.log(`${name}: chromium ${browser.version()}, ${base}`);
  let failed = false;
  try {
    for (const url of entry.urls) {
      const { context, problems, seen, at } = await open(
        browser,
        base,
        url,
        SPEC.viewport,
      );
      await context.close();
      if (url.known) {
        // A failure someone is fixing elsewhere: reported, not failed. Only the problem it names.
        const named = problems.filter((p) => p.includes(url.known.problem));
        const others = problems.filter((p) => !p.includes(url.known.problem));
        if (named.length === 0) {
          failed = true;
          console.error(
            `FAIL: ${name} ${url.path}: its "known" problem ${JSON.stringify(url.known.problem)} did not happen: remove the "known"`,
          );
        } else {
          console.log(`known: ${name} ${url.path} (${url.known.reason})`);
          for (const p of named) console.log(`  ${p}`);
        }
        if (others.length > 0) {
          failed = true;
          console.error(`FAIL: ${name} ${url.path}: more than it names`);
          for (const p of others) console.error(`  ${p}`);
        }
      } else if (problems.length === 0) {
        console.log(`ok: ${name} ${url.path} shows "${url.expect}"`);
      } else {
        failed = true;
        console.error(`FAIL: ${name} ${url.path}`);
        for (const p of problems) console.error(`  ${p}`);
      }
      if (print) console.log(`  at: ${at}\n  texts: ${JSON.stringify(seen)}`);
    }
    for (const allow of entry.allow ?? []) {
      if (!used.has(allow)) {
        failed = true;
        console.error(
          `FAIL: ${name}: the allow entry ${JSON.stringify(allow)} matched nothing: remove it`,
        );
      }
    }
    for (const skip of entry.skip ?? []) {
      console.log(`skipped: ${name} ${skip.pattern}: ${skip.reason}`);
    }
  } finally {
    await browser.close();
    server.close();
  }
  return failed ? 1 : 0;
};

process.exit(await main());
