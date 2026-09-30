//! Parse cache for `fsp watch`: a save changes one file, so only that file is parsed again.
//!
//! The resolver calls [`parse`] for every Dart file of every route on each run. Outside
//! `watch` the cache is off and this is `dart::parse`. `watch` calls [`enable`] once and
//! [`finish_run`] after each regeneration. The key is the file's source text itself, so a hit
//! is exact: there is no hash to collide and no mtime to trust. Entries a run didn't touch
//! (deleted, renamed or edited files) are dropped by [`finish_run`], so the cache never
//! outgrows the app folder.

use std::cell::RefCell;
use std::collections::HashMap;

use crate::dart::{self, Module};

struct Entry {
    module: Module,
    /// Whether the current run used this entry.
    used: bool,
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

/// `dart::parse`, served from the cache when the cache is on and has seen this exact source.
pub fn parse(src: &str) -> Module {
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        let Some(cache) = c.as_mut() else { return dart::parse(src) };
        if let Some(e) = cache.entries.get_mut(src) {
            e.used = true;
            cache.reused += 1;
            return e.module.clone();
        }
        let module = dart::parse(src);
        cache.parsed += 1;
        cache.entries.insert(src.to_string(), Entry { module: module.clone(), used: true });
        module
    })
}

/// Ends a run: forgets sources the run didn't use and returns `(parsed, reused)` for it.
pub fn finish_run() -> (usize, usize) {
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        let Some(cache) = c.as_mut() else { return (0, 0) };
        cache.entries.retain(|_, e| std::mem::take(&mut e.used));
        (std::mem::take(&mut cache.parsed), std::mem::take(&mut cache.reused))
    })
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::time::Instant;

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
    fn a_cache_off_thread_just_parses() {
        CACHE.with(|c| *c.borrow_mut() = None);
        assert_eq!(parse("class A { const A(); }").classes[0].name, "A");
        assert_eq!(finish_run(), (0, 0));
    }

    /// A 1,000-route app: `lib/app/r0/.../page.dart`, `data.dart` on every fifth.
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

    /// Cold and single-file-change regeneration of a 1,000-route app, with and without the
    /// cache. Prints the timings: `cargo test --release parse_cache -- --ignored --nocapture`.
    #[test]
    #[ignore = "benchmark"]
    fn bench_single_file_change_in_1000_routes() {
        let dir = synthetic_app(1000);
        let app = dir.path().join("lib/app");
        let cfg = Config::default();
        let run = || {
            let t = Instant::now();
            let (code, _diags, routes) = build(&app, &cfg).unwrap();
            (t.elapsed(), code, routes)
        };
        let edit = |n: u32| {
            fs::write(
                app.join("group0/r0/page.dart"),
                format!("{}\n// edit {n}\n", PAGE.replace("{N}", "R0")),
            )
            .unwrap();
        };

        CACHE.with(|c| *c.borrow_mut() = None);
        let (cold, _, routes) = run();
        edit(1);
        let (uncached, code_uncached, _) = run();
        println!("{routes} routes: cold {cold:.1?}; after a one-file edit, no cache {uncached:.1?}");

        enable();
        run();
        finish_run();
        edit(2);
        let (cached, code_cached, _) = run();
        let (parsed, reused) = finish_run();
        println!("with cache: {cached:.1?} (parsed {parsed}, reused {reused})");
        assert_eq!(parsed, 1);
        assert_eq!(code_cached, code_uncached);
        CACHE.with(|c| *c.borrow_mut() = None);
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
