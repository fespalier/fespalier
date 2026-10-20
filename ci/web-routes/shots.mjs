// What examples.mjs and example-images.mjs share about the examples' screenshots. No dependency, no
// browser, no file access: the two scripts do their own.
//
// `settle(page)` is how a screen is known to be still. The rest is what example-shots.lock.json
// records about each shot, written by examples.mjs when it makes the images and checked by
// example-images.mjs. A shot's entry has two hashes:
//   - `spec`: of everything in examples.json that decides the pixels, apart from the app itself: the
//     shot's path and `expect`, where the URL ends (`at`), the viewport, the fixed time and the
//     example's `--dart-define`s. Change one of them and the image is stale until
//     `just example-screenshots <example>` makes it again;
//   - `png`: of the image's bytes, so an image that was edited or replaced by hand is noticed.
import { createHash } from "node:crypto";

/** The lock's file name, next to the spec (not under docs/images/, which holds images only). */
export const LOCK_FILE = "example-shots.lock.json";

/** `value` as JSON with the keys of every object sorted, so equal values have equal text. */
const canonical = (value) => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const keys = Object.keys(value).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
};

/** The hex SHA-256 of `bytes` (a string or a Buffer). */
export const sha256 = (bytes) =>
  createHash("sha256").update(bytes).digest("hex");

/** Everything that decides one shot's pixels in `spec`, besides the app: what the spec hash covers. */
export const shotSpec = (spec, name, shot) => {
  const entry = spec.examples[name];
  const url = entry.urls.find(
    (u) => u.path === shot.path && u.expect === shot.expect,
  );
  return {
    path: shot.path,
    expect: shot.expect,
    at: url?.at ?? null,
    viewport: { ...spec.viewport, ...(shot.viewport ?? {}) },
    time: spec.time,
    defines: entry.defines ?? {},
  };
};

/** The lock's `spec` hash of a shot. */
export const specHash = (spec, name, shot) =>
  sha256(canonical(shotSpec(spec, name, shot)));

// A screen is still when SETTLE_RUN captures in a row are the same bytes, no two of them more than
// SETTLE_GAP ms apart, over more than SETTLE_SPAN ms. A text caret shows for 500 ms and hides for
// 500 ms: captures less than 500 ms apart that span more than 500 ms cannot all fall in one of those
// phases (two captures could, 300 ms apart), so a blinking caret changes the bytes.
export const SETTLE_RUN = 3;
export const SETTLE_GAP = 500;
export const SETTLE_SPAN = 500;
// The pause between captures; a capture itself takes about as long again.
const SETTLE_WAIT = 150;
// How long a screenshot waits for its screen to be still.
export const SETTLE_MS = 10000;

/**
 * Captures `page` until it is still (see SETTLE_RUN), for at most SETTLE_MS. Returns the last
 * capture, or null when it never was. A capture is dated just before it is asked for: the browser
 * takes the frame at the start of the call, and encodes the PNG after.
 */
export const settle = async (page) => {
  const start = performance.now();
  let run = [];
  while (performance.now() - start < SETTLE_MS) {
    const at = performance.now();
    const png = await page.screenshot();
    const last = run.at(-1);
    if (last && (!png.equals(last.png) || at - last.at >= SETTLE_GAP)) run = [];
    run.push({ png, at });
    if (run.length >= SETTLE_RUN && at - run[0].at > SETTLE_SPAN) return png;
    await page.waitForTimeout(SETTLE_WAIT);
  }
  return null;
};
