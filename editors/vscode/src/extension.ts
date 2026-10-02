import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';

import { countBySeverity, groupByFile, parseFindings, toRange } from './diagnostics';
import { affectsCheck, appDirFromPubspec } from './project';
import { fspOnPath, invocation, run, RunnerSetting } from './runner';

interface Project {
  /** Absolute folder with the pubspec.yaml. */
  root: string;
  appDir: string;
}

let output: vscode.OutputChannel;
let status: vscode.StatusBarItem;
let diagnostics: vscode.DiagnosticCollection;
/** Files each project has diagnostics on, so a clean run clears them. */
const published = new Map<string, Set<string>>();
/** One run at a time per project, and a burst of saves collapses into one run. */
const timers = new Map<string, NodeJS.Timeout>();
const running = new Map<string, Promise<void>>();
const totals = new Map<string, { errors: number; warnings: number; failed: boolean }>();
let fspAvailable: boolean | undefined;

function settings() {
  const c = vscode.workspace.getConfiguration('fespalier');
  return {
    runner: c.get<RunnerSetting>('runner', 'auto'),
    fspPath: c.get<string>('fspPath', 'fsp'),
    checkOnSave: c.get<boolean>('checkOnSave', true),
  };
}

function readProject(root: string): Project | undefined {
  try {
    const text = fs.readFileSync(path.join(root, 'pubspec.yaml'), 'utf8');
    return { root, appDir: appDirFromPubspec(text) };
  } catch {
    return undefined;
  }
}

/** The nearest folder above `file` (up to its workspace folder) that has a pubspec.yaml. */
function projectOf(file: vscode.Uri): Project | undefined {
  const ws = vscode.workspace.getWorkspaceFolder(file);
  if (!ws) {
    return undefined;
  }
  let dir = path.dirname(file.fsPath);
  for (;;) {
    if (fs.existsSync(path.join(dir, 'pubspec.yaml'))) {
      return readProject(dir);
    }
    if (dir === ws.uri.fsPath || path.dirname(dir) === dir) {
      return undefined;
    }
    dir = path.dirname(dir);
  }
}

/** Projects that use fespalier: a pubspec.yaml that lists it or has a `fespalier:` section. */
async function findProjects(): Promise<Project[]> {
  const files = await vscode.workspace.findFiles(
    '**/pubspec.yaml',
    '**/{node_modules,.dart_tool,build,.git,ephemeral}/**',
    100,
  );
  const projects: Project[] = [];
  for (const f of files) {
    try {
      const text = fs.readFileSync(f.fsPath, 'utf8');
      if (/^\s*fespalier:/m.test(text)) {
        projects.push({ root: path.dirname(f.fsPath), appDir: appDirFromPubspec(text) });
      }
    } catch {
      // unreadable pubspec: skip
    }
  }
  return projects;
}

function refreshStatus() {
  let errors = 0;
  let warnings = 0;
  let failed = false;
  for (const t of totals.values()) {
    errors += t.errors;
    warnings += t.warnings;
    failed ||= t.failed;
  }
  if (totals.size === 0) {
    status.hide();
    return;
  }
  if (failed) {
    status.text = '$(warning) fespalier: failed';
    status.tooltip = 'fespalier could not run; see the fespalier output. Click to check again.';
  } else if (errors > 0) {
    status.text = `$(error) fespalier: ${errors} error${errors === 1 ? '' : 's'}`;
    status.tooltip = 'Click to check again';
  } else if (warnings > 0) {
    status.text = `$(warning) fespalier: ${warnings} warning${warnings === 1 ? '' : 's'}`;
    status.tooltip = 'Click to check again';
  } else {
    status.text = '$(check) fespalier';
    status.tooltip = 'No fespalier problems. Click to check again.';
  }
  status.show();
}

async function execute(project: Project, sub: 'check' | 'gen'): Promise<void> {
  const s = settings();
  if (s.runner === 'auto' && fspAvailable === undefined) {
    fspAvailable = await fspOnPath(s.fspPath, project.root);
  }
  const inv = invocation(s.runner, s.fspPath, fspAvailable ?? false, sub, project.root);
  status.text = '$(sync~spin) fespalier';
  status.show();
  const r = await run(inv, project.root);
  const { findings, ignored } = parseFindings(r.stdout);

  // Replace this project's diagnostics with the new ones.
  const previous = published.get(project.root) ?? new Set<string>();
  const now = new Set<string>();
  for (const [file, list] of groupByFile(findings)) {
    const uri = vscode.Uri.file(path.join(project.root, file));
    const ds = list.map((f) => {
      const r0 = toRange(f);
      const d = new vscode.Diagnostic(
        new vscode.Range(r0.startLine, r0.startCharacter, r0.endLine, r0.endCharacter),
        f.message,
        f.severity === 'error' ? vscode.DiagnosticSeverity.Error : vscode.DiagnosticSeverity.Warning,
      );
      d.source = 'fespalier';
      return d;
    });
    diagnostics.set(uri, ds);
    now.add(uri.toString());
  }
  for (const key of previous) {
    if (!now.has(key)) {
      diagnostics.delete(vscode.Uri.parse(key));
    }
  }
  published.set(project.root, now);

  // A non-zero exit with no error diagnostics means fsp itself failed (no app folder, bad pubspec).
  const counts = countBySeverity(findings);
  const failed = r.spawnError !== undefined || (r.code !== 0 && counts.errors === 0);
  totals.set(project.root, { ...counts, failed });
  refreshStatus();

  output.appendLine(`$ ${inv.command} ${inv.args.join(' ')}`);
  for (const line of ignored) {
    output.appendLine(line);
  }
  if (r.stderr.trim() !== '') {
    output.appendLine(r.stderr.trimEnd());
  }
  if (r.spawnError !== undefined) {
    output.appendLine(r.spawnError);
    const hint =
      inv.command === 'dart'
        ? 'Install the Dart SDK, or install fsp (see the fespalier README).'
        : 'Install fsp, set fespalier.fspPath, or set fespalier.runner to "dart".';
    void vscode.window.showErrorMessage(`fespalier: could not run ${inv.command}. ${hint}`);
  } else if (sub === 'gen') {
    if (r.code === 0) {
      void vscode.window.setStatusBarMessage(`fespalier: ${lastLine(r.stderr) || 'generated'}`, 5000);
    } else {
      void vscode.window
        .showErrorMessage('fespalier: gen failed. See the Problems panel.', 'Show output')
        .then((pick) => pick && output.show(true));
    }
  }
}

function lastLine(text: string): string {
  const lines = text.trim().split(/\r?\n/);
  return lines[lines.length - 1] ?? '';
}

/** Runs `sub` for the project unless one is running; a request during a run reruns after it. */
function schedule(project: Project, sub: 'check' | 'gen', delayMs = 150): Promise<void> {
  return new Promise((resolve) => {
    clearTimeout(timers.get(project.root));
    timers.set(
      project.root,
      setTimeout(async () => {
        timers.delete(project.root);
        await running.get(project.root);
        const p = execute(project, sub).catch((e) => output.appendLine(String(e)));
        running.set(project.root, p);
        await p;
        if (running.get(project.root) === p) {
          running.delete(project.root);
        }
        resolve();
      }, delayMs),
    );
  });
}

async function pickProject(): Promise<Project | undefined> {
  const active = vscode.window.activeTextEditor?.document.uri;
  if (active) {
    const p = projectOf(active);
    if (p) {
      return p;
    }
  }
  const all = await findProjects();
  if (all.length <= 1) {
    return all[0];
  }
  const pick = await vscode.window.showQuickPick(
    all.map((p) => ({ label: path.basename(p.root), description: p.root, project: p })),
    { placeHolder: 'Which project?' },
  );
  return pick?.project;
}

async function command(sub: 'check' | 'gen') {
  const project = await pickProject();
  if (!project) {
    void vscode.window.showInformationMessage('fespalier: no project with a fespalier: section or dependency found.');
    return;
  }
  if (sub === 'gen') {
    // Don't generate from stale files.
    await vscode.workspace.saveAll(false);
  }
  await schedule(project, sub, 0);
}

export function activate(context: vscode.ExtensionContext) {
  output = vscode.window.createOutputChannel('fespalier');
  diagnostics = vscode.languages.createDiagnosticCollection('fespalier');
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 0);
  status.name = 'fespalier';
  status.command = 'fespalier.check';
  context.subscriptions.push(output, diagnostics, status);

  context.subscriptions.push(
    vscode.commands.registerCommand('fespalier.generate', () => command('gen')),
    vscode.commands.registerCommand('fespalier.check', () => command('check')),
    vscode.workspace.onDidSaveTextDocument((doc) => {
      if (!settings().checkOnSave) {
        return;
      }
      const project = projectOf(doc.uri);
      if (!project) {
        return;
      }
      const rel = path.relative(project.root, doc.uri.fsPath).split(path.sep).join('/');
      // pubspec.yaml can move the app folder; anything under it can change the route table; a
      // Dart file elsewhere under lib/ can hold a string path that matches no route.
      if (affectsCheck(rel, project.appDir)) {
        void schedule(project, 'check');
      }
    }),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('fespalier')) {
        fspAvailable = undefined;
      }
    }),
  );

  // Check every fespalier project once, so problems show before the first save.
  void findProjects().then((projects) => {
    if (settings().checkOnSave) {
      for (const p of projects) {
        void schedule(p, 'check', 0);
      }
    }
  });
}

export function deactivate() {
  for (const t of timers.values()) {
    clearTimeout(t);
  }
}
