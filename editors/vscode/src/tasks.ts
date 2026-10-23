// `fsp run --json` (since fespalier 0.22.0) prints one JSON object per task on stdout:
//   {"name": "codegen", "args": ["run", "codegen"], "needs_target": false,
//    "run": "dart run build_runner build", "declared": true}
// `dev` and `build` come first, always (`fsp dev`, `fsp build <target>`). See `json_lines` in
// cli/src/tasks.rs. Nothing here imports `vscode` (unit-tested).

export interface TaskEntry {
  name: string;
  /** What to give fsp to run it: `["dev"]`, `["build"]`, `["run", "codegen"]`. */
  args: string[];
  /** `build`: a target (apk, web, ...) goes right after `args`. */
  needsTarget: boolean;
  /** The main command, as `fsp run <name> --dry-run` shows it. */
  run: string;
  /** Whether pubspec.yaml has the task (false for the default `dev` and `build`). */
  declared: boolean;
}

/** One line of `fsp run --json`, or undefined when it is not a task. */
export function parseTaskEntry(line: string): TaskEntry | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return undefined;
  }
  const o = raw as Record<string, unknown>;
  if (typeof o.name !== 'string' || o.name === '' || typeof o.run !== 'string') {
    return undefined;
  }
  if (!Array.isArray(o.args) || o.args.length === 0 || !o.args.every((a) => typeof a === 'string')) {
    return undefined;
  }
  return {
    name: o.name,
    args: o.args as string[],
    needsTarget: o.needs_target === true,
    run: o.run,
    declared: o.declared === true,
  };
}

export function parseTaskList(stdout: string): { tasks: TaskEntry[]; ignored: string[] } {
  const tasks: TaskEntry[] = [];
  const ignored: string[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    if (line.trim() === '') {
      continue;
    }
    const t = parseTaskEntry(line);
    if (t) {
      tasks.push(t);
    } else {
      ignored.push(line);
    }
  }
  return { tasks, ignored };
}

/** What a `"type": "fespalier"` task in tasks.json says. */
export interface FespalierTaskDefinition {
  task: string;
  path?: string;
  target?: string;
  args?: string[];
}

/**
 * The fsp arguments that run a task definition, or a reason it can't run: `dev` is `fsp dev`,
 * `build` is `fsp build <target>`, any other name `fsp run <name>`; `args` go after `--`.
 */
export function taskArgs(def: FespalierTaskDefinition): string[] | { error: string } {
  const extra = def.args && def.args.length > 0 ? ['--', ...def.args] : [];
  if (def.task === 'dev') {
    return ['dev', ...extra];
  }
  if (def.task === 'build') {
    const target = (def.target ?? '').trim();
    if (target === '') {
      return { error: 'the build task needs a "target": what flutter build builds (apk, web, ios, ...)' };
    }
    return ['build', target, ...extra];
  }
  return ['run', def.task, ...extra];
}

/** `codegen`, or `codegen - examples/shop` when the workspace folder has more than one project. */
export function taskLabel(name: string, relPath: string, several: boolean): string {
  return several ? `${name} - ${relPath === '' ? '.' : relPath}` : name;
}

/** Why `fsp run --json` gave no list, in one line. */
export function taskListFailure(code: number | null, stderr: string, spawnError?: string): string {
  if (spawnError !== undefined) {
    return spawnError;
  }
  if (/unexpected argument '--json'/.test(stderr)) {
    return 'this fsp cannot list tasks: `fsp run --json` needs fespalier 0.22.0 or later';
  }
  const lines = stderr.trim().split(/\r?\n/);
  const last = lines[lines.length - 1]?.trim() ?? '';
  return last !== '' ? last : `exited with code ${code}`;
}
