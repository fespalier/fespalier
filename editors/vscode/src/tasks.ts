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
  /** The main command, as the listing of `fsp run` shows it (`flutter run` for an undeclared `dev`). */
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
 * A `"type": "fespalier"` entry of tasks.json, checked: VS Code only warns about a value that does
 * not fit `taskDefinitions` (`"args": "--release"` would be spread letter by letter), so the types
 * are verified here, and the reason is the error.
 */
export function readDefinition(raw: unknown): FespalierTaskDefinition | { error: string } {
  if (typeof raw !== 'object' || raw === null) {
    return { error: 'the task has no definition' };
  }
  const o = raw as Record<string, unknown>;
  if (typeof o.task !== 'string' || o.task.trim() === '') {
    return { error: 'the "task" must be a name from `fespalier: tasks:`, or dev or build' };
  }
  const def: FespalierTaskDefinition = { task: o.task };
  for (const key of ['path', 'target'] as const) {
    const v = o[key];
    if (v === undefined) {
      continue;
    }
    if (typeof v !== 'string') {
      return { error: `"${key}" must be a string, got ${JSON.stringify(v)}` };
    }
    def[key] = v;
  }
  if (o.args !== undefined) {
    if (!Array.isArray(o.args) || !o.args.every((a) => typeof a === 'string')) {
      return { error: `"args" must be a list of strings, got ${JSON.stringify(o.args)}` };
    }
    def.args = o.args as string[];
  }
  return def;
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

/** What the plugins say when the `fsp` they run has no `run --json`. */
export const OLD_FSP_TASKS = 'this fsp cannot list tasks: `fsp run --json` needs fespalier 0.22.0 or later';

/**
 * Why `fsp run --json` gave no list, in one line: the old-`fsp` sentence, the `error:` line of a
 * clap message (its last line is only "For more information, try '--help'."), else the last line
 * (fsp's own errors are one line).
 */
export function taskListFailure(code: number | null, stderr: string, spawnError?: string): string {
  if (spawnError !== undefined) {
    return spawnError;
  }
  // `unexpected argument '--json'`: fsp 0.9 to 0.21; `unrecognized subcommand 'run'`: before 0.9.
  if (/unexpected argument '--json'|unrecognized subcommand 'run'/.test(stderr)) {
    return OLD_FSP_TASKS;
  }
  const lines = stderr
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l !== '');
  const line = lines.find((l) => l.startsWith('error:')) ?? lines[lines.length - 1] ?? '';
  return line !== '' ? line : `exited with code ${code}`;
}
