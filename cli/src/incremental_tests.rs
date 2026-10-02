//! `fsp watch` regenerates through a [`Session`] (the parse cache, the last run, the formatted
//! text). These tests hold it to one rule: after any sequence of edits, what it generates,
//! reports and writes is what a from-scratch generation of the same folder does, errors
//! included. There is one scenario per kind of edit the roadmap item names, then a
//! property-style test that replays random edits from fixed seeds.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use crate::config::Config;
use crate::session::{Formats, Session};
use crate::synth::{Files, Rng, layout, page};
use crate::{gen_core, parse_cache};

/// What a run said: whether it succeeded, the error line, every diagnostic, and the files it
/// leaves (`None` when it didn't write any).
#[derive(Debug, Clone, PartialEq)]
struct Report {
    ok: bool,
    error: String,
    diags: Vec<String>,
    outputs: Vec<Option<String>>,
    wrote: bool,
    routes: usize,
}

fn report(project: &Path, cfg: &Config, session: &mut Session) -> Report {
    let mut diags = vec![];
    let result = gen_core(project, cfg, true, session, |_, d| {
        diags = d.0.iter().map(std::string::ToString::to_string).collect();
    });
    let outputs = [Some(&cfg.output), cfg.output_manifest.as_ref()]
        .into_iter()
        .flatten()
        .map(|o| fs::read_to_string(project.join(o)).ok())
        .collect();
    let (wrote, routes) = result.as_ref().map_or((false, 0), |o| (o.wrote, o.routes));
    Report {
        ok: result.is_ok(),
        error: result.err().map(|e| format!("{e:#}")).unwrap_or_default(),
        diags,
        outputs,
        wrote,
        routes,
    }
}

/// Every file under `dir`, relative, with `/` separators.
fn walk(dir: &Path, rel: &str, files: &mut BTreeMap<String, String>, dirs: &mut Vec<String>) {
    let mut entries: Vec<_> = fs::read_dir(dir).unwrap().map(|e| e.unwrap()).collect();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    for e in entries {
        let name = e.file_name().to_string_lossy().to_string();
        let rel = if rel.is_empty() {
            name
        } else {
            format!("{rel}/{name}")
        };
        if e.file_type().unwrap().is_dir() {
            dirs.push(rel.clone());
            walk(&e.path(), &rel, files, dirs);
        } else {
            files.insert(rel, fs::read_to_string(e.path()).unwrap());
        }
    }
}

/// A folder being edited and regenerated the way `watch` does, next to a copy regenerated from scratch.
struct Sim {
    dir: tempfile::TempDir,
    cfg: Config,
    session: Session,
    counter: usize,
    rng: Rng,
    /// `(parsed, reused)` by the last [`Sim::regen`].
    parses: (usize, usize),
}

impl Sim {
    fn new(files: &Files, pubspec: &str, seed: u64) -> Sim {
        let dir = tempfile::tempdir().unwrap();
        files.write_to(dir.path());
        fs::write(dir.path().join("pubspec.yaml"), pubspec).unwrap();
        let cfg = Config::load(dir.path()).unwrap();
        parse_cache::enable();
        Sim {
            dir,
            cfg,
            session: Session::default(),
            counter: 0,
            rng: Rng::new(seed),
            parses: (0, 0),
        }
    }

    fn root(&self) -> PathBuf {
        self.dir.path().join("lib/app")
    }

    fn files(&self) -> BTreeMap<String, String> {
        let (mut files, mut dirs) = (BTreeMap::new(), vec![]);
        walk(&self.root(), "", &mut files, &mut dirs);
        files
    }

    fn dirs(&self) -> Vec<String> {
        let (mut files, mut dirs) = (BTreeMap::new(), vec![]);
        walk(&self.root(), "", &mut files, &mut dirs);
        dirs
    }

    fn write(&self, rel: &str, src: &str) {
        let p = self.root().join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, src).unwrap();
    }

    /// A file under `lib/` but outside the app folder: `models/category.dart`.
    fn lib_write(&self, rel: &str, src: &str) {
        let p = self.dir.path().join("lib").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, src).unwrap();
    }

    fn lib_remove(&self, rel: &str) {
        let _ = fs::remove_file(self.dir.path().join("lib").join(rel));
    }

    fn remove(&self, rel: &str) {
        let p = self.root().join(rel);
        if p.is_dir() {
            fs::remove_dir_all(p).unwrap();
        } else {
            fs::remove_file(p).unwrap();
        }
    }

    /// Regenerates through the session, as `watch` does.
    fn regen(&mut self) -> Report {
        let r = report(self.dir.path(), &self.cfg, &mut self.session);
        self.parses = parse_cache::finish_run();
        r
    }

    /// Regenerates a copy of the folder as it is now, on a thread of its own (so the parse
    /// cache is off) and with a new session: `gen`.
    fn fresh(&self) -> Report {
        let copy = tempfile::tempdir().unwrap();
        fs::write(
            copy.path().join("pubspec.yaml"),
            fs::read_to_string(self.dir.path().join("pubspec.yaml")).unwrap(),
        )
        .unwrap();
        fs::create_dir_all(copy.path().join("lib")).unwrap();
        fn copy_dir(from: &Path, to: &Path) {
            for e in fs::read_dir(from).unwrap() {
                let e = e.unwrap();
                let target = to.join(e.file_name());
                if e.file_type().unwrap().is_dir() {
                    fs::create_dir_all(&target).unwrap();
                    copy_dir(&e.path(), &target);
                } else {
                    fs::copy(e.path(), &target).unwrap();
                }
            }
        }
        // All of `lib/`: the enums segments name are declared outside the app folder.
        copy_dir(&self.dir.path().join("lib"), &copy.path().join("lib"));
        let cfg = self.cfg.clone();
        std::thread::spawn(move || report(copy.path(), &cfg, &mut Session::default()))
            .join()
            .unwrap()
    }

    /// Regenerates both ways and asserts they agree, however the edit went.
    fn same(&mut self, after: &str) -> Report {
        let inc = self.regen();
        let fresh = self.fresh();
        // `wrote` legitimately differs: the session's folder already has an output file.
        let strip = |r: &Report| Report {
            wrote: false,
            ..r.clone()
        };
        let (a, b) = (strip(&inc), strip(&fresh));
        // A failed run leaves the output the last good run wrote, which a new folder doesn't have.
        if inc.ok || fresh.ok {
            assert_eq!(a, b, "after {after}");
        } else {
            assert_eq!((&a.error, &a.diags), (&b.error, &b.diags), "after {after}");
        }
        inc
    }

    fn name(&mut self) -> usize {
        self.counter += 1;
        self.counter
    }
}

impl Drop for Sim {
    fn drop(&mut self) {
        parse_cache::disable();
    }
}

fn app(routes: usize) -> Files {
    Files::synth(routes)
}

const NO_CONFIG: &str = "name: demo\n";

#[test]
fn an_unchanged_folder_writes_nothing_and_resolves_nothing() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 1);
    let first = sim.same("the first run");
    assert!(first.ok && first.wrote, "{first:?}");
    let again = sim.regen();
    assert!(again.ok && !again.wrote);
    // The scanned tree is the last one's: the resolver never asked for a parse.
    assert_eq!(sim.parses, (0, 0));
    // Files the generator doesn't read change nothing either.
    sim.write("s1/_widgets/card.dart", "class Card {}");
    sim.write("s1/r30/helper.dart", "int helper() => 1;");
    let other = sim.regen();
    assert_eq!(other, again);
    assert_eq!(sim.parses, (0, 0));
}

#[test]
fn a_saved_page_parses_once_and_reports_no_change_when_the_output_is_the_same() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 1);
    sim.same("the first run");
    let page = "s1/r30/page.dart";
    let src = sim.files()[page].clone();
    sim.write(page, &format!("{src}\n// build() changed\n"));
    let r = sim.same("editing a build method");
    assert!(r.ok && !r.wrote, "{r:?}");
    // The next save parses one file; the fresh generation runs on another thread.
    let files = sim.files().keys().filter(|k| k.ends_with(".dart")).count();
    sim.write(page, &format!("{src}\n// again\n"));
    sim.regen();
    assert_eq!(sim.parses, (1, files - 1));
}

#[test]
fn add_and_remove_a_route() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 2);
    let before = sim.same("the first run");
    sim.write("s1/fresh/page.dart", &page("FreshPage", ""));
    let added = sim.same("adding a route");
    assert_eq!(added.routes, before.routes + 1);
    assert!(added.outputs[0].as_ref().unwrap().contains("FreshRoute"));
    sim.remove("s1/fresh");
    let removed = sim.same("removing it");
    assert_eq!(removed.routes, before.routes);
    assert_eq!(removed.outputs, before.outputs);
}

#[test]
fn rename_a_folder() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 3);
    sim.same("the first run");
    fs::rename(sim.root().join("s1/r30"), sim.root().join("s1/renamed")).unwrap();
    let r = sim.same("renaming a static folder");
    assert!(
        r.ok && r.outputs[0].as_ref().unwrap().contains("/renamed"),
        "{r:?}"
    );
    // Static to dynamic: whatever the generator makes of that, it makes of it either way.
    fs::rename(
        sim.root().join("s1/renamed"),
        sim.root().join("s1/$renamed"),
    )
    .unwrap();
    sim.same("making it a dynamic segment");
    fs::rename(sim.root().join("s1/$renamed"), sim.root().join("s1/r30")).unwrap();
    assert!(sim.same("and back").ok);
    // A whole section, with its layout and everything below it.
    fs::rename(sim.root().join("s1"), sim.root().join("s1-moved")).unwrap();
    assert!(sim.same("renaming a section").ok);
}

#[test]
fn change_a_data_type() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 4);
    sim.same("the first run");
    // A route with a data.dart and a `page` query parameter that both files declare.
    let (data, page_file) = ("s1/r30/data.dart", "s1/r30/page.dart");
    let (d, p) = (sim.files()[data].clone(), sim.files()[page_file].clone());
    assert!(
        d.contains("int? page") && p.contains("int? page"),
        "{d}\n{p}"
    );
    // Only data.dart changes: the two files disagree.
    sim.write(data, &d.replace("int? page", "String? page"));
    assert!(!sim.same("changing the type in data.dart only").ok);
    // Both change: the parameter is a String now, in the generated code too.
    sim.write(page_file, &p.replace("int? page", "String? page"));
    let r = sim.same("changing it in both");
    assert!(r.ok && r.wrote, "{r:?}");
    sim.write(data, &d);
    sim.write(page_file, &p);
    let r = sim.same("changing it back");
    assert!(r.ok && r.wrote);
}

#[test]
fn add_and_remove_a_layout() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 5);
    sim.same("the first run");
    // Below a section, and on a folder with a page of its own.
    sim.write("s1/r31/layout.dart", &layout("R31Layout", ""));
    assert!(sim.same("adding a layout to a route").ok);
    sim.write(
        "s1/r33/layout.dart",
        &layout("R33Layout", ", required this.mystery"),
    );
    sim.same("adding one that wants something it can't get");
    sim.remove("s1/r33/layout.dart");
    sim.same("removing it");
    sim.remove("s1/layout.dart");
    assert!(sim.same("removing a section's layout").ok);
    sim.remove("layout.dart");
    assert!(sim.same("removing the root layout").ok);
    sim.write("layout.dart", &layout("RootLayout", ""));
    assert!(sim.same("adding it back").ok);
}

#[test]
fn deferred_follows_a_route_dart() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 10);
    sim.same("the first run");
    sim.write("s1/route.dart", "const deferred = true;");
    let r = sim.same("a route.dart that defers");
    assert!(
        r.ok && r.wrote && r.outputs[0].as_ref().unwrap().contains("DeferredLibrary("),
        "{r:?}"
    );
    sim.write("s1/route.dart", "const deferred = false;");
    let r = sim.same("turning it off");
    assert!(
        r.ok && !r.outputs[0].as_ref().unwrap().contains("DeferredLibrary"),
        "{r:?}"
    );
    sim.write("s1/route.dart", "const deferred = maybe;");
    assert!(!sim.same("a route.dart that isn't a literal").ok);
    sim.remove("s1/route.dart");
    assert!(sim.same("removing it").ok);
}

#[test]
fn route_dart_extra_codec_and_extra_on_layouts_follow() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 10);
    sim.same("the first run");
    sim.write("s1/route.dart", "const caseSensitive = false;");
    let r = sim.same("a route.dart");
    assert!(
        r.ok && r.wrote
            && r.outputs[0]
                .as_ref()
                .unwrap()
                .contains("caseSensitive: false"),
        "{r:?}"
    );
    sim.write("s1/route.dart", "const caseSensitive = true;");
    assert!(sim.same("turning it back on").ok);
    sim.write("s1/route.dart", "final caseSensitive = maybe();");
    assert!(!sim.same("a route.dart that isn't a literal").ok);
    sim.remove("s1/route.dart");
    assert!(sim.same("removing it").ok);
    // Localized paths follow too: their spellings, a collision, and taking them away.
    let out = |r: &Report| r.outputs[0].clone().unwrap_or_default();
    sim.write("s1/route.dart", "const paths = {'fr': 'section-un'};");
    let r = sim.same("a route.dart with paths");
    assert!(r.ok && r.wrote && out(&r).contains("section-un"), "{r:?}");
    sim.write(
        "s1/route.dart",
        "const paths = {'fr': 'section-deux', 'de': 'über'};",
    );
    let r = sim.same("other spellings");
    assert!(
        r.ok && out(&r).contains("section-deux") && !out(&r).contains("section-un"),
        "{r:?}"
    );
    sim.write("s1/r30/route.dart", "const paths = {'fr': 'r31'};");
    assert!(!sim.same("a spelling that collides with another folder").ok);
    sim.write("s1/r30/route.dart", "const paths = {'fr': 'r30-fr'};");
    assert!(sim.same("fixing it").ok);
    sim.remove("s1/r30/route.dart");
    sim.remove("s1/route.dart");
    let r = sim.same("removing the paths");
    assert!(
        r.ok && !out(&r).contains("section-deux") && !out(&r).contains("r30-fr"),
        "{r:?}"
    );
    sim.write(
        "extra_codec.dart",
        "import 'package:fespalier/fespalier.dart';\nfinal extraCodec = ExtraCodec({});",
    );
    let r = sim.same("an extra_codec.dart");
    assert!(
        r.ok && r.outputs[0].as_ref().unwrap().contains("extraCodec"),
        "{r:?}"
    );
    sim.remove("extra_codec.dart");
    assert!(sim.same("removing it").ok);
    // A layout's `extra` is filled; a parameter that isn't one of ours is not.
    sim.write("s1/layout.dart", &layout("S1Layout", ", this.extra"));
    sim.same("a layout that takes extra");
    sim.write(
        "s1/layout.dart",
        &layout("S1Layout", ", required this.mystery"),
    );
    let r = sim.same("a layout that wants something it can't get");
    assert!(
        !r.ok && r.diags.iter().any(|d| d.contains("mystery")),
        "{r:?}"
    );
}

#[test]
fn a_route_that_leaves_the_page_above_follows() {
    let mut sim = Sim::new(&app(30), NO_CONFIG, 12);
    sim.same("the first run");
    let out = |r: &Report| r.outputs[0].clone().unwrap_or_default();
    sim.write("orders/page.dart", &page("OrdersPage", ""));
    sim.write("orders/refund/page.dart", &page("RefundPage", ""));
    let nested = sim.same("two pages, one below the other");
    assert!(
        nested.ok && !out(&nested).contains("(sibling)"),
        "{nested:?}"
    );
    // Beside `orders` instead of in it, and nested again when the setting goes.
    sim.write("orders/refund/route.dart", "const nest = false;");
    let r = sim.same("a nest = false");
    assert!(r.ok && r.wrote && out(&r).contains("(sibling)"), "{r:?}");
    sim.write("orders/refund/route.dart", "const nest = true;");
    let r = sim.same("a nest = true");
    assert!(r.ok && !out(&r).contains("(sibling)"), "{r:?}");
    sim.write("orders/refund/route.dart", "const nest = maybe;");
    assert!(!sim.same("a nest that isn't a literal").ok);
    // What a leaving route would escape: the layout of the page it leaves.
    sim.write("orders/refund/route.dart", "const nest = false;");
    assert!(sim.same("a nest = false again").ok);
    sim.write("orders/layout.dart", &layout("OrdersLayout", ""));
    let r = sim.same("a layout in the page's folder");
    assert!(
        !r.ok
            && r.diags
                .iter()
                .any(|d| d.contains("escape that layout's shell")),
        "{r:?}"
    );
    sim.remove("orders/layout.dart");
    assert!(sim.same("taking it away").ok);
    // A guard of the page it leaves goes with the route.
    sim.write(
        "orders/guard.dart",
        "GuardResult guard(ProviderContainer c) => null;",
    );
    let r = sim.same("a guard on the page");
    assert!(r.ok && out(&r).contains("orders/guard.dart"), "{r:?}");
    // A page that is no longer there is nothing to leave.
    sim.remove("orders/page.dart");
    sim.remove("orders/guard.dart");
    let r = sim.same("removing the page above");
    assert!(!r.ok, "{r:?}");
    sim.remove("orders/refund/route.dart");
    assert!(sim.same("removing the route.dart").ok);
}

const CATEGORY: &str = "enum Category { shoes, hats }\n";

/// Two routes with an enum segment: one imports the enum's file, one a file that exports it.
fn with_enum_routes(sim: &Sim) {
    sim.lib_write("models/category.dart", CATEGORY);
    sim.lib_write("models/all.dart", "export 'category.dart';\n");
    let shop = format!(
        "import 'package:demo/models/category.dart';\n{}",
        page("ShopCat", "required Category category")
    );
    let stock = format!(
        "import 'package:demo/models/all.dart';\n{}",
        page("StockCat", "required Category category")
    );
    sim.write("s1/shop/$category/page.dart", &shop);
    sim.write("s1/stock/$category/page.dart", &stock);
}

#[test]
fn an_enum_outside_the_app_folder_follows() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 11);
    with_enum_routes(&sim);
    let r = sim.same("the first run");
    assert!(
        r.ok && r.outputs[0]
            .as_ref()
            .unwrap()
            .contains("Segment.asEnum(s, 'category', Category.values)"),
        "{r:?}"
    );
    // The enum's file is read each run and compared, and while it is the same nothing is parsed or resolved.
    sim.regen();
    assert_eq!(sim.parses, (0, 0));
    sim.lib_write("widgets/unrelated.dart", "class W {}");
    sim.regen();
    assert_eq!(sim.parses, (0, 0));
    // A value added: still an enum.
    sim.lib_write(
        "models/category.dart",
        "enum Category { shoes, hats, bags }\n",
    );
    assert!(sim.same("a new enum value").ok);
    // The enum renamed: what the routes name is gone, so both are errors, as from scratch.
    sim.lib_write("models/category.dart", "enum Kind { shoes, hats }\n");
    let r = sim.same("the enum renamed");
    assert!(
        !r.ok && r.diags.iter().any(|d| d.contains("Category")),
        "{r:?}"
    );
    sim.lib_write("models/category.dart", CATEGORY);
    assert!(sim.same("and back").ok);
    // It stops being an enum, is deleted, is exported from somewhere else.
    sim.lib_write("models/category.dart", "class Category {}\n");
    assert!(!sim.same("a class now").ok);
    sim.lib_write("models/category.dart", CATEGORY);
    sim.lib_remove("models/category.dart");
    assert!(!sim.same("the file deleted").ok);
    sim.lib_write("models/elsewhere.dart", CATEGORY);
    sim.lib_write("models/all.dart", "export 'elsewhere.dart';\n");
    let r = sim.same("declared in another file, exported by all.dart");
    assert!(!r.ok, "the direct import no longer finds it: {r:?}");
    sim.remove("s1/shop");
    assert!(
        sim.same("without the route that imports the deleted file")
            .ok
    );
    sim.lib_write("models/all.dart", "// nothing exported\n");
    assert!(!sim.same("the export removed").ok);
}

/// A string path in a file outside the app folder is checked on every run, whether the tree
/// changed or not, and a save of that file alone is noticed.
#[test]
fn a_string_path_outside_the_app_folder_follows() {
    let mut sim = Sim::new(&app(30), NO_CONFIG, 3);
    assert!(sim.same("the first run").ok);
    sim.lib_write(
        "screens/home.dart",
        "void f(BuildContext c) { c.go('/missing/x'); }\n",
    );
    let bad = sim.same("a path that matches no route");
    assert!(bad.ok && bad.diags.len() == 1, "{bad:?}");
    assert!(
        bad.diags[0].starts_with("! lib/screens/home.dart:1  no route matches `/missing/x`"),
        "{bad:?}"
    );
    // The same source again: the same report, and nothing is written.
    let again = sim.same("the same file saved again");
    assert_eq!((&again.diags, again.wrote), (&bad.diags, false));
    sim.lib_write(
        "screens/home.dart",
        "void f(BuildContext c) { c.go('/'); }\n",
    );
    assert!(sim.same("the path fixed").diags.is_empty());
    // A route that appears makes a path that matched nothing match.
    sim.lib_write(
        "screens/home.dart",
        "void f(BuildContext c) { c.go('/fresh'); }\n",
    );
    assert_eq!(sim.same("a path to a route not there yet").diags.len(), 1);
    sim.write("fresh/page.dart", &page("FreshPage", ""));
    assert!(sim.same("the route added").diags.is_empty());
    sim.remove("fresh");
    assert_eq!(sim.same("the route removed again").diags.len(), 1);
    sim.lib_remove("screens/home.dart");
    assert!(sim.same("the file deleted").diags.is_empty());
}

#[test]
fn touch_a_group_folder() {
    let mut sim = Sim::new(&app(60), NO_CONFIG, 6);
    sim.same("the first run");
    // An empty group, then something in it.
    fs::create_dir_all(sim.root().join("(empty)")).unwrap();
    sim.same("an empty group");
    sim.write("(empty)/extra/page.dart", &page("ExtraPage", ""));
    assert!(sim.same("a page in it").ok);
    // A group becomes a static folder and back: the URLs of everything under it change.
    fs::rename(sim.root().join("(g0)"), sim.root().join("g0")).unwrap();
    assert!(sim.same("a group becoming a folder").ok);
    fs::rename(sim.root().join("g0"), sim.root().join("(g0)")).unwrap();
    assert!(sim.same("and back").ok);
    // Group names that collide.
    fs::rename(sim.root().join("(empty)"), sim.root().join("(g0)/(inner)")).unwrap();
    sim.same("a group inside a group");
    sim.remove("(g0)");
    sim.same("deleting a group with everything in it");
}

#[test]
fn an_invalid_folder_name_is_reported_and_then_gone() {
    let mut sim = Sim::new(&app(30), NO_CONFIG, 7);
    sim.same("the first run");
    sim.write("bad name/page.dart", &page("BadPage", ""));
    let r = sim.same("a folder that isn't a segment");
    assert!(
        !r.ok && r.diags.iter().any(|d| d.contains("bad name")),
        "{r:?}"
    );
    // The tree is the same as before (the folder is left out of it), the diagnostics aren't.
    sim.remove("bad name");
    assert!(sim.same("removing it").ok);
    fs::write(sim.root().join("s1/not_found.dart"), "class A extends StatelessWidget { const A({super.key, required this.uri}); final Uri uri; }").unwrap();
    fs::write(sim.root().join("s1/not-found.dart"), "class B extends StatelessWidget { const B({super.key, required this.uri}); final Uri uri; }").unwrap();
    let r = sim.same("two spellings of one view");
    assert!(!r.ok);
    sim.remove("s1/not-found.dart");
    assert!(sim.same("keeping one").ok);
}

#[test]
fn a_manifest_file_follows_too() {
    let cfg = "name: demo\nfespalier:\n  output_manifest: lib/app.routes.g.dart\n";
    let mut sim = Sim::new(&app(60), cfg, 8);
    let first = sim.same("the first run");
    assert!(first.outputs.iter().all(Option::is_some));
    sim.write("s1/r30/meta.dart", "const meta = 'changed';");
    let r = sim.same("a meta.dart");
    assert!(r.ok && r.wrote, "{r:?}");
    sim.remove("s1/r30/meta.dart");
    assert!(sim.same("removing it").ok);
}

#[test]
fn a_deleted_output_is_written_again_even_for_an_unchanged_tree() {
    let mut sim = Sim::new(&app(20), NO_CONFIG, 9);
    sim.same("the first run");
    fs::remove_file(sim.dir.path().join("lib/app.g.dart")).unwrap();
    let r = sim.regen();
    assert!(r.ok && r.wrote && r.outputs[0].is_some());
    fs::write(sim.dir.path().join("lib/app.g.dart"), "// edited by hand").unwrap();
    let r = sim.regen();
    assert!(r.ok && r.wrote);
    assert_eq!(r, sim.fresh_as_written());
}

impl Sim {
    /// A fresh generation's report, but with `wrote` as the session's run had it.
    fn fresh_as_written(&self) -> Report {
        Report {
            wrote: true,
            ..self.fresh()
        }
    }
}

// --- random edits ------------------------------------------------------------

impl Sim {
    /// One random edit; returns what it did, for the failure message.
    fn edit(&mut self) -> String {
        let n = self.name();
        let files = self.files();
        let dirs = self.dirs();
        let pages: Vec<&String> = files.keys().filter(|f| f.ends_with("page.dart")).collect();
        let parent_of = |f: &str| {
            f.rsplit_once('/')
                .map(|(d, _)| d.to_string())
                .unwrap_or_default()
        };
        match self.rng.below(18) {
            0 | 1 => {
                // A route: static or dynamic, sometimes a duplicate route name.
                let mut sections = vec![String::new()];
                sections.extend(
                    dirs.iter()
                        .filter(|d| d.matches('/').count() <= 1 && !d.starts_with('_'))
                        .cloned(),
                );
                let at = self.rng.pick(&sections).clone();
                let dynamic = self.rng.below(3) == 0;
                let seg = if dynamic {
                    format!("$p{n}")
                } else {
                    format!("n{n}")
                };
                let class = if self.rng.below(8) == 0 {
                    "R0Page".to_string()
                } else {
                    format!("N{n}Page")
                };
                let params = if dynamic {
                    format!("required int p{n}")
                } else {
                    "String? q".into()
                };
                let dir = if at.is_empty() {
                    seg
                } else {
                    format!("{at}/{seg}")
                };
                self.write(&format!("{dir}/page.dart"), &page(&class, &params));
                if self.rng.below(3) == 0 {
                    self.write(
                        &format!("{dir}/data.dart"),
                        "Future<Item> data(Ref ref) async => Item();",
                    );
                }
                format!("adding {dir}")
            }
            2 if !pages.is_empty() => {
                let picked = (*self.rng.pick(&pages)).clone();
                let dir = parent_of(&picked);
                if dir.is_empty() {
                    return "nothing (the root page stays)".into();
                }
                self.remove(&dir);
                format!("removing {dir}")
            }
            3 if dirs.len() > 1 => {
                let d = self.rng.pick(&dirs).clone();
                let parent = d
                    .rsplit_once('/')
                    .map(|(p, _)| format!("{p}/"))
                    .unwrap_or_default();
                let new = match self.rng.below(4) {
                    0 => format!("$z{n}"),
                    1 => format!("(z{n})"),
                    _ => format!("z{n}"),
                };
                fs::rename(
                    self.root().join(&d),
                    self.root().join(format!("{parent}{new}")),
                )
                .unwrap();
                format!("renaming {d} to {new}")
            }
            4 => {
                let datas: Vec<&String> =
                    files.keys().filter(|f| f.ends_with("data.dart")).collect();
                if datas.is_empty() {
                    return "nothing (no data.dart)".into();
                }
                let data = (*self.rng.pick(&datas)).clone();
                let src = files[&data].clone();
                let both = self.rng.below(2) == 0;
                let page_file = format!("{}/page.dart", parent_of(&data));
                if src.contains("int? page") {
                    self.write(&data, &src.replace("int? page", "String? page"));
                    if both && let Some(p) = files.get(&page_file) {
                        self.write(&page_file, &p.replace("int? page", "String? page"));
                    }
                } else {
                    self.write(
                        &data,
                        &src.replace("Future<Item>", "Future<List<Item>>")
                            .replace("Item()", "[Item()]"),
                    );
                }
                format!("changing the type in {data} (both files: {both})")
            }
            5 => {
                let candidates: Vec<&String> = dirs
                    .iter()
                    .filter(|d| !files.contains_key(&format!("{d}/layout.dart")))
                    .collect();
                if candidates.is_empty() {
                    return "nothing".into();
                }
                let d = (*self.rng.pick(&candidates)).clone();
                self.write(&format!("{d}/layout.dart"), &layout(&format!("L{n}"), ""));
                format!("adding {d}/layout.dart")
            }
            6 => {
                let layouts: Vec<&String> = files
                    .keys()
                    .filter(|f| f.ends_with("layout.dart"))
                    .collect();
                if layouts.is_empty() {
                    return "nothing".into();
                }
                let l = (*self.rng.pick(&layouts)).clone();
                self.remove(&l);
                format!("removing {l}")
            }
            7 => {
                // A group folder: rename it, fill it, empty it.
                let groups: Vec<&String> = dirs
                    .iter()
                    .filter(|d| d.rsplit('/').next().is_some_and(|b| b.starts_with('(')))
                    .collect();
                if groups.is_empty() {
                    fs::create_dir_all(self.root().join(format!("(new{n})"))).unwrap();
                    return format!("creating an empty group (new{n})");
                }
                let g = (*self.rng.pick(&groups)).clone();
                match self.rng.below(3) {
                    0 => {
                        self.write(
                            &format!("{g}/in{n}/page.dart"),
                            &page(&format!("In{n}Page"), ""),
                        );
                        format!("adding a route in {g}")
                    }
                    1 => {
                        let parent = g
                            .rsplit_once('/')
                            .map(|(p, _)| format!("{p}/"))
                            .unwrap_or_default();
                        fs::rename(
                            self.root().join(&g),
                            self.root().join(format!("{parent}g{n}")),
                        )
                        .unwrap();
                        format!("turning {g} into a folder")
                    }
                    _ => {
                        self.remove(&g);
                        format!("deleting {g}")
                    }
                }
            }
            8 | 9 => {
                let dart: Vec<&String> = files.keys().filter(|f| f.ends_with(".dart")).collect();
                let f = (*self.rng.pick(&dart)).clone();
                let src = files[&f].clone();
                let new = if self.rng.below(2) == 0 {
                    format!("{src}\n// edit {n}\n")
                } else {
                    src
                };
                self.write(&f, &new);
                format!("rewriting {f}")
            }
            10 => {
                let d = self.rng.pick(&dirs).clone();
                self.write(&format!("{d}/_widgets/w{n}.dart"), "class W {}");
                format!("a widget in {d}/_widgets")
            }
            11 if !pages.is_empty() => {
                let p = (*self.rng.pick(&pages)).clone();
                self.write(&p, "class P extends StatelessWidget { const P({super.key, required this.x}); final int x; }");
                format!("breaking {p}")
            }
            12 => {
                let f = (*self.rng.pick(&files.keys().collect::<Vec<_>>())).clone();
                self.remove(&f);
                format!("deleting {f}")
            }
            13 => {
                // A folder's `route.dart`: add one (either way) or take it away.
                // `nest = false` takes a route out of the page above it: it works for a folder
                // with a page below another that has one (unless a layout is in between), and is
                // an error anywhere else, so it is aimed at the folders that have a page above.
                let has_page = |dir: &str| {
                    files.contains_key(&if dir.is_empty() {
                        "page.dart".to_string()
                    } else {
                        format!("{dir}/page.dart")
                    })
                };
                let below_a_page = |d: &str| {
                    let mut up = d;
                    let mut above = has_page("");
                    while let Some((p, _)) = up.rsplit_once('/') {
                        up = p;
                        above |= has_page(up);
                    }
                    has_page(d) && above
                };
                let leavers: Vec<&String> = dirs.iter().filter(|d| below_a_page(d)).collect();
                if !leavers.is_empty() && self.rng.below(3) == 0 {
                    let d = (*self.rng.pick(&leavers)).clone();
                    let nest = self.rng.below(5) == 0;
                    self.write(&format!("{d}/route.dart"), &format!("const nest = {nest};"));
                    return format!("adding {d}/route.dart (nest = {nest})");
                }
                let d = self.rng.pick(&dirs).clone();
                let f = format!("{d}/route.dart");
                if files.contains_key(&f) {
                    self.remove(&f);
                    format!("removing {f}")
                } else if self.rng.below(3) == 0 {
                    // Other spellings for the folder: some collide with a folder that is there, some
                    // are not valid, some sit on a folder that can't have them (a `$param`, the root).
                    let words = ["aussen", "über", "a b", "r30", "s1", "x9", "produits"];
                    let word = *self.rng.pick(&words);
                    let taken: Vec<&str> = dirs
                        .iter()
                        .filter_map(|d| d.rsplit('/').next())
                        .filter(|d| !d.is_empty() && !d.starts_with('$'))
                        .collect();
                    let other = if taken.is_empty() {
                        "r30".to_string()
                    } else {
                        self.rng.pick(&taken).to_string()
                    };
                    let body = match self.rng.below(4) {
                        0 => format!("const paths = {{'fr': '{word}'}};"),
                        1 => format!("const paths = {{'fr': '{other}', 'de': '{word}'}};"),
                        2 => "const paths = names;".to_string(),
                        _ => format!(
                            "const caseSensitive = false;\nconst paths = {{'fr': '{other}'}};"
                        ),
                    };
                    self.write(&f, &body);
                    format!("adding {f} ({body})")
                } else {
                    let on = self.rng.below(2) == 0;
                    self.write(&f, &format!("const caseSensitive = {on};"));
                    format!("adding {f} ({on})")
                }
            }
            14 => {
                // The root's `extra_codec.dart`: add it or take it away.
                if files.contains_key("extra_codec.dart") {
                    self.remove("extra_codec.dart");
                    "removing extra_codec.dart".into()
                } else {
                    self.write("extra_codec.dart", "import 'package:fespalier/fespalier.dart';\nfinal extraCodec = ExtraCodec({});");
                    "adding extra_codec.dart".into()
                }
            }
            15 | 16 => {
                // Outside the app folder: the enum's file, or the file that exports it.
                const ENUMS: [&str; 5] = [
                    "enum Category { shoes, hats }\n",
                    "enum Category { shoes, hats, bags }\n",
                    "enum Kind { shoes }\n",
                    "class Category {}\n",
                    "// emptied\n",
                ];
                match self.rng.below(4) {
                    0 | 1 => {
                        let src = self.rng.pick(&ENUMS);
                        self.lib_write("models/category.dart", src);
                        format!("models/category.dart is {src:?}")
                    }
                    2 => {
                        self.lib_remove("models/category.dart");
                        "deleting models/category.dart".into()
                    }
                    _ => {
                        let src = if self.rng.below(2) == 0 {
                            "export 'category.dart';\n"
                        } else {
                            "// nothing\n"
                        };
                        self.lib_write("models/all.dart", src);
                        format!("models/all.dart is {src:?}")
                    }
                }
            }
            17 => {
                // A string path in a file outside the app folder (`lib/screens/`): to a route
                // that is there, or one that is not. The lint reads these files on every run.
                let file = format!("screens/s{}.dart", self.rng.below(3));
                if self.rng.below(4) == 0 {
                    self.lib_remove(&file);
                    return format!("deleting lib/{file}");
                }
                let url = if pages.is_empty() || self.rng.below(3) == 0 {
                    format!("/missing{n}")
                } else {
                    let dir = parent_of(self.rng.pick(&pages));
                    let parts: Vec<&str> = dir
                        .split('/')
                        .filter(|p| !p.is_empty() && !p.starts_with('('))
                        .map(|p| if p.starts_with('$') { "1" } else { p })
                        .collect();
                    format!("/{}", parts.join("/"))
                };
                self.lib_write(
                    &file,
                    &format!("void f(BuildContext c) {{ c.go('{url}'); }}\n"),
                );
                format!("lib/{file} goes to {url}")
            }
            _ => "nothing".into(),
        }
    }
}

/// The whole folder as it is on disk, to put back: the app folder and the enum files beside it.
struct Snapshot {
    files: BTreeMap<String, String>,
    dirs: Vec<String>,
    models: Vec<(&'static str, Option<String>)>,
}

const MODELS: [&str; 2] = ["models/category.dart", "models/all.dart"];

fn snapshot(sim: &Sim) -> Snapshot {
    let (mut files, mut dirs) = (BTreeMap::new(), vec![]);
    walk(&sim.root(), "", &mut files, &mut dirs);
    let models = MODELS
        .iter()
        .map(|m| {
            (
                *m,
                fs::read_to_string(sim.dir.path().join("lib").join(m)).ok(),
            )
        })
        .collect();
    Snapshot {
        files,
        dirs,
        models,
    }
}

fn restore(sim: &Sim, snap: &Snapshot) {
    fs::remove_dir_all(sim.root()).unwrap();
    fs::create_dir_all(sim.root()).unwrap();
    for d in &snap.dirs {
        fs::create_dir_all(sim.root().join(d)).unwrap();
    }
    for (f, src) in &snap.files {
        sim.write(f, src);
    }
    for (m, src) in &snap.models {
        match src {
            Some(src) => sim.lib_write(m, src),
            None => sim.lib_remove(m),
        }
    }
}

fn random_edits(seed: u64, config: &str) -> (usize, usize) {
    let mut sim = Sim::new(&app(30), config, seed);
    with_enum_routes(&sim);
    let mut good = snapshot(&sim);
    let (mut oks, mut errs, mut failing) = (0, 0, 0);
    let mut log = vec![];
    for step in 0..30 {
        let what = sim.edit();
        log.push(what.clone());
        let r = sim.same(&format!(
            "step {step} of seed {seed}: {what}\n(steps so far: {log:#?})"
        ));
        if r.ok {
            oks += 1;
            good = snapshot(&sim);
            failing = 0;
        } else {
            errs += 1;
            failing += 1;
            // Put back the last folder that generated, like undoing a bad save.
            if failing >= 3 {
                restore(&sim, &good);
                sim.same(&format!(
                    "restoring the last good folder after step {step} of seed {seed}"
                ));
                failing = 0;
            }
        }
    }
    (oks, errs)
}

#[test]
fn random_edits_match_a_fresh_generation() {
    let (mut oks, mut errs) = (0, 0);
    for seed in 1..=8 {
        let config = if seed % 3 == 0 {
            "name: demo\nfespalier:\n  output_manifest: lib/app.routes.g.dart\n"
        } else {
            NO_CONFIG
        };
        let (o, e) = random_edits(seed, config);
        oks += o;
        errs += e;
    }
    // The edits reach both kinds of run: an app that generates, and one that reports errors.
    assert!(
        oks > 60 && errs > 20,
        "{oks} runs generated, {errs} reported errors"
    );
}

// --- the formatted text ------------------------------------------------------

#[test]
fn code_is_formatted_once_however_often_it_comes_back() {
    let mut formats = Formats::default();
    let mut calls = 0;
    let mut go = |formats: &mut Formats, path: &str, code: &str| {
        formats.get(path, code, |c| {
            calls += 1;
            (format!("// formatted\n{c}"), None)
        })
    };
    assert_eq!(go(&mut formats, "a.g.dart", "one"), "// formatted\none");
    assert_eq!(go(&mut formats, "a.g.dart", "one"), "// formatted\none");
    assert_eq!(
        go(&mut formats, "b.g.dart", "one"),
        "// formatted\none",
        "another file is another entry"
    );
    assert_eq!(go(&mut formats, "a.g.dart", "two"), "// formatted\ntwo");
    assert_eq!(go(&mut formats, "a.g.dart", "two"), "// formatted\ntwo");
    assert_eq!(calls, 3);
    // A warning (no `dart`) isn't remembered: it is said, and tried, again.
    let mut tries = 0;
    for _ in 0..2 {
        let out = formats.get("c.g.dart", "x", |c| {
            tries += 1;
            (c.to_string(), Some("warning: not formatting".into()))
        });
        assert_eq!(out, "x");
    }
    assert_eq!(tries, 2);
}

// --- pieces ------------------------------------------------------------------

#[cfg(unix)]
#[test]
fn a_symlinked_folder_is_still_a_folder() {
    let dir = tempfile::tempdir().unwrap();
    let mut files = Files::default();
    files.set("page.dart", page("HomePage", ""));
    files.write_to(dir.path());
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("page.dart"), page("LinkedPage", "")).unwrap();
    std::os::unix::fs::symlink(outside.path(), dir.path().join("lib/app/linked")).unwrap();
    let (code, diags, routes) =
        crate::build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    assert_eq!(routes, 2);
    assert!(code.contains("LinkedRoute"));
}
