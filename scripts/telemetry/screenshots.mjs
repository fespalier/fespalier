// Regenerates the README screenshots in docs/images/telemetry (`just telemetry-screenshots`).
//
//   node scripts/telemetry/screenshots.mjs [--no-start] [--no-seed] [--keep] [--app-build <dir>]
//                                          [--out <dir>] [--width <px>]
//                                          [--o2 <url>] [--grafana <url>] [--otlp <url>]
//
// Not part of `just ci` or CI. It needs Docker (Compose 2.20+), Node, python3 and a Chromium.
// FSP_CHROMIUM=/path/to/chrome uses a Chromium that is already on disk; otherwise Playwright's own
// (`npx playwright install chromium` in ci/web-routes).
//
// What it does:
//   1. starts cli/templates/telemetry/compose.yaml as its own Compose project, with Grafana, on
//      ports of its own (15080, 13000, 14317, 14318), so a stack you run yourself is untouched;
//   2. sends seed.py's --showcase session in real time (a batch every 15 s for six minutes), because
//      Grafana's span metrics are stamped when the collector receives a span;
//   3. waits until Grafana's metrics hold every seeded span, opens each dashboard in a headless
//      Chromium (light theme, 100 %), and refuses to go on when a panel is blank, still loading, or
//      says there is no data;
//   4. crops the dashboard, optimises the PNGs losslessly with a pinned oxipng image, checks the
//      byte budget, and only then moves them into --out;
//   5. removes the stack and its volumes (--keep leaves it up).
//
// --no-start uses the stack that is already running at --o2, --grafana and --otlp (the standard
// ports by default; the Compose project is then not touched). --no-seed skips step 2, for data that
// is already there. --app-build serves a Flutter web build of examples/telemetry on 127.0.0.1:8123
// first, and visits its routes, so that its real spans join the seeded ones; see
// examples/telemetry/README.md.
//
// Everything that depends on the look of OpenObserve or Grafana is in SELECTORS. When a new image
// of either moves something, only that object needs to change, and the error names the selector
// that matched nothing. Never commit images from a run that printed a failure.
import { spawn, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
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
import { extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const require = createRequire(
  new URL("../../ci/web-routes/package.json", import.meta.url),
);

const SERVICE = "telemetry-example";
const PROJECT = "fespalier-telemetry-shots";
const COMPOSE = join(root, "cli/templates/telemetry/compose.yaml");
const OXIPNG =
  "ghcr.io/shssoichiro/oxipng:v9.1.5@sha256:e1623b0da9f14b63b242ffb78e4eef4ba0f09c9159880d238665af4654c75b4f";
const CREDENTIALS = {
  email: "dev@fespalier.local",
  password: "Fespalier-local-1",
};
const DRIP_MINUTES = 6;
const BUDGET = { perImage: 150_000, total: 800_000 };
const MAX_HEIGHT = 1600;

// What each UI calls its parts. OpenObserve: `data-test` attributes. Grafana: `data-testid`.
const SELECTORS = {
  o2: {
    // The login form's fields and button.
    user: '[data-test="login-user-id"] input',
    password: '[data-test="login-password"] input',
    signIn: '[data-test="login-sign-in"]',
    // One dashboard panel.
    panel: '[data-test="dashboard-panel-container"]',
    // A panel's title bar, and what a panel draws (a chart or a stat on a canvas, a table, Markdown).
    title: '[data-test="dashboard-panel-bar"]',
    table: '[data-test="o2-table"]',
    row: '[data-test^="o2-table-row-"]',
    markdown: '[data-test="markdown-renderer"]',
    // The title and the App variable, above the panels.
    header: '[data-test="dashboard-name-title"]',
    // The element that holds every panel; the crop ends at its bottom.
    grid: ".grid-stack",
    // The App variable's current value.
    variable: '[data-test="variable-selector-service-inner-value"]',
    // A notification that OpenObserve or Grafana raised (a failed query shows one).
    toast: ".q-notification, [role=alert]",
    noData: /\bno data\b/i,
  },
  grafana: {
    panel: 'section[data-testid^="data-testid Panel header"]',
    title: '[data-testid^="data-testid Panel header"] h2',
    table: '[role="table"], [role="grid"]',
    row: '[role="row"]',
    markdown: '[data-testid="TextPanel-converted-content"]',
    // The controls row (variables, time picker) at the top of a kiosk dashboard.
    header: '[data-testid="data-testid dashboard controls"]',
    grid: '[data-testid="data-testid Layout container "], .react-grid-layout',
    toast: "[role=alert], .panel-info-corner--error",
    noData: /\bno data\b/i,
  },
};
const NOT_ENOUGH = /not enough data yet/i;

// File name -> where it is and what to wait for.
const SHOTS = [
  { file: "grafana-app-health.png", ui: "grafana", dashboard: "health" },
  {
    file: "grafana-screens.png",
    ui: "grafana",
    dashboard: "screens",
    limit: 1000,
  },
  {
    file: "openobserve-app-health.png",
    ui: "o2",
    dashboard: "fespalier · App health",
  },
  {
    file: "openobserve-screens.png",
    ui: "o2",
    dashboard: "fespalier · Screens",
    limit: 1000,
  },
  {
    file: "openobserve-actions.png",
    ui: "o2",
    dashboard: "fespalier · Actions",
    limit: 850,
  },
  {
    file: "openobserve-errors.png",
    ui: "o2",
    dashboard: "fespalier · Errors",
    limit: 1000,
  },
];

// ---------------------------------------------------------------------------------- arguments

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name, fallback) => {
  const at = args.indexOf(name);
  return at >= 0 && args[at + 1] ? args[at + 1] : fallback;
};
const noStart = flag("--no-start");
const keep = flag("--keep");
const ports = noStart
  ? { o2: 5080, grafana: 3000, http: 4318, grpc: 4317 }
  : { o2: 15080, grafana: 13000, http: 14318, grpc: 14317 };
const urls = {
  o2: option("--o2", `http://localhost:${ports.o2}`),
  grafana: option("--grafana", `http://localhost:${ports.grafana}`),
  otlp: option("--otlp", `http://localhost:${ports.http}`),
};
const out = resolve(option("--out", join(root, "docs/images/telemetry")));
const width = Number(option("--width", "1900"));
const appBuild = option("--app-build", "");
const authorization =
  "Basic " +
  Buffer.from(`${CREDENTIALS.email}:${CREDENTIALS.password}`).toString(
    "base64",
  );

const say = (text) => console.log(`==> ${text}`);
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

class Failure extends Error {}

// ------------------------------------------------------------------------------------- docker

const compose = (...words) =>
  spawnSync(
    "docker",
    ["compose", "-f", COMPOSE, "-p", PROJECT, "--profile", "grafana", ...words],
    {
      env: {
        ...process.env,
        FSP_O2_PORT: String(ports.o2),
        FSP_GRAFANA_PORT: String(ports.grafana),
        FSP_OTLP_HTTP_PORT: String(ports.http),
        FSP_OTLP_GRPC_PORT: String(ports.grpc),
      },
      stdio: "inherit",
    },
  );

const startStack = () => {
  say(
    `start the stack as the Compose project ${PROJECT} (ports ${Object.values(ports).join(", ")})`,
  );
  if (compose("up", "-d").status !== 0)
    throw new Failure("docker compose up failed");
  if (compose("wait", "dashboards").status !== 0)
    throw new Failure("the dashboard importer failed");
};

const stopStack = () => {
  if (noStart || keep) return;
  say("remove the stack and its volumes");
  compose("down", "-v");
};

// -------------------------------------------------------------------------------------- data

const sendSeed = () =>
  new Promise((done, fail) => {
    say(
      `send the showcase session, a batch every 15 s for ${DRIP_MINUTES} minutes`,
    );
    const child = spawn(
      "python3",
      [
        join(root, "scripts/telemetry/seed.py"),
        "--showcase",
        "--drip-minutes",
        String(DRIP_MINUTES),
        "--endpoint",
        urls.otlp,
      ],
      { stdio: ["ignore", "pipe", "inherit"] },
    );
    let text = "";
    child.stdout.on("data", (chunk) => {
      text += chunk;
      process.stdout.write(chunk);
    });
    child.on("close", (code) => {
      const sent = /sent (\d+) spans/.exec(text);
      if (code !== 0 || !sent) fail(new Failure(`seed.py exited with ${code}`));
      else done(Number(sent[1]));
    });
  });

const o2Get = async (path) => {
  const response = await fetch(urls.o2 + path, {
    headers: { Authorization: authorization },
  });
  return response.json();
};

const spanMetrics = async () => {
  const query = `sum(sum_over_time(fespalier_calls{service_name="${SERVICE}"}[1h]))`;
  const body = await o2Get(
    `/api/default/prometheus/api/v1/query?query=${encodeURIComponent(query)}`,
  );
  return Number(body?.data?.result?.[0]?.value?.[1] ?? 0);
};

const waitForMetrics = async (spans) => {
  say(`wait until the span metrics hold ${spans} spans`);
  const deadline = Date.now() + 120_000;
  let have = 0;
  while (Date.now() < deadline) {
    have = await spanMetrics().catch(() => 0);
    if (have >= spans) return;
    await sleep(3000);
  }
  throw new Failure(
    `the span metrics hold ${have} of ${spans} spans after 120 s`,
  );
};

// ----------------------------------------------------------------------------- the web app

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".otf": "font/otf",
  ".ttf": "font/ttf",
  ".woff2": "font/woff2",
};
const APP_PORT = 8123;

/** Serves a Flutter web build on 127.0.0.1:8123 (a deep link falls back to index.html). */
const serveApp = (dir) =>
  new Promise((done) => {
    const server = createServer((request, response) => {
      const path = decodeURIComponent(
        new URL(request.url, "http://x").pathname,
      );
      let file = join(dir, path);
      if (
        !file.startsWith(dir) ||
        !existsSync(file) ||
        statSync(file).isDirectory()
      )
        file = join(dir, "index.html");
      response.writeHead(200, {
        "Content-Type": MIME[extname(file)] ?? "application/octet-stream",
      });
      response.end(readFileSync(file));
    });
    server.listen(APP_PORT, "127.0.0.1", () => done(server));
  });

/** Opens the example app's routes, so that its real spans arrive beside the seeded ones. */
/** How many fespalier spans of the service OpenObserve holds. */
const appSpans = async () => {
  const search = {
    query: {
      sql: `SELECT COUNT(*) AS n FROM "default" WHERE service_name = '${SERVICE}' AND fespalier_operation IS NOT NULL`,
      start_time: Date.now() * 1000 - 3600e6,
      end_time: Date.now() * 1000 + 60e6,
      from: 0,
      size: 1,
    },
  };
  const response = await fetch(`${urls.o2}/api/default/_search?type=traces`, {
    method: "POST",
    headers: {
      Authorization: authorization,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(search),
  });
  return (await response.json()).hits?.[0]?.n ?? 0;
};

const visitApp = async (chromium, launch) => {
  const before = await appSpans();
  const server = await serveApp(resolve(appBuild));
  const browser = await chromium.launch(launch);
  try {
    const page = await (
      await browser.newContext({ viewport: { width: 900, height: 800 } })
    ).newPage();
    page.on("pageerror", (error) => console.log(`    app: ${error.message}`));
    const routes = [
      "/",
      "/orders",
      ...[1, 2, 3, 4, 5].map((n) => `/orders/${n}`),
      "/settings",
      "/login",
    ];
    say(
      `visit ${routes.length} routes of the example app at http://127.0.0.1:${APP_PORT}`,
    );
    for (const route of routes) {
      await page.goto(`http://127.0.0.1:${APP_PORT}${route}`);
      await sleep(7000); // the exporter sends a batch every 5 s, and a page that goes away loses its batch
    }
    await sleep(3000);
  } finally {
    await browser.close();
    server.close();
  }
  const count = (await appSpans()) - before;
  if (count <= 0) throw new Failure("no spans of the example app arrived");
  console.log(`    ${count} spans of the example app arrived in OpenObserve`);
};

// ----------------------------------------------------------------------------------- browser

const loginO2 = async (page) => {
  const S = SELECTORS.o2;
  await page.goto(`${urls.o2}/web/login`);
  await page.locator(S.user).fill(CREDENTIALS.email);
  await page.locator(S.password).fill(CREDENTIALS.password);
  await page.locator(S.signIn).click();
  await page.waitForURL((url) => !url.pathname.endsWith("/login"), {
    timeout: 20_000,
  });
};

const o2Url = async (title) => {
  const folder = await o2Get(
    "/api/v2/default/folders/dashboards/name/fespalier",
  );
  const list = await o2Get(`/api/default/dashboards?folder=${folder.folderId}`);
  const found = list.dashboards?.find((item) => item.title === title);
  if (!found)
    throw new Failure(
      `OpenObserve has no dashboard "${title}" in the folder fespalier`,
    );
  const query = `org_identifier=default&dashboard=${found.dashboard_id}&folder=${folder.folderId}&tab=default&period=10m&var-service=${SERVICE}`;
  return `${urls.o2}/web/dashboards/view?${query}`;
};

const grafanaUrl = (uid) =>
  `${urls.grafana}/d/fespalier-${uid}?orgId=1&from=now-8m&to=now&var-service=${SERVICE}&theme=light&kiosk`;

/** What each panel shows, and what is wrong with it. Runs in the page. */
const inspect = ({ S, notEnough, noData }) => {
  const problems = [];
  const summary = [];
  const noDataPattern = new RegExp(noData, "i");
  const notEnoughPattern = new RegExp(notEnough, "i");
  if (document.querySelector(S.toast))
    problems.push(
      `a notification is showing: ${document.querySelector(S.toast).innerText.slice(0, 80)}`,
    );
  const panels = [...document.querySelectorAll(S.panel)];
  if (panels.length === 0)
    return {
      problems: [`no element matches the panel selector ${S.panel}`],
      summary: "",
    };
  for (const panel of panels) {
    const title = (panel.querySelector(S.title) ?? panel).textContent
      .trim()
      .replace(/\s+/g, " ")
      .slice(0, 60);
    const text = panel.innerText.replace(/\s+/g, " ").trim();
    const canvases = [...panel.querySelectorAll("canvas")];
    const tables = [...panel.querySelectorAll(S.table)];
    const markdown = S.markdown ? panel.querySelector(S.markdown) : null;
    let kind = "text";
    if (tables.length > 0) {
      kind = "table";
      const rows = panel.querySelectorAll(S.row).length;
      if (rows < 1) problems.push(`${title}: a table without rows`);
    } else if (canvases.length > 0) {
      kind = "canvas";
      // OpenObserve stacks a few canvases (an empty overlay among them): one must have content.
      let most = 0;
      for (const canvas of canvases) {
        if (canvas.width === 0 || canvas.height === 0) continue;
        const context = canvas.getContext("2d");
        if (!context) continue;
        const { data } = context.getImageData(
          0,
          0,
          canvas.width,
          canvas.height,
        );
        const seen = new Set();
        for (let at = 0; at < data.length && seen.size < 12; at += 4) {
          seen.add((data[at] << 16) | (data[at + 1] << 8) | data[at + 2]);
        }
        most = Math.max(most, seen.size);
      }
      if (most < 6)
        problems.push(
          `${title}: the canvas has ${most} colours, it looks blank`,
        );
    } else if (markdown || text.length > 0) {
      kind = "markdown";
    }
    if (text.length < 3 && canvases.length === 0)
      problems.push(`${title}: empty`);
    // A text panel may say these words; a tile or a table must not.
    if (!markdown && noDataPattern.test(text))
      problems.push(`${title}: says "no data"`);
    if (!markdown && notEnoughPattern.test(text))
      problems.push(`${title}: says "Not enough data yet"`);
    summary.push(`${kind}:${title}:${text.length}`);
  }
  return { problems, summary: summary.join("|") };
};

/** Waits for the panels to hold data and to stop changing, or throws what is wrong. */
const settle = async (page, ui, name) => {
  const S = SELECTORS[ui];
  const arg = {
    S: { ...S, noData: undefined },
    notEnough: NOT_ENOUGH.source,
    noData: S.noData.source,
  };
  const deadline = Date.now() + 90_000;
  let before = "";
  let last;
  while (Date.now() < deadline) {
    last = await page.evaluate(inspect, arg);
    // Two looks 1.5 s apart must agree, or a panel is still drawing.
    if (
      last.problems.length === 0 &&
      last.summary === before &&
      last.summary !== ""
    ) {
      await sleep(1000);
      return;
    }
    before = last.summary;
    await sleep(1500);
  }
  await debugDump(page, name);
  throw new Failure(
    `${name}: ${last.problems.length ? last.problems.join("; ") : "the panels never settled"}`,
  );
};

const debugDump = async (page, name) => {
  const base = join(tmpdir(), `fespalier-shots-${name}`);
  await page
    .screenshot({ path: `${base}.debug.png`, fullPage: true })
    .catch(() => {});
  writeFileSync(`${base}.html`, await page.content().catch(() => ""));
  console.log(`    saved ${base}.debug.png and ${base}.html`);
};

/** The rectangle to keep: from the top of the content to the bottom of the grid. */
const cropOf = async (page, ui, shot) => {
  const S = SELECTORS[ui];
  const box = await page.evaluate(
    ({ S, ui, limit }) => {
      const grid = document.querySelector(S.grid);
      const header = document.querySelector(S.header);
      if (!grid) return { missing: "grid" };
      if (!header) return { missing: "header" };
      const panels = [...document.querySelectorAll(S.panel)];
      const bottoms = panels.map(
        (p) => p.getBoundingClientRect().bottom + window.scrollY,
      );
      const main = document.querySelector('[data-test="main-content"]');
      const origin = ui === "o2" ? (main?.getBoundingClientRect().top ?? 0) : 0;
      // Whole panels only: the last one whose bottom is within the limit.
      const fitting = bottoms.filter((b) => b - origin <= limit);
      const bottom =
        fitting.length > 0 ? Math.max(...fitting) : Math.min(...bottoms);
      // OpenObserve's sidebar is on the left; keep the page title and App variable, not the menu.
      const left =
        ui === "o2"
          ? (document
              .querySelector('[data-test="main-content"]')
              ?.getBoundingClientRect().left ?? 0)
          : 0;
      const top =
        ui === "o2"
          ? (document
              .querySelector('[data-test="main-content"]')
              ?.getBoundingClientRect().top ?? 0)
          : 0;
      return { left, top, bottom, width: window.innerWidth };
    },
    { S, ui, limit: shot.limit ?? MAX_HEIGHT },
  );
  if (box.missing)
    throw new Failure(
      `${shot.file}: no element matches SELECTORS.${ui}.${box.missing}`,
    );
  return {
    x: Math.floor(box.left),
    y: Math.floor(box.top),
    width: Math.floor(box.width - box.left - (ui === "o2" ? 15 : 0)),
    height: Math.ceil(box.bottom - box.top + 4),
  };
};

const capture = async (browser, shot, dir) => {
  const context = await browser.newContext({
    viewport: { width, height: shot.ui === "o2" ? 2200 : 1500 },
    deviceScaleFactor: 1,
    colorScheme: "light",
    locale: "en-US",
    timezoneId: "UTC",
  });
  try {
    const page = await context.newPage();
    let target;
    if (shot.ui === "o2") {
      await loginO2(page);
      target = await o2Url(shot.dashboard);
    } else {
      target = grafanaUrl(shot.dashboard);
    }
    await page.goto(target);
    if (shot.ui === "o2") {
      const selected = await page
        .locator(SELECTORS.o2.variable)
        .innerText({ timeout: 30_000 })
        .catch(() => "");
      if (selected.trim() !== SERVICE)
        throw new Failure(
          `${shot.file}: the App variable shows "${selected}", not ${SERVICE}`,
        );
    }
    await settle(page, shot.ui, shot.file);
    await page.mouse.move(1, 1); // no tile shows its hover buttons
    await sleep(500);
    const clip = await cropOf(page, shot.ui, shot);
    await page.screenshot({ path: join(dir, shot.file), clip });
    console.log(`    ${shot.file}: ${clip.width}x${clip.height}`);
  } finally {
    await context.close();
  }
};

// ------------------------------------------------------------------------ optimise and budget

const optimise = (dir) => {
  say("optimise the PNGs (oxipng, lossless)");
  const files = readdirSync(dir).filter((name) => name.endsWith(".png"));
  const run = spawnSync(
    "docker",
    [
      "run",
      "--rm",
      "-v",
      `${dir}:/work`,
      "-w",
      "/work",
      OXIPNG,
      "-o",
      "4",
      "--strip",
      "safe",
      ...files,
    ],
    { stdio: "inherit" },
  );
  if (run.status !== 0) throw new Failure("oxipng failed");
};

const checkBudget = (dir) => {
  const sizes = readdirSync(dir)
    .filter((name) => name.endsWith(".png"))
    .map((name) => [name, statSync(join(dir, name)).size]);
  const total = sizes.reduce((sum, [, size]) => sum + size, 0);
  for (const [name, size] of sizes) console.log(`    ${name}: ${size} bytes`);
  console.log(`    total ${total} bytes`);
  const over = sizes.filter(([, size]) => size > BUDGET.perImage);
  if (over.length > 0 || total > BUDGET.total) {
    throw new Failure(
      `over the byte budget (${BUDGET.perImage} per image, ${BUDGET.total} in all): crop a shorter part of the dashboard, never lower the scale`,
    );
  }
};

// ------------------------------------------------------------------------------------- main

const main = async () => {
  const { chromium } = require("playwright");
  const launch = process.env.FSP_CHROMIUM
    ? { executablePath: process.env.FSP_CHROMIUM }
    : {};
  if (!noStart) startStack();
  if (!flag("--no-seed")) {
    const spans = await sendSeed();
    await waitForMetrics(spans);
  }
  if (appBuild) await visitApp(chromium, launch);
  const temp = mkdtempSync(join(tmpdir(), "fespalier-shots-"));
  const browser = await chromium.launch(launch);
  try {
    for (const shot of SHOTS) await capture(browser, shot, temp);
  } finally {
    await browser.close();
  }
  optimise(temp);
  checkBudget(temp);
  mkdirSync(out, { recursive: true });
  for (const name of readdirSync(temp))
    copyFileSync(join(temp, name), join(out, name));
  rmSync(temp, { recursive: true, force: true });
  say(`wrote ${SHOTS.length} images to ${out}`);
};

let code = 0;
try {
  await main();
} catch (error) {
  console.error(
    error instanceof Failure ? `screenshots: ${error.message}` : error,
  );
  code = 1;
} finally {
  stopStack();
}
process.exit(code);
