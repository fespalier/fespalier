// The examples' README screenshots match ci/web-routes/examples.json (`just example-images`, in
// `just ci` and CI's skills job). No dependency, no browser, no build:
//
//   node ci/web-routes/example-images.mjs [path-to-fespalier-checkout]
//
// For each example of examples.json:
//   - docs/images/examples/<example>/ holds exactly the PNGs its `shots` name (none missing, none
//     left over from a shot that was removed);
//   - each is a PNG of the shot's viewport times its device pixel ratio, in pixels (the size in its
//     header, not what it draws);
//   - each is within the per-image budget, and all of docs/images/examples/ within the total;
//   - examples/<example>/README.md shows each one as `![<alt>](../../docs/images/examples/<example>/<file>)`;
//   - each is what `just example-screenshots` made from this spec: ci/web-routes/example-shots.lock.json
//     has, per image, a hash of what in examples.json decides it (the shot's path, `expect` and `at`,
//     its viewport, the fixed time and the example's `--dart-define`s) and the SHA-256 of its bytes.
//     A changed spec is "spec changed" and an image that was edited or replaced by hand is "image
//     changed", each with the command that fixes it;
//   - each shot is also one of the example's `urls` (not a `known` failure), with the same `expect`,
//     so `just examples-web` (CI's examples-web job) opens that URL at the spec's phone viewport
//     (390 x 844) and proves it renders there.
//
// What this does not prove: that an image shows the app as it is today (a changed page needs
// `just example-screenshots <example>`, and `git diff` shows the new pixels: no browser runs here),
// and that a shot with a viewport of its own renders at it: `just examples-web` opens every URL at
// the phone viewport only, so tabs' 1280 x 800 shot (the drawer) is rendered, and looked at, only when
// its image is made.
//
// `just example-screenshots [example ...]` makes the images. Exit 0 = they match, 1 = a problem, named.
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { LOCK_FILE, sha256, specHash } from "./shots.mjs";

const root = resolve(
  process.argv[2] ?? fileURLToPath(new URL("../..", import.meta.url)),
);
const spec = JSON.parse(
  readFileSync(join(root, "ci/web-routes/examples.json"), "utf8"),
);
const images = join(root, "docs/images/examples");
const lockFile = join(root, "ci/web-routes", LOCK_FILE);
const lock = existsSync(lockFile)
  ? JSON.parse(readFileSync(lockFile, "utf8"))
  : null;
const problems = [];
let total = 0;
let count = 0;

/** Width and height from a PNG's IHDR chunk, or null when it is not a PNG. */
const pngSize = (file) => {
  const bytes = readFileSync(file);
  const signature = "89504e470d0a1a0a";
  if (bytes.length < 24 || bytes.subarray(0, 8).toString("hex") !== signature)
    return null;
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
};

for (const [name, entry] of Object.entries(spec.examples)) {
  const shots = entry.shots ?? [];
  if (shots.length === 0 || shots.length > spec.budget.perExample) {
    problems.push(
      `${name}: ${shots.length} shots; 1 to ${spec.budget.perExample} are allowed`,
    );
  }
  const dir = join(images, name);
  const present = existsSync(dir) ? readdirSync(dir) : [];
  for (const file of present) {
    if (!shots.some((s) => s.file === file)) {
      problems.push(
        `docs/images/examples/${name}/${file} is no shot of examples.json: remove it`,
      );
    }
  }
  const readmePath = join(root, "examples", name, "README.md");
  const readme = existsSync(readmePath)
    ? readFileSync(readmePath, "utf8")
    : null;
  if (readme === null)
    problems.push(`examples/${name}/README.md does not exist`);
  for (const shot of shots) {
    const file = join(dir, shot.file);
    const rel = `docs/images/examples/${name}/${shot.file}`;
    if (!existsSync(file)) {
      problems.push(`${rel} is missing: run just example-screenshots ${name}`);
      continue;
    }
    count += 1;
    const bytes = statSync(file).size;
    total += bytes;
    if (bytes > spec.budget.perImage) {
      problems.push(`${rel} is ${bytes} bytes, over ${spec.budget.perImage}`);
    }
    const viewport = { ...spec.viewport, ...(shot.viewport ?? {}) };
    const want = {
      width: viewport.width * viewport.deviceScaleFactor,
      height: viewport.height * viewport.deviceScaleFactor,
    };
    const got = pngSize(file);
    if (!got) problems.push(`${rel} is not a PNG`);
    else if (got.width !== want.width || got.height !== want.height) {
      problems.push(
        `${rel} is ${got.width}x${got.height}, not ${want.width}x${want.height}`,
      );
    }
    const recorded = lock?.[name]?.[shot.file];
    if (lock === null) {
      // Said once, below.
    } else if (!recorded) {
      problems.push(
        `${rel} has no entry in ci/web-routes/${LOCK_FILE}: run just example-screenshots ${name}`,
      );
    } else {
      if (recorded.spec !== specHash(spec, name, shot)) {
        problems.push(
          `${rel}: spec changed since the image was made: run just example-screenshots ${name}`,
        );
      }
      if (recorded.png !== sha256(readFileSync(file))) {
        problems.push(
          `${rel}: image changed since the lock recorded it (its bytes are not the ones just example-screenshots wrote): run just example-screenshots ${name}`,
        );
      }
    }
    const link = `![${shot.alt}](../../${rel})`;
    if (readme !== null && !readme.includes(link)) {
      problems.push(`examples/${name}/README.md does not show ${link}`);
    }
    if (
      !entry.urls.some(
        (u) => u.path === shot.path && u.expect === shot.expect && !u.known,
      )
    ) {
      problems.push(
        `${name}: the shot ${shot.file} (${shot.path}, "${shot.expect}") is not one of its urls`,
      );
    }
  }
}
for (const dir of existsSync(images) ? readdirSync(images) : []) {
  if (!(dir in spec.examples)) {
    problems.push(
      `docs/images/examples/${dir} is no example of examples.json: remove it`,
    );
  }
}
if (lock === null) {
  problems.push(
    `ci/web-routes/${LOCK_FILE} does not exist: run just example-screenshots`,
  );
} else {
  for (const [name, files] of Object.entries(lock)) {
    const shots = spec.examples[name]?.shots ?? [];
    if (!(name in spec.examples)) {
      problems.push(
        `ci/web-routes/${LOCK_FILE} has an entry for ${name}, which is no example of examples.json: remove it`,
      );
      continue;
    }
    for (const file of Object.keys(files)) {
      if (!shots.some((s) => s.file === file)) {
        problems.push(
          `ci/web-routes/${LOCK_FILE} has an entry for ${name}/${file}, which is no shot of examples.json: remove it`,
        );
      }
    }
  }
}
if (total > spec.budget.total) {
  problems.push(
    `docs/images/examples/ holds ${total} bytes, over ${spec.budget.total}`,
  );
}
if (problems.length > 0) {
  console.error(`example-images: ${problems.length} problem(s)\n`);
  for (const p of problems) console.error(`  ✗ ${p}`);
  process.exit(1);
}
console.log(
  `example-images: ${count} screenshots, ${total} bytes, all shown, within budget and as just example-screenshots made them`,
);
