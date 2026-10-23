// The `fespalier` task type: each task of `fespalier: tasks:` in a project's pubspec.yaml, as
// `fsp run --json` lists it, as a VS Code task (Terminal > Run Task > fespalier).

import * as path from 'node:path';
import * as vscode from 'vscode';

import { Invocation, needsShell, RunResult } from './runner';
import {
  FespalierTaskDefinition,
  OLD_FSP_TASKS,
  parseTaskList,
  readDefinition,
  TaskEntry,
  taskArgs,
  taskLabel,
  taskListFailure,
} from './tasks';

export const TASK_TYPE = 'fespalier';

export interface TaskHost {
  /** The projects that use fespalier (the same search as the diagnostics). */
  findProjects(): Promise<{ root: string }[]>;
  /** `fsp` or `dart run fespalier` with these args, as the settings say. */
  command(args: string[], cwd: string): Promise<Invocation>;
  /** Runs it (the runner's `run`). */
  run(inv: Invocation, cwd: string): Promise<RunResult>;
  /** Whether `<root>/pubspec.yaml` exists. */
  hasPubspec(root: string): boolean;
  log(line: string): void;
}

export class FespalierTaskProvider implements vscode.TaskProvider {
  /** Each project's list, kept only while it is a success: a failed one is asked for again. */
  private readonly lists = new Map<string, Promise<TaskEntry[] | undefined>>();
  /** Warnings shown: `<root>\0<reason>` for a project's own, `\0<reason>` for one every project shares. */
  private readonly warned = new Set<string>();
  private readonly refused = new Set<string>();

  constructor(private readonly host: TaskHost) {}

  /** pubspec.yaml or the settings changed: list again next time. */
  invalidate(): void {
    this.lists.clear();
  }

  async provideTasks(): Promise<vscode.Task[]> {
    const projects = await this.host.findProjects();
    const roots = new Set(projects.map((p) => p.root));
    for (const root of [...this.lists.keys()]) {
      if (!roots.has(root)) {
        this.lists.delete(root);
      }
    }
    // Every project's tasks, listed in parallel, in the order of the projects.
    const lists = await Promise.all(projects.map((p) => this.listOf(p.root)));
    const out: vscode.Task[] = [];
    for (const [i, entries] of lists.entries()) {
      out.push(...(await this.tasksOf(projects[i].root, entries ?? [], projects)));
    }
    return out;
  }

  resolveTask(task: vscode.Task): Promise<vscode.Task | undefined> | undefined {
    const def = readDefinition(task.definition);
    if ('error' in def) {
      return this.refuse(def.error);
    }
    const folder = typeof task.scope === 'object' ? task.scope : vscode.workspace.workspaceFolders?.[0];
    if (!folder) {
      return this.refuse('open a folder with a pubspec.yaml to run a task');
    }
    const root = path.join(folder.uri.fsPath, def.path ?? '');
    if (!this.host.hasPubspec(root)) {
      // Without this fsp would walk up from `root` to any pubspec.yaml above it.
      return this.refuse(
        `there is no pubspec.yaml in ${root}: set "path" to the project's folder, relative to the workspace folder`,
      );
    }
    const args = taskArgs(def);
    if (!Array.isArray(args)) {
      return this.refuse(args.error);
    }
    return this.host
      .command(args, root)
      .then((inv) => new vscode.Task(task.definition, folder, task.name, TASK_TYPE, execution(inv, root), []));
  }

  /** Says why a task can't run, once for each reason (VS Code resolves tasks.json entries often). */
  private refuse(message: string): undefined {
    const text = `fespalier: ${message}`;
    this.host.log(text);
    if (!this.refused.has(text)) {
      this.refused.add(text);
      void vscode.window.showErrorMessage(text);
    }
    return undefined;
  }

  private listOf(root: string): Promise<TaskEntry[] | undefined> {
    let list = this.lists.get(root);
    if (!list) {
      const made = this.fetch(root);
      list = made;
      this.lists.set(root, made);
      void made.then((entries) => {
        // A failure is not kept (the user fixes it, say `fsp upgrade`, and asks again); neither is
        // an answer that arrives after `invalidate()`.
        if (entries === undefined && this.lists.get(root) === made) {
          this.lists.delete(root);
        }
      });
    }
    return list;
  }

  /** `fsp run --json` in one project: its tasks, or undefined after a failure (told once). */
  private async fetch(root: string): Promise<TaskEntry[] | undefined> {
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(root));
    if (!folder) {
      return [];
    }
    const rel = relativeTo(folder, root);
    let listing: Invocation | undefined;
    let why: string;
    let fspWide: boolean;
    try {
      listing = await this.host.command(['run', '--json'], root);
      const r = await this.host.run(listing, root);
      if (r.spawnError === undefined && r.code === 0) {
        this.forgetWarnings(root);
        return parseTaskList(r.stdout).tasks;
      }
      why = taskListFailure(r.code, r.stderr, r.spawnError);
      // What no project can fix on its own: no fsp, or one older than 0.22.0.
      fspWide = r.spawnError !== undefined || why === OLD_FSP_TASKS;
    } catch (e) {
      why = String(e);
      fspWide = false;
    }
    this.host.log(`${listing ? `$ ${listing.command} ${listing.args.join(' ')}\n` : ''}${why}`);
    const key = `${fspWide ? '' : root}\0${why}`;
    if (!this.warned.has(key)) {
      this.warned.add(key);
      const where = fspWide ? '' : ` of ${rel || folder.name}`;
      void vscode.window.showWarningMessage(`fespalier: could not list the tasks${where}: ${why}`);
    }
    return undefined;
  }

  /** A listing worked: the next failure of this project (or of fsp itself) is told again. */
  private forgetWarnings(root: string): void {
    for (const key of [...this.warned]) {
      if (key.startsWith('\0') || key.startsWith(`${root}\0`)) {
        this.warned.delete(key);
      }
    }
  }

  private async tasksOf(root: string, entries: TaskEntry[], projects: { root: string }[]): Promise<vscode.Task[]> {
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(root));
    if (!folder) {
      return [];
    }
    const several =
      projects.filter((q) => vscode.workspace.getWorkspaceFolder(vscode.Uri.file(q.root)) === folder).length > 1;
    const rel = relativeTo(folder, root);
    const out: vscode.Task[] = [];
    for (const entry of entries) {
      if (entry.needsTarget) {
        continue; // `fsp build <target>`: a tasks.json entry with a "target" runs it
      }
      const def: FespalierTaskDefinition & vscode.TaskDefinition = { type: TASK_TYPE, task: entry.name };
      if (rel !== '') {
        def.path = rel;
      }
      const inv = await this.host.command(entry.args, root);
      const task = new vscode.Task(def, folder, taskLabel(entry.name, rel, several), TASK_TYPE, execution(inv, root), []);
      task.detail = entry.run;
      task.presentationOptions = {
        reveal: vscode.TaskRevealKind.Always,
        panel: vscode.TaskPanelKind.Dedicated,
        focus: entry.name === 'dev',
      };
      out.push(task);
    }
    return out;
  }
}

function relativeTo(folder: vscode.WorkspaceFolder, root: string): string {
  return path.relative(folder.uri.fsPath, root).split(path.sep).join('/');
}

function execution(inv: Invocation, cwd: string): vscode.ProcessExecution | vscode.ShellExecution {
  return needsShell(inv, process.platform)
    ? new vscode.ShellExecution(inv.command, inv.args, { cwd })
    : new vscode.ProcessExecution(inv.command, inv.args, { cwd });
}
