//! What `fsp watch` keeps from one regeneration to the next, so a save redoes only what it
//! changed. Three layers, from the cheapest to skip to the dearest:
//!
//! 1. **The result of the last run.** Everything after the scan (resolve, check, emit) is a
//!    function of the scanned tree, the files named below, and the configuration (which `watch`
//!    reads once), so
//!    a run that scans a tree equal to the last one's reuses the last run's diagnostics and
//!    generated code without resolving or rendering again. Equal means equal: the same
//!    folders, the same file names and byte-identical sources, and the same contents in the
//!    files outside the app folder that resolving read to find enum declarations
//!    ([`crate::enums::Libs`]), which are compared by content on every run. A file the
//!    generator doesn't read (a colocated widget in `lib/app/`) or a save that changed
//!    nothing is that case.
//! 2. **The formatted text.** `dart format` of the generated file takes seconds on a big app
//!    and its output depends only on its input, so the last unformatted text and what it
//!    formatted to are kept. A save that changes a page's `build` method changes the tree,
//!    but not the generated code, and doesn't run `dart` at all.
//! 3. **Parse results**, in [`crate::parse_cache`]: a changed tree parses only its changed files.
//!
//! What isn't kept, on purpose: the resolver and the emitter run again for a changed tree.
//! On the benchmark's 5,000-route app that is about 0.2 s, of which resolving is 30 ms, and
//! resolving one route reads the folders above it and changes shared state (names claimed,
//! query types settled), so a per-route cache would have to replay those effects for less
//! than it costs to keep. Nor is the folder walk (about 80 ms at 5,000 routes, reading the
//! files included) made incremental: a cache keyed on modification times would save less than
//! it risks (an edit within one timestamp tick, a file replaced by one of the same size and time).

use std::collections::HashMap;

use crate::diag::Diags;
use crate::enums::{Libs, Reads};
use crate::scan::Node;

/// What one scan → resolve → emit produced, before formatting.
pub struct Run {
    pub diags: Diags,
    pub routes: usize,
    /// `(path relative to the project, generated code)`: the output, then the manifest if it
    /// has its own file. Empty when there are errors.
    pub files: Vec<(String, String)>,
}

struct Last {
    tree: Node,
    /// The diagnostics of the scan itself (a folder that isn't a valid segment is reported and
    /// left out of the tree, so the tree alone doesn't tell two such scans apart).
    scan_diags: String,
    /// The files outside the app folder that resolving read (enum declarations) and what they held.
    reads: Reads,
    run: Run,
}

/// Layers 1 and 2 above, one field each so a run can hold one while it uses the other.
#[derive(Default)]
pub struct Session {
    pub last: LastRun,
    pub formats: Formats,
}

#[derive(Default)]
pub struct LastRun(Option<Last>);

impl LastRun {
    /// The last run's result, and the files it read, when it was made from this very tree and
    /// those files still read the same.
    pub fn reuse(&mut self, tree: &Node, scan_diags: &str, libs: &Libs) -> Option<(Run, Reads)> {
        let last = self.0.take()?;
        (last.tree == *tree && last.scan_diags == scan_diags && libs.unchanged_since(&last.reads)).then_some((last.run, last.reads))
    }

    /// Keeps `run`, made from `tree` and the files `reads` lists, for the next [`reuse`](LastRun::reuse).
    pub fn keep(&mut self, tree: Node, scan_diags: String, reads: Reads, run: Run) -> &Run {
        &self.0.insert(Last { tree, scan_diags, reads, run }).run
    }
}

/// Output path → (the code as emitted, what `dart format` made of it).
#[derive(Default)]
pub struct Formats(HashMap<String, (String, String)>);

impl Formats {
    /// `code` formatted by `format`, which is only called for code it hasn't formatted before.
    /// A run of `format` that warned (no `dart`) isn't kept, so the warning comes again.
    pub fn get(&mut self, path: &str, code: &str, format: impl FnOnce(&str) -> (String, Option<String>)) -> String {
        if let Some((raw, done)) = self.0.get(path) {
            if raw == code {
                return done.clone();
            }
        }
        let (done, warning) = format(code);
        match warning {
            Some(w) => eprintln!("{w}"),
            None => {
                self.0.insert(path.to_string(), (code.to_string(), done.clone()));
            }
        }
        done
    }
}
