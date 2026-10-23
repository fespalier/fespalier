// A stand-in for the `vscode` module, so the task provider (which builds vscode.Task objects) runs
// under `node --test`. Call `installFakeVscode()` before the first `require` of a module that
// imports `vscode`; node runs each test file in its own process, so the hook stays in this file.

import Module from 'node:module';

export interface FakeFolder {
  uri: { fsPath: string };
  name: string;
  index: number;
}

export interface FakeVscode {
  folders: FakeFolder[];
  warnings: string[];
  errors: string[];
}

export function folder(fsPath: string): FakeFolder {
  return { uri: { fsPath }, name: fsPath.split('/').pop() ?? fsPath, index: 0 };
}

export function installFakeVscode(folders: FakeFolder[]): FakeVscode {
  const state: FakeVscode = { folders, warnings: [], errors: [] };
  const within = (p: string, root: string) => p === root || p.startsWith(`${root}/`);
  const fake = {
    workspace: {
      getWorkspaceFolder: (uri: { fsPath: string }) => state.folders.find((f) => within(uri.fsPath, f.uri.fsPath)),
      get workspaceFolders() {
        return state.folders;
      },
    },
    window: {
      showWarningMessage: (m: string) => {
        state.warnings.push(m);
        return Promise.resolve(undefined);
      },
      showErrorMessage: (m: string) => {
        state.errors.push(m);
        return Promise.resolve(undefined);
      },
    },
    Uri: { file: (fsPath: string) => ({ fsPath }) },
    Task: class {
      detail?: string;
      presentationOptions?: unknown;
      constructor(
        public definition: unknown,
        public scope: unknown,
        public name: string,
        public source: string,
        public execution: unknown,
        public problemMatchers: unknown,
      ) {}
    },
    ProcessExecution: class {
      constructor(
        public process: string,
        public args: string[],
        public options: unknown,
      ) {}
    },
    ShellExecution: class {
      constructor(
        public commandLine: string,
        public args: string[],
        public options: unknown,
      ) {}
    },
    TaskRevealKind: { Always: 1, Silent: 2, Never: 3 },
    TaskPanelKind: { Shared: 1, Dedicated: 2, New: 3 },
  };
  const hook = Module as unknown as { _load: (request: string, ...rest: unknown[]) => unknown };
  const load = hook._load;
  hook._load = function (this: unknown, request: string, ...rest: unknown[]) {
    return request === 'vscode' ? fake : load.call(this, request, ...rest);
  };
  return state;
}
