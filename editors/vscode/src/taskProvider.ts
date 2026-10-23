// The `fespalier` task type: each task of `fespalier: tasks:` in a project's pubspec.yaml, as
// `fsp run --json` lists it, as a VS Code task (Terminal > Run Task > fespalier).

import * as path from 'node:path';
import * as vscode from 'vscode';

import { Invocation, needsShell, run } from './runner';
import { FespalierTaskDefinition, parseTaskList, taskArgs, taskLabel, taskListFailure } from './tasks';

export const TASK_TYPE = 'fespalier';

export interface TaskHost {
  /** The projects that use fespalier (the same search as the diagnostics). */
  findProjects(): Promise<{ root: string }[]>;
  /** `fsp` or `dart run fespalier` with these args, as the settings say. */
  command(args: string[], cwd: string): Promise<Invocation>;
  log(line: string): void;
}

export class FespalierTaskProvider implements vscode.TaskProvider {
  private cached: Promise<vscode.Task[]> | undefined;
  private readonly warned = new Set<string>();

  constructor(private readonly host: TaskHost) {}

  /** pubspec.yaml or the settings changed: list again next time. */
  invalidate(): void {
    this.cached = undefined;
  }

  provideTasks(): Promise<vscode.Task[]> {
    this.cached ??= this.list();
    return this.cached;
  }

  resolveTask(task: vscode.Task): Promise<vscode.Task | undefined> | undefined {
    const def = task.definition as vscode.TaskDefinition & FespalierTaskDefinition;
    if (typeof def.task !== 'string' || def.task === '') {
      return undefined;
    }
    const folder = typeof task.scope === 'object' ? task.scope : vscode.workspace.workspaceFolders?.[0];
    if (!folder) {
      return undefined;
    }
    const root = path.join(folder.uri.fsPath, def.path ?? '');
    const args = taskArgs(def);
    if (!Array.isArray(args)) {
      this.host.log(`fespalier: ${args.error}`);
      return undefined;
    }
    return this.host.command(args, root).then(
      (inv) => new vscode.Task(def, folder, task.name, TASK_TYPE, execution(inv, root), []),
    );
  }

  /** Every project's tasks, listed in parallel, in the order of the projects. */
  private async list(): Promise<vscode.Task[]> {
    const projects = await this.host.findProjects();
    const lists = await Promise.all(projects.map((p) => this.listProject(p.root, projects)));
    return lists.flat();
  }

  private async listProject(root: string, projects: { root: string }[]): Promise<vscode.Task[]> {
    const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(root));
    if (!folder) {
      return [];
    }
    const several =
      projects.filter((q) => vscode.workspace.getWorkspaceFolder(vscode.Uri.file(q.root)) === folder).length > 1;
    const rel = path.relative(folder.uri.fsPath, root).split(path.sep).join('/');
    const listing = await this.host.command(['run', '--json'], root);
    const r = await run(listing, root);
    if (r.spawnError !== undefined || r.code !== 0) {
      const why = taskListFailure(r.code, r.stderr, r.spawnError);
      this.host.log(`$ ${listing.command} ${listing.args.join(' ')}\n${why}`);
      if (!this.warned.has(root + why)) {
        this.warned.add(root + why);
        void vscode.window.showWarningMessage(`fespalier: could not list the tasks of ${rel || folder.name}: ${why}`);
      }
      return [];
    }
    const out: vscode.Task[] = [];
    for (const entry of parseTaskList(r.stdout).tasks) {
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

function execution(inv: Invocation, cwd: string): vscode.ProcessExecution | vscode.ShellExecution {
  return needsShell(inv, process.platform)
    ? new vscode.ShellExecution(inv.command, inv.args, { cwd })
    : new vscode.ProcessExecution(inv.command, inv.args, { cwd });
}
