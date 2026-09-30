//! Where the time goes in `fsp gen` and in a `fsp watch` regeneration, on synthetic apps of
//! 500, 2,000 and 5,000 routes:
//! `cargo test --release bench -- --ignored --nocapture --test-threads=1`.

use std::fs;
use std::time::{Duration, Instant};

use crate::config::Config;
use crate::diag::Diags;
use crate::synth::Files;
use crate::session::Session;
use crate::{emit, format, manifest, parse_cache, resolve, scan};

fn time<T>(f: impl FnOnce() -> T) -> (Duration, T) {
    let t = Instant::now();
    let v = f();
    (t.elapsed(), v)
}

fn ms(d: Duration) -> String {
    format!("{:>8.1}", d.as_secs_f64() * 1000.0)
}

fn sources(n: &scan::Node, out: &mut Vec<String>) {
    out.extend(n.files.values().cloned());
    for c in &n.children {
        sources(c, out);
    }
}

#[test]
#[ignore = "benchmark"]
fn bench_stages() {
    let cfg = Config::default();
    println!("\n  routes |  files |     scan    parse  resolve     emit (check) |   format    write");
    for routes in [500, 2000, 5000] {
        let dir = tempfile::tempdir().unwrap();
        let files = Files::synth(routes);
        files.write_to(dir.path());
        let app_dir = dir.path().join("lib/app");
        let out = dir.path().join("lib/app.g.dart");

        parse_cache::disable();
        let (t_scan, tree) = time(|| scan::scan(&app_dir, &mut Diags::default()).unwrap());
        let mut srcs = vec![];
        sources(&tree, &mut srcs);
        let (t_parse, _) = time(|| srcs.iter().for_each(|s| drop(crate::dart::parse(s))));
        // Resolve alone: the parses come from the cache.
        parse_cache::enable();
        resolve::resolve(&tree, cfg.case_sensitive, &crate::enums::Libs::default(), &mut Diags::default());
        parse_cache::finish_run();
        let (t_resolve, app) = time(|| resolve::resolve(&tree, cfg.case_sensitive, &crate::enums::Libs::default(), &mut Diags::default()));
        parse_cache::disable();
        let (t_check, _) = time(|| manifest::check(&app, &cfg, &mut Diags::default()));
        let (t_emit, code) = time(|| emit::emit(&app, &cfg, &mut Diags::default()));
        let (t_format, _) = time(|| format::format_dart(&code, &out));
        let (t_write, _) = time(|| {
            fs::create_dir_all(out.parent().unwrap()).unwrap();
            fs::write(&out, &code).unwrap();
        });
        println!(
            "{routes:>8} | {:>6} | {} {} {} {} ({}) | {} {}   [{} KB generated]",
            srcs.len(),
            ms(t_scan),
            ms(t_parse),
            ms(t_resolve),
            ms(t_emit),
            ms(t_check),
            ms(t_format),
            ms(t_write),
            code.len() / 1024
        );
    }
}

fn walk(dir: &std::path::Path, read: bool, stat: bool, n: &mut usize) {
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().filter_map(|e| e.ok()).collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let ft = e.file_type().unwrap();
        if ft.is_dir() {
            walk(&e.path(), read, stat, n);
        } else {
            *n += 1;
            if stat {
                *n += e.metadata().unwrap().len() as usize % 2;
            }
            if read {
                *n += fs::read_to_string(e.path()).unwrap().len() % 2;
            }
        }
    }
}

#[test]
#[ignore = "benchmark"]
fn bench_walk() {
    let dir = tempfile::tempdir().unwrap();
    Files::synth(5000).write_to(dir.path());
    let app = dir.path().join("lib/app");
    for (read, stat) in [(false, false), (false, true), (true, false), (true, true)] {
        let mut n = 0;
        walk(&app, read, stat, &mut n);
        let (t, _) = time(|| walk(&app, read, stat, &mut n));
        println!("walk read={read} stat={stat}: {}", ms(t));
    }
    let (t, _) = time(|| scan::scan(&app, &mut Diags::default()).unwrap());
    println!("scan::scan {}", ms(t));
}

/// A cold `gen`, and `watch`-style regenerations (one session, the parse cache on) after
/// each kind of save, end to end through `gen_core`, in milliseconds. `wrote` says whether
/// the save changed the generated file.
#[test]
#[ignore = "benchmark"]
fn bench_regeneration() {
    println!("\n  routes |     cold | body edit | data type | other file |   idle |  format");
    for routes in [500, 2000, 5000] {
        for format in [false, true] {
            let dir = tempfile::tempdir().unwrap();
            let files = Files::synth(routes);
            files.write_to(dir.path());
            let cfg = Config { format, ..Config::default() };
            let mut session = Session::default();
            parse_cache::disable();
            let (cold, _) = time(|| crate::gen_core(dir.path(), &cfg, true, &mut Session::default(), |_, _| {}).unwrap());
            parse_cache::enable();
            let run = |session: &mut Session| {
                let (t, o) = time(|| crate::gen_core(dir.path(), &cfg, true, session, |_, _| {}).unwrap());
                parse_cache::finish_run();
                format!("{} {}", ms(t), if o.wrote { "w" } else { "-" })
            };
            run(&mut session);
            let page = "(g0)/r0/$id/page.dart";
            let src = files.0[page].clone() + "\n// a change to build()\n";
            files.write_one(dir.path(), page, &src);
            let body = run(&mut session);
            let data = "(g0)/r0/$id/data.dart";
            files.write_one(dir.path(), data, &files.0[data].replace("int? page", "String? page"));
            files.write_one(dir.path(), page, &src.replace("int? page", "String? page"));
            let ty = run(&mut session);
            files.write_one(dir.path(), "(g0)/r0/_widgets/card.dart", "class Card {}");
            let other = run(&mut session);
            let idle = run(&mut session);
            parse_cache::disable();
            println!("{routes:>8} | {} | {body} | {ty} | {other} | {idle} | {format}", ms(cold));
        }
    }
}

