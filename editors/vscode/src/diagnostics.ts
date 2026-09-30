// `fsp check --json` / `fsp gen --json` print one JSON object per line on stdout:
//   {"file": "lib/app/products/$id/page.dart", "line": 4, "column": 7,
//    "severity": "error" | "warning", "message": "..."}
// `file` is relative to the project root; `line` and `column` are 1-based and null when the
// problem isn't about a place in the file. (See json_line in cli/src/diag.rs.)
//
// Nothing here imports `vscode`, so it is unit-tested with a plain runner.

export type Severity = 'error' | 'warning';

export interface Finding {
  file: string;
  line: number | null;
  column: number | null;
  severity: Severity;
  message: string;
}

export interface Parsed {
  findings: Finding[];
  /** Lines that were not a diagnostic object (kept so the caller can show them). */
  ignored: string[];
}

function positive(v: unknown): number | null {
  return typeof v === 'number' && Number.isInteger(v) && v >= 1 ? v : null;
}

/** One line of `--json` output, or undefined when it isn't a diagnostic. */
export function parseFinding(line: string): Finding | undefined {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return undefined;
  }
  if (typeof raw !== 'object' || raw === null) {
    return undefined;
  }
  const o = raw as Record<string, unknown>;
  if (typeof o.file !== 'string' || typeof o.message !== 'string') {
    return undefined;
  }
  if (o.severity !== 'error' && o.severity !== 'warning') {
    return undefined;
  }
  return {
    file: o.file,
    line: positive(o.line),
    column: positive(o.column),
    severity: o.severity,
    message: o.message,
  };
}

export function parseFindings(stdout: string): Parsed {
  const findings: Finding[] = [];
  const ignored: string[] = [];
  for (const line of stdout.split(/\r?\n/)) {
    if (line.trim() === '') {
      continue;
    }
    const f = parseFinding(line);
    if (f) {
      findings.push(f);
    } else {
      ignored.push(line);
    }
  }
  return { findings, ignored };
}

export interface ZeroBasedRange {
  startLine: number;
  startCharacter: number;
  endLine: number;
  endCharacter: number;
}

/**
 * The range to underline: the reported position (0-based for VS Code), or the top of the file
 * when the diagnostic has no position. The width is left empty so the editor underlines the
 * word at that position.
 */
export function toRange(f: Finding): ZeroBasedRange {
  const line = f.line === null ? 0 : f.line - 1;
  const character = f.line === null || f.column === null ? 0 : f.column - 1;
  return { startLine: line, startCharacter: character, endLine: line, endCharacter: character };
}

/** Findings grouped by their (project-relative) file, in first-seen order. */
export function groupByFile(findings: Finding[]): Map<string, Finding[]> {
  const out = new Map<string, Finding[]>();
  for (const f of findings) {
    const list = out.get(f.file);
    if (list) {
      list.push(f);
    } else {
      out.set(f.file, [f]);
    }
  }
  return out;
}

export function countBySeverity(findings: Finding[]): { errors: number; warnings: number } {
  const errors = findings.filter((f) => f.severity === 'error').length;
  return { errors, warnings: findings.length - errors };
}
