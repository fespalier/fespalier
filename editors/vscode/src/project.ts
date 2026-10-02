// Reads what the extension needs from a project: where the app folder is, and whether a saved
// file is inside it. No `vscode` import (unit-tested).

export const DEFAULT_APP_DIR = 'lib/app';

/** `./lib\app/` -> `lib/app`. */
export function normalizeDir(dir: string): string {
  let d = dir.trim().replace(/\\/g, '/');
  while (d.startsWith('./')) {
    d = d.slice(2);
  }
  return d.replace(/\/+$/, '');
}

function stripComment(value: string): string {
  const v = value.trim();
  if (v.startsWith('"') || v.startsWith("'")) {
    const quote = v[0];
    const end = v.indexOf(quote, 1);
    return end === -1 ? v.slice(1) : v.slice(1, end);
  }
  const hash = v.search(/\s#/);
  return (hash === -1 ? v : v.slice(0, hash)).trim();
}

/**
 * `fespalier: app_dir:` from the text of a pubspec.yaml, or `lib/app`. A small line reader,
 * not a YAML parser: it only looks inside the top-level `fespalier:` mapping.
 */
export function appDirFromPubspec(pubspec: string): string {
  let inSection = false;
  for (const line of pubspec.split(/\r?\n/)) {
    if (/^fespalier:\s*(#.*)?$/.test(line)) {
      inSection = true;
      continue;
    }
    if (!inSection) {
      continue;
    }
    if (/^\S/.test(line) && !line.startsWith('#')) {
      break; // next top-level key
    }
    const m = /^\s+app_dir:\s*(.*)$/.exec(line);
    if (m) {
      const dir = normalizeDir(stripComment(m[1]));
      return dir === '' ? DEFAULT_APP_DIR : dir;
    }
  }
  return DEFAULT_APP_DIR;
}

/** Whether `relPath` (relative to the project root) is the app folder or below it. */
export function isUnderAppDir(relPath: string, appDir: string): boolean {
  const p = normalizeDir(relPath);
  const dir = normalizeDir(appDir);
  return p === dir || p.startsWith(dir + '/');
}

/**
 * Whether saving `relPath` (relative to the project root) can change what `fsp check` finds:
 * `pubspec.yaml` (it can move the app folder), anything under the app folder (the route tree),
 * or a Dart file anywhere under `lib/` that `fsp` did not generate (the string paths it checks,
 * since fespalier 0.7.0).
 */
export function affectsCheck(relPath: string, appDir: string): boolean {
  const p = normalizeDir(relPath);
  return (
    p === 'pubspec.yaml' ||
    isUnderAppDir(p, appDir) ||
    (p.startsWith('lib/') && p.endsWith('.dart') && !p.endsWith('.g.dart'))
  );
}
