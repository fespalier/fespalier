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

// What cmd.exe treats specially (http://www.robvanderwoude.com/escapechars.php).
const cmdMeta = /([()\][%!^"`<>&|;, *?])/g;

/**
 * The line `cmd.exe /d /s /c` runs for `inv`, where execFile with `shell: true` joins the command
 * and its arguments with spaces and quotes nothing: a project in `C:\Users\First Last` would be two
 * arguments, and a `&` in a folder name would start a command. Each argument is quoted as
 * `CommandLineToArgvW` reads it, then cmd's metacharacters are escaped with `^` twice, because
 * `dart.bat` hands `%*` to cmd once more (https://qntm.org/cmd, as cross-spawn does it).
 */
export function cmdLine(inv: Invocation): string {
  return [inv.command.replace(cmdMeta, '^$1'), ...inv.args.map(cmdArgument)].join(' ');
}

function cmdArgument(arg: string): string {
  // Backslashes before a quote are doubled and the quote escaped; backslashes before the closing
  // quote are doubled; every other backslash is literal.
  const quoted = `"${arg.replace(/(?=(\\+?)?)\1"/g, '$1$1\\"').replace(/(?=(\\+?)?)\1$/, '$1$1')}"`;
  return quoted.replace(cmdMeta, '^$1').replace(cmdMeta, '^$1');
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
  // On Windows `dart` is `dart.bat`, which execFile only starts through a shell: the line is
  // quoted here (cmdLine), since the shell quotes nothing.
  const shell = needsShell(inv, process.platform);
  return new Promise((resolve) => {
    execFile(
      shell ? cmdLine(inv) : inv.command,
      shell ? [] : inv.args,
      { cwd, maxBuffer: 32 * 1024 * 1024, shell },
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
