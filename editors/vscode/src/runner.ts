// Runs the generator. No `vscode` import (the command choice is unit-tested).

import { execFile } from 'node:child_process';

export type RunnerSetting = 'auto' | 'fsp' | 'dart';

export interface Invocation {
  command: string;
  args: string[];
}

/**
 * `fsp <sub> --json --project <dir>`, or `dart run fespalier <sub> --json --project <dir>`.
 * `auto` prefers fsp when it is on PATH (`fspAvailable`).
 */
export function invocation(
  runner: RunnerSetting,
  fspPath: string,
  fspAvailable: boolean,
  subcommand: 'check' | 'gen',
  projectDir: string,
): Invocation {
  return fspCommand(runner, fspPath, fspAvailable, [subcommand, '--json', '--project', projectDir]);
}

/** `fsp <args>`, or `dart run fespalier <args>`; `auto` prefers fsp when it is on PATH. */
export function fspCommand(runner: RunnerSetting, fspPath: string, fspAvailable: boolean, args: string[]): Invocation {
  const useFsp = runner === 'fsp' || (runner === 'auto' && fspAvailable);
  return useFsp ? { command: fspPath || 'fsp', args } : { command: 'dart', args: ['run', 'fespalier', ...args] };
}

/** On Windows `dart` is `dart.bat`, which only a shell starts; everything else runs with no shell. */
export function needsShell(inv: Invocation, platform: string): boolean {
  return platform === 'win32' && inv.command === 'dart';
}

export interface RunResult {
  /** Exit code; null when the process could not start or was killed. */
  code: number | null;
  stdout: string;
  stderr: string;
  /** Set when the process could not be started (`ENOENT`: not installed). */
  spawnError?: string;
}

export function run(inv: Invocation, cwd: string): Promise<RunResult> {
  return new Promise((resolve) => {
    execFile(
      inv.command,
      inv.args,
      // On Windows `dart` is `dart.bat`, which execFile only starts through a shell.
      { cwd, maxBuffer: 32 * 1024 * 1024, shell: needsShell(inv, process.platform) },
      (err, stdout, stderr) => {
        if (err && typeof (err as NodeJS.ErrnoException).code === 'string') {
          resolve({ code: null, stdout, stderr, spawnError: err.message });
        } else {
          const code = err ? ((err as { code?: number | null }).code ?? null) : 0;
          resolve({ code, stdout, stderr });
        }
      },
    );
  });
}

/** Whether `fsp --version` runs. */
export async function fspOnPath(fspPath: string, cwd: string): Promise<boolean> {
  const r = await run({ command: fspPath || 'fsp', args: ['--version'] }, cwd);
  return r.spawnError === undefined && r.code === 0;
}
