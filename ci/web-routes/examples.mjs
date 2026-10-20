// Opens every example's routes in Chromium against its release web build (`just examples-web`), and
// takes the screenshots its README shows (`just example-screenshots`).
//
//   node examples.mjs check <example> <build/web dir> [--print]
//   node examples.mjs shots <example> <build/web dir> <out dir>
//
// scripts/check-examples-web.sh builds the example (a throwaway copy, `--no-web-resources-cdn`) and
// runs this. examples.json, next to this file, says per example which URLs to open and the text each
// must show (`urls`), which routes are not opened and why (`skip`), what may be logged or fetched and
// why (`allow`), the `--dart-define`s of its build (`defines`) and its screenshots (`shots`).
// cli/tests/examples_web.rs keeps `urls` and `skip` in step with `fsp routes --json`, and
// example-images.mjs keeps `shots` in step with docs/images/examples/ and the READMEs.
//
// A URL works when, in a fresh browser profile with every request off this machine aborted:
//   - Flutter starts (`flutter-view`) and, once its semantics tree is on (the harness clicks the
//     placeholder Flutter puts in every page, so no example needs `semantics_ids`), a node's text
//     contains `expect` within 20 s;
//   - the address ends on `at`, when the URL names where a redirect or a guard lands;
//   - nothing threw (`pageerror`) and nothing was logged as an error: a release build draws a broken
//     widget as a grey box and prints the exception to the console as errors, so that is where it
//     shows. The browser's own `Failed to load resource` lines are not the app's errors;
//   - nothing was fetched from another host, unless `allow` says why. An `allow` entry that matches
//     nothing in a whole run fails it, so it goes when its reason does.
//
// A URL with `known` (what is broken, and the fix item or issue that fixes it) is reported but does
// not fail the run, and fails once it passes, so the note cannot outlive the bug.
//
// --print also prints every text each page shows (to write an `expect`).
//
// A screenshot is taken once the page passes those checks and two captures 300 ms apart are the
// same bytes (a spinner or a blinking cursor never settles: pick another screen). It is optimised
// with a pinned oxipng (Docker; FSP_OXIPNG=/path/to/oxipng uses a local binary instead), held to
// the byte budget, and only then are the example's images replaced in <out dir>.
//
// FSP_CHROMIUM=/path/to/chrome uses a Chromium that is already on disk; otherwise Playwright's own
// (`npx --no-install playwright install chromium` in this folder).
//
// Exit codes: 0 every URL (or shot) passed, 1 one failed, 2 usage or an unknown example.
import { spawnSync } from "node:child_process";
import { createServer } from "node:http";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { extname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const SPEC = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("examples.json", import.meta.url)),
    "utf8",
  ),
);
const OXIPNG =
  "ghcr.io/shssoichiro/oxipng:v9.1.5@sha256:e1623b0da9f14b63b242ffb78e4eef4ba0f09c9159880d238665af4654c75b4f";
// How long a page has to show its text, and to settle for a screenshot.
const TIMEOUT = 20000;
const SETTLE_TRIES = 33;
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
    "usage: node examples.mjs check <example> <build/web dir> [--print]\n" +
      "       node examples.mjs shots <example> <build/web dir> <out dir>",
  );
  process.exit(2);
};

const [mode, name, buildDir, ...rest] = process.argv.slice(2);
if (!["check", "shots"].includes(mode) || !name || !buildDir) usage();
if (mode === "shots" && rest.length !== 1) usage();
const entry = SPEC.examples[name];
if (!entry) {
  console.error(`examples.json has no entry for ${name}`);
  process.exit(2);
}
const print = rest.includes("--print");

const firstLine = (text) => String(text).split("\n")[0].slice(0, 300);

const isLocal = (url) => {
  try {
    const { protocol, hostname } = new URL(url);
    if (protocol === "data:" || protocol === "blob:") return true;
    return ["localhost", "127.0.0.1", "[::1]"].includes(hostname);
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
    if (isLocal(requested)) return route.continue();
    if (!allowed("blocked", requested)) problems.push(`fetched ${requested}`);
    return route.abort();
  });
  const page = await context.newPage();
  // Date.now() is fixed (a page that prints a time prints the same one every run); timers run.
  await page.clock.setFixedTime(new Date(SPEC.time));
  page.on("pageerror", (error) =>
    problems.push(`uncaught: ${firstLine(error.message)}`),
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
    // The "Enable accessibility" placeholder: a click turns the semantics tree on.
    await page.evaluate(() =>
      document.querySelector("flt-semantics-placeholder")?.click(),
    );
    const deadline = Date.now() + TIMEOUT;
    for (;;) {
      seen = await texts(page);
      if (seen.some((t) => t.includes(url.expect))) break;
      if (Date.now() > deadline) {
        problems.push(
          `"${url.expect}" did not appear within ${TIMEOUT} ms; the page shows ${JSON.stringify(seen.slice(0, 15))}`,
        );
        break;
      }
      await page.waitForTimeout(250);
    }
    // An error a frame later still counts.
    await page.waitForTimeout(500);
    at = locationOf(page.url());
    if (url.at !== undefined && at !== url.at) {
      problems.push(`ended at ${at}, not ${url.at}`);
    }
  } catch (error) {
    problems.push(firstLine(error.message));
  }
  return { context, page, problems, seen, at };
};

/** Two captures 300 ms apart that are the same bytes, or null. */
const settle = async (page) => {
  let last = await page.screenshot();
  for (let i = 0; i < SETTLE_TRIES; i++) {
    await page.waitForTimeout(300);
    const next = await page.screenshot();
    if (next.equals(last)) return next;
    last = next;
  }
  return null;
};

const optimise = (dir) => {
  const files = readdirSync(dir).filter((f) => f.endsWith(".png"));
  const args = ["-o", "4", "--strip", "safe", ...files];
  const run = process.env.FSP_OXIPNG
    ? spawnSync(process.env.FSP_OXIPNG, args, { cwd: dir, stdio: "inherit" })
    : spawnSync(
        "docker",
        ["run", "--rm", "-v", `${dir}:/work`, "-w", "/work", OXIPNG, ...args],
        { stdio: "inherit" },
      );
  return run.status === 0;
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
    if (mode === "check") {
      for (const url of entry.urls) {
        const { context, problems, seen, at } = await open(
          browser,
          base,
          url,
          SPEC.viewport,
        );
        await context.close();
        if (url.known && problems.length > 0) {
          // A failure someone is fixing elsewhere: reported, not failed.
          console.log(`known: ${name} ${url.path} (${url.known})`);
          for (const p of problems) console.log(`  ${p}`);
        } else if (url.known) {
          failed = true;
          console.error(
            `FAIL: ${name} ${url.path} passes now: remove its "known"`,
          );
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
    } else {
      const out = resolve(rest[0]);
      const temp = mkdtempSync(join(tmpdir(), "fespalier-example-shots-"));
      try {
        const shots = entry.shots ?? [];
        if (shots.length === 0 || shots.length > SPEC.budget.perExample) {
          throw new Error(
            `${name} has ${shots.length} shots; 1 to ${SPEC.budget.perExample} are allowed`,
          );
        }
        for (const shot of shots) {
          const viewport = { ...SPEC.viewport, ...(shot.viewport ?? {}) };
          const { context, page, problems } = await open(
            browser,
            base,
            shot,
            viewport,
          );
          if (problems.length === 0) {
            const png = await settle(page);
            if (png) writeFileSync(join(temp, shot.file), png);
            else
              problems.push(
                "the screen did not settle within 10 s (a spinner, a cursor or an animation)",
              );
          }
          await context.close();
          if (problems.length === 0)
            console.log(`shot: ${name} ${shot.path} -> ${shot.file}`);
          else {
            failed = true;
            console.error(`FAIL: ${name} ${shot.path} (${shot.file})`);
            for (const p of problems) console.error(`  ${p}`);
          }
        }
        if (failed) throw new Error("no image was replaced");
        if (!optimise(temp))
          throw new Error("oxipng failed; no image was replaced");
        for (const shot of shots) {
          const size = statSync(join(temp, shot.file)).size;
          console.log(`  ${shot.file}: ${size} bytes`);
          if (size > SPEC.budget.perImage) {
            throw new Error(
              `${shot.file} is ${size} bytes, over the budget of ${SPEC.budget.perImage}: pick a calmer screen, never a lower scale`,
            );
          }
        }
        rmSync(out, { recursive: true, force: true });
        mkdirSync(out, { recursive: true });
        for (const shot of shots)
          copyFileSync(join(temp, shot.file), join(out, shot.file));
        console.log(`wrote ${shots.length} images to ${out}`);
      } catch (error) {
        failed = true;
        console.error(`FAIL: ${firstLine(error.message)}`);
      } finally {
        rmSync(temp, { recursive: true, force: true });
      }
    }
  } finally {
    await browser.close();
    server.close();
  }
  return failed ? 1 : 0;
};

process.exit(await main());
