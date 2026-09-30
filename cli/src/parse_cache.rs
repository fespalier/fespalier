//! Parse cache for `fsp watch`: a save changes one file, so only that file is parsed again.
//!
//! The resolver calls [`parse`] for every Dart file of every route on each run. Outside
//! `watch` the cache is off and this is `dart::parse`. `watch` calls [`enable`] once and
//! [`finish_run`] after each regeneration. The key is the file's source text itself, so a hit
//! is exact: there is no hash to collide and no mtime to trust. Entries a run didn't touch
//! (deleted, renamed or edited files) are dropped by [`finish_run`], so the cache never
//! outgrows the app folder.
//!
//! [`prewarm`] parses the files a run is missing on all cores before the resolver asks for
//! them: a cold run of a big app is a third parsing, and each file parses on its own.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::thread;

use crate::dart::{self, Module};
use crate::scan::Node;

/// Fewer missing files than this are parsed as the resolver asks: starting threads costs more.
const PARALLEL_MIN: usize = 64;

struct Entry {
    module: Module,
    /// Whether the current run used this entry.
    used: bool,
    /// Parsed ahead by [`prewarm`] and not asked for yet: [`prewarm`] has already counted it
    /// as parsed, so its first use isn't a reuse.
    fresh: bool,
}

#[derive(Default)]
struct Cache {
    entries: HashMap<String, Entry>,
    /// Files parsed / served from the cache since the last [`finish_run`].
    parsed: usize,
    reused: usize,
}

thread_local! {
    static CACHE: RefCell<Option<Cache>> = const { RefCell::new(None) };
}

/// Turns the cache on for this thread (idempotent).
pub fn enable() {
    CACHE.with(|c| {
        c.borrow_mut().get_or_insert_with(Cache::default);
    });
}

/// Turns the cache off again and forgets what it held.
pub fn disable() {
    CACHE.with(|c| *c.borrow_mut() = None);
}

/// Returned by [`prewarm`]: drops the cache when [`prewarm`] was what turned it on, so a
/// one-off `gen` doesn't keep the sources of the whole app in a cache nobody reads again.
pub struct Prewarmed {
    turned_on: bool,
}

impl Drop for Prewarmed {
    fn drop(&mut self) {
        if self.turned_on {
            disable();
        }
    }
}

/// Parses, on every core, the sources of `tree` that the cache hasn't seen, so the resolver
/// finds them there. With the cache off (`gen`, `check`) it is on until the result is
/// dropped. A handful of files aren't worth threads and are left to [`parse`].
pub fn prewarm(tree: &Node) -> Prewarmed {
    let turned_on = CACHE.with(|c| c.borrow().is_none());
    enable();
    let mut srcs: Vec<&str> = vec![];
    fn collect<'t>(n: &'t Node, out: &mut Vec<&'t str>) {
        out.extend(n.files.values().map(String::as_str));
        n.children.iter().for_each(|c| collect(c, out));
    }
    collect(tree, &mut srcs);
    let missing: Vec<&str> = CACHE.with(|c| {
        let c = c.borrow();
        let cache = c.as_ref().expect("enabled above");
        let mut seen = HashSet::new();
        srcs.into_iter()
            .filter(|s| !cache.entries.contains_key(*s) && seen.insert(*s))
            .collect()
    });
    if missing.len() >= PARALLEL_MIN {
        let threads = thread::available_parallelism()
            .map_or(1, |n| n.get())
            .min(missing.len() / 16)
            .max(1);
        let per = missing.len().div_ceil(threads);
        let parsed: Vec<Vec<(&str, Module)>> = thread::scope(|scope| {
            let handles: Vec<_> = missing
                .chunks(per)
                .map(|chunk| {
                    scope.spawn(move || {
                        chunk
                            .iter()
                            .map(|s| (*s, dart::parse(s)))
                            .collect::<Vec<_>>()
                    })
                })
                .collect();
            handles
                .into_iter()
                .map(|h| h.join().expect("parsing panicked"))
                .collect()
        });
        CACHE.with(|c| {
            let mut c = c.borrow_mut();
            let cache = c.as_mut().expect("enabled above");
            for (src, module) in parsed.into_iter().flatten() {
                cache.parsed += 1;
                cache.entries.insert(
                    src.to_string(),
                    Entry {
                        module,
                        used: false,
                        fresh: true,
                    },
                );
            }
        });
    }
    Prewarmed { turned_on }
}

/// `dart::parse`, served from the cache when the cache is on and has seen this exact source.
pub fn parse(src: &str) -> Module {
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        let Some(cache) = c.as_mut() else {
            return dart::parse(src);
        };
        if let Some(e) = cache.entries.get_mut(src) {
            e.used = true;
            if !std::mem::take(&mut e.fresh) {
                cache.reused += 1;
            }
            return e.module.clone();
        }
        let module = dart::parse(src);
        cache.parsed += 1;
        cache.entries.insert(
            src.to_string(),
            Entry {
                module: module.clone(),
                used: true,
                fresh: false,
            },
        );
        module
    })
}

/// Ends a run: forgets sources the run didn't use and returns `(parsed, reused)` for it.
pub fn finish_run() -> (usize, usize) {
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        let Some(cache) = c.as_mut() else {
            return (0, 0);
        };
        cache.entries.retain(|_, e| std::mem::take(&mut e.used));
        (
            std::mem::take(&mut cache.parsed),
            std::mem::take(&mut cache.reused),
        )
    })
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::build;
    use crate::config::Config;

    const PAGE: &str = "class {N}Page extends StatelessWidget { const {N}Page({super.key}); }";

    #[test]
    fn a_hit_needs_the_exact_source_and_unused_entries_are_dropped() {
        enable();
        let a = "class A { const A(); }";
        let b = "class B { const B(); }";
        assert_eq!(parse(a).classes[0].name, "A");
        assert_eq!(parse(b).classes[0].name, "B");
        assert_eq!(finish_run(), (2, 0));
        // Run 2: A unchanged, B edited into C.
        assert_eq!(parse(a).classes[0].name, "A");
        assert_eq!(parse("class C { const C(); }").classes[0].name, "C");
        assert_eq!(finish_run(), (1, 1));
        // B was not used in run 2, so it is parsed again.
        assert_eq!(parse(b).classes[0].name, "B");
        assert_eq!(finish_run(), (1, 0));
        CACHE.with(|c| *c.borrow_mut() = None);
    }

    #[test]
    fn prewarming_parses_on_several_threads_what_the_resolver_would_and_counts_it_once() {
        let dir = synthetic_app(200);
        let tree = crate::scan::scan(
            &dir.path().join("lib/app"),
            &mut crate::diag::Diags::default(),
        )
        .unwrap();
        // 200 pages (one text but for the class name) and 40 data files that differ by their string.
        disable();
        {
            let _warm = prewarm(&tree);
            assert_eq!(finish_run_counts(), (240, 0));
            // The resolver's own calls: every one is served, the first use of each isn't a reuse.
            let mut sources = vec![];
            fn collect(n: &crate::scan::Node, out: &mut Vec<String>) {
                out.extend(n.files.values().cloned());
                n.children.iter().for_each(|c| collect(c, out));
            }
            collect(&tree, &mut sources);
            for src in &sources {
                assert_eq!(
                    format!("{:?}", parse(src)),
                    format!("{:?}", dart::parse(src))
                );
            }
            assert_eq!(finish_run(), (240, 0));
        }
        // It turned the cache on, so it turns it off again.
        assert_eq!(finish_run(), (0, 0));
        CACHE.with(|c| assert!(c.borrow().is_none()));
        // A cache that was already on stays on, with its entries.
        enable();
        drop(prewarm(&tree));
        CACHE.with(|c| assert_eq!(c.borrow().as_ref().unwrap().entries.len(), 240));
        disable();
    }

    /// What [`prewarm`] counted, read without ending the run.
    fn finish_run_counts() -> (usize, usize) {
        CACHE.with(|c| c.borrow().as_ref().map(|c| (c.parsed, c.reused)).unwrap())
    }

    #[test]
    fn a_cache_off_thread_just_parses() {
        CACHE.with(|c| *c.borrow_mut() = None);
        assert_eq!(parse("class A { const A(); }").classes[0].name, "A");
        assert_eq!(finish_run(), (0, 0));
    }

    /// An app of `routes` routes: `lib/app/groupN/rI/page.dart`, `data.dart` on every fifth.
    fn synthetic_app(routes: usize) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
        for i in 0..routes {
            let d = dir.path().join(format!("lib/app/group{}/r{i}", i % 20));
            fs::create_dir_all(&d).unwrap();
            fs::write(d.join("page.dart"), PAGE.replace("{N}", &format!("R{i}"))).unwrap();
            if i % 5 == 0 {
                fs::write(
                    d.join("data.dart"),
                    format!("Future<String> data() async => 'r{i}';\n"),
                )
                .unwrap();
            }
        }
        dir
    }

    #[test]
    fn the_cache_changes_nothing_but_speed() {
        let dir = synthetic_app(40);
        let app = dir.path().join("lib/app");
        let cfg = Config::default();
        CACHE.with(|c| *c.borrow_mut() = None);
        let (plain, plain_diags, _) = build(&app, &cfg).unwrap();
        enable();
        build(&app, &cfg).unwrap();
        assert_eq!(finish_run().0, 48, "40 pages + 8 data files");
        let (cached, cached_diags, _) = build(&app, &cfg).unwrap();
        assert_eq!(finish_run(), (0, 48));
        assert_eq!(plain, cached);
        assert_eq!(plain_diags.0.len(), cached_diags.0.len());
        CACHE.with(|c| *c.borrow_mut() = None);
    }
}
