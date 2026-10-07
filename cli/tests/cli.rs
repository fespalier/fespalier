//! Runs the built `fsp` binary: success lines, `fsp new`, and `fsp watch`.

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "integration-test helpers: a failed unwrap is a failed test"
)]

use std::fs;
use std::io::{self, Read, Write};
use std::path::Path;
#[cfg(unix)]
use std::process::ExitStatus;
use std::process::{Child, Command, Output, Stdio};
use std::sync::{PoisonError, RwLock};
use std::thread::sleep;
use std::time::{Duration, Instant};

// --- Writing stand-in executables, starting processes ------------------------------------------
//
// Some tests write a stand-in executable (a shell script for `docker`, `flutter` or `dart`) and
// run it through `fsp`, while other test threads start processes. `Command::spawn` forks, and
// until the child execs it holds a copy of every file the test process has open (close-on-exec
// only acts at the exec). A child forked by another thread between our `open` and `close` of the
// script keeps it open for writing, so running the script fails with ETXTBSY, "Text file busy"
// (rust-lang/rust#114554). One lock rules that out: a script is written holding its write side
// (`write_executable`), and a process is started holding its read side until the child has
// exec'd (`spawn_locked`, `output_locked`, `status_locked`), so no fork overlaps a write. Every
// `Command` in this file goes through them, and every stand-in executable is written by the one.

/// Write side: an executable is being written. Read side: a process is being started.
static EXEC_RACE: RwLock<()> = RwLock::new(());

/// Writes `contents` to `path` and makes it executable, while no process is being started.
#[cfg(unix)]
fn write_executable(path: &Path, contents: &str) {
    use std::os::unix::fs::PermissionsExt;
    let _writing = EXEC_RACE.write().unwrap_or_else(PoisonError::into_inner);
    fs::write(path, contents).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

/// `command.spawn()`. The read lock is held until the child has exec'd (which is when `spawn`
/// returns), so it holds no file of ours open, and is released before anyone waits for it.
fn spawn_locked(command: &mut Command) -> io::Result<Child> {
    let _starting = EXEC_RACE.read().unwrap_or_else(PoisonError::into_inner);
    command.spawn()
}

/// `command.output()`: stdin is empty, stdout and stderr are captured. Only the start is locked.
fn output_locked(command: &mut Command) -> io::Result<Output> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    spawn_locked(command)?.wait_with_output()
}

/// `command.status()`: the child's streams are inherited. Only the start is locked.
#[cfg(unix)]
fn status_locked(command: &mut Command) -> io::Result<ExitStatus> {
    spawn_locked(command)?.wait()
}

fn page(class: &str) -> String {
    format!("class {class} extends StatelessWidget {{ const {class}({{super.key}}); }}")
}

fn project() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    fs::create_dir_all(dir.path().join("lib/app")).unwrap();
    fs::write(dir.path().join("lib/app/page.dart"), page("HomePage")).unwrap();
    dir
}

fn fsp(dir: &Path, args: &[&str]) -> (bool, String) {
    let out = output_locked(
        Command::new(env!("CARGO_BIN_EXE_fsp"))
            .args(args)
            .current_dir(dir),
    )
    .unwrap();
    assert!(
        out.stdout.is_empty(),
        "stdout: {}",
        String::from_utf8_lossy(&out.stdout)
    );
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn gen_and_check_report_success() {
    let dir = project();
    assert_eq!(
        fsp(dir.path(), &["check"]),
        (true, "✓ 1 route, no errors\n".into())
    );
    assert!(
        !dir.path().join("lib/app.g.dart").exists(),
        "check must not write"
    );
    assert_eq!(
        fsp(dir.path(), &["gen"]),
        (true, "✓ 1 route → lib/app.g.dart\n".into())
    );
    assert_eq!(
        fsp(dir.path(), &["gen"]),
        (true, "✓ 1 route, lib/app.g.dart unchanged\n".into())
    );
    assert_eq!(
        fsp(dir.path(), &["check"]),
        (true, "✓ 1 route, no errors\n".into())
    );
}

/// `check` writes and compares nothing, so it passes while the committed output is stale; the
/// docs/getting-started.md says so, and tells CI to run `gen` and then fail on a diff to catch that.
#[test]
fn check_passes_while_the_committed_output_is_stale() {
    let dir = project();
    assert!(fsp(dir.path(), &["gen"]).0);
    let out = dir.path().join("lib/app.g.dart");
    let committed = fs::read_to_string(&out).unwrap();

    // A new route the committed file knows nothing about.
    fs::create_dir_all(dir.path().join("lib/app/about")).unwrap();
    fs::write(
        dir.path().join("lib/app/about/page.dart"),
        page("AboutPage"),
    )
    .unwrap();
    assert_eq!(
        fsp(dir.path(), &["check"]),
        (true, "✓ 2 routes, no errors\n".into())
    );
    assert_eq!(fs::read_to_string(&out).unwrap(), committed, "check wrote");

    // `gen` is what brings it up to date, and shows up as a diff.
    assert_eq!(
        fsp(dir.path(), &["gen"]),
        (true, "✓ 2 routes → lib/app.g.dart\n".into())
    );
    assert_ne!(fs::read_to_string(&out).unwrap(), committed);
}

#[test]
fn check_failure_keeps_its_exit_code() {
    let dir = project();
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "class P extends StatelessWidget { const P({required this.x}); final int x; }",
    )
    .unwrap();
    let (ok, err) = fsp(dir.path(), &["check"]);
    assert!(
        !ok && err.contains("1 error(s)") && !err.contains('✓'),
        "{err}"
    );
}

#[test]
fn new_generates_typed_routes_and_says_so() {
    let dir = project();
    let (ok, err) = fsp(dir.path(), &["new", "products/[id]"]);
    assert!(ok, "{err}");
    assert!(
        err.contains("  new   lib/app/products/$id/page.dart"),
        "{err}"
    );
    assert!(
        err.trim_end().ends_with("✓ 2 routes → lib/app.g.dart"),
        "{err}"
    );
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(
        code.contains("final class ProductsIdRoute extends TypedLocation"),
        "{code}"
    );
}

#[test]
fn new_group_layout_needs_no_page() {
    let dir = project();
    let (ok, err) = fsp(dir.path(), &["new", "(account)", "--layout"]);
    assert!(ok, "{err}");
    assert!(dir.path().join("lib/app/(account)/layout.dart").exists());
    assert!(!dir.path().join("lib/app/(account)/page.dart").exists());
    assert!(
        err.trim_end().ends_with("✓ 1 route → lib/app.g.dart"),
        "{err}"
    );
}

#[test]
fn new_observe_writes_the_hooks_and_the_generated_file_attaches_them() {
    let dir = project();
    let (ok, err) = fsp(dir.path(), &["new", "orders/[id]", "--observe"]);
    assert!(ok, "{err}");
    assert!(
        err.contains("  new   lib/app/orders/$id/observe.dart"),
        "{err}"
    );
    let observe = fs::read_to_string(dir.path().join("lib/app/orders/$id/observe.dart")).unwrap();
    assert!(
        observe.contains("void onEnter(Ref ref, {required String id}) {}"),
        "{observe}"
    );
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(
        code.contains("observeAttach(router, _observeAt, container: container);"),
        "{code}"
    );
    // `fsp new` with nothing to write names every flag, this one included.
    let (ok, err) = fsp(dir.path(), &["new", "(oops)"]);
    assert!(!ok);
    assert!(
        err.contains("nothing to create: a (group) folder has no page; also pass --action, --layout, --loading, --error, --not-found, --guard, --observe or --transition"),
        "{err}"
    );
}

#[test]
fn new_names_the_files_it_left_behind_when_gen_fails() {
    let dir = project();
    // A bare group has nothing to scaffold.
    let (ok, err) = fsp(dir.path(), &["new", "(oops)"]);
    assert!(!ok);
    assert!(err.contains("nothing to create"), "{err}");
    // Break the tree, then scaffold something: gen fails, and the message lists what was written.
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "class P extends StatelessWidget { const P({required this.x}); final int x; }",
    )
    .unwrap();
    let (ok, err) = fsp(dir.path(), &["new", "docs"]);
    assert!(!ok);
    assert!(
        err.contains("`fsp new` created:\n  lib/app/docs/page.dart\n"),
        "{err}"
    );
    assert!(err.contains("Fix or delete them"), "{err}");
}

// --- watch -------------------------------------------------------------------

struct Watch {
    child: Child,
    log: std::path::PathBuf,
}

impl Watch {
    fn start(dir: &Path) -> Watch {
        Watch::start_with(dir, &[])
    }

    fn start_with(dir: &Path, env: &[(&str, &str)]) -> Watch {
        let log = dir.join("watch.log");
        let file = fs::File::create(&log).unwrap();
        let child = spawn_locked(
            Command::new(env!("CARGO_BIN_EXE_fsp"))
                .arg("watch")
                .envs(env.iter().copied())
                .current_dir(dir)
                .stdout(Stdio::null())
                .stderr(file),
        )
        .unwrap();
        let w = Watch { child, log };
        w.wait_for("watching lib/app/");
        w
    }

    fn text(&self) -> String {
        let mut s = String::new();
        fs::File::open(&self.log)
            .unwrap()
            .read_to_string(&mut s)
            .unwrap();
        s
    }

    fn lines(&self) -> usize {
        self.text().lines().count()
    }

    fn wait_for(&self, needle: &str) {
        let end = Instant::now() + Duration::from_secs(10);
        while !self.text().contains(needle) {
            assert!(
                Instant::now() < end,
                "timed out waiting for `{needle}`; got:\n{}",
                self.text()
            );
            sleep(Duration::from_millis(50));
        }
    }

    /// Long enough for a debounce, an event burst and a regeneration to have finished.
    fn settle(&self) {
        sleep(Duration::from_millis(700));
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn watch_is_quiet_when_idle_and_reacts_once_per_change() {
    let dir = project();
    let root = dir.path();
    let w = Watch::start(root);
    w.settle();

    // Idle: the generator's own reads of lib/app must not retrigger it.
    sleep(Duration::from_secs(2));
    let text = w.text();
    assert!(
        text.starts_with("✓ 1 route → lib/app.g.dart (")
            && text.ends_with(")\nwatching lib/app/ …\n"),
        "{text}"
    );
    assert_eq!(w.lines(), 2, "{}", w.text());

    // A new page regenerates once.
    fs::create_dir_all(root.join("lib/app/about")).unwrap();
    fs::write(root.join("lib/app/about/page.dart"), page("AboutPage")).unwrap();
    w.wait_for("✓ 2 routes → lib/app.g.dart");
    w.settle();
    assert_eq!(w.lines(), 3, "{}", w.text());
    assert!(
        fs::read_to_string(root.join("lib/app.g.dart"))
            .unwrap()
            .contains("AboutRoute")
    );

    // Rewriting a file with the same content changes nothing, so it prints nothing.
    fs::write(root.join("lib/app/about/page.dart"), page("AboutPage")).unwrap();
    w.settle();
    assert_eq!(w.lines(), 3, "{}", w.text());

    // Deleting a folder regenerates. Moved out of the watched tree first, as an editor's
    // delete does: one change. `remove_dir_all` in place is two (the file, then the folder),
    // and a slow machine can let more than the debounce pass between them, which is a second
    // regeneration, not the one this counts.
    fs::rename(root.join("lib/app/about"), root.join("about.removed")).unwrap();
    fs::remove_dir_all(root.join("about.removed")).unwrap();
    w.wait_for("✓ 1 route → lib/app.g.dart (");
    w.settle();
    assert_eq!(w.lines(), 4, "{}", w.text());
    assert!(
        !fs::read_to_string(root.join("lib/app.g.dart"))
            .unwrap()
            .contains("AboutRoute")
    );

    // An invalid file prints its error once, and fixing it says so.
    fs::write(
        root.join("lib/app/page.dart"),
        "class P extends StatelessWidget { const P({required this.x}); final int x; }",
    )
    .unwrap();
    w.wait_for("1 error(s)");
    w.settle();
    let text = w.text();
    assert_eq!(text.matches("1 error(s)").count(), 1, "{text}");
    assert_eq!(text.matches("can't fill `x`").count(), 1, "{text}");
    let before = w.lines();
    fs::write(root.join("lib/app/page.dart"), page("HomePage")).unwrap();
    w.wait_for("✓ 1 route, lib/app.g.dart unchanged");
    w.settle();
    assert_eq!(w.lines(), before + 1, "{}", w.text());
}

#[test]
fn watch_ignores_an_output_file_inside_the_app_folder() {
    let dir = project();
    let root = dir.path();
    fs::write(
        root.join("pubspec.yaml"),
        "name: demo\nfespalier:\n  output: lib/app/routes.g.dart\n",
    )
    .unwrap();
    let w = Watch::start(root);
    w.settle();
    sleep(Duration::from_secs(1));
    // Writing routes.g.dart into the watched folder must not loop.
    assert_eq!(w.lines(), 2, "{}", w.text());
}

/// An enum a segment names is declared under `lib/` but outside the app folder, and `watch`
/// sees it: renaming the enum breaks the route, renaming it back mends it.
#[test]
fn watch_follows_an_enum_declared_outside_the_app_folder() {
    let dir = project();
    let root = dir.path();
    fs::create_dir_all(root.join("lib/models")).unwrap();
    fs::create_dir_all(root.join("lib/app/shop/$category")).unwrap();
    fs::write(
        root.join("lib/models/category.dart"),
        "enum Category { shoes, hats }\n",
    )
    .unwrap();
    fs::write(
        root.join("lib/app/shop/$category/page.dart"),
        format!("import 'package:demo/models/category.dart';\n{}", "class ShopPage extends StatelessWidget { const ShopPage({super.key, required this.category}); final Category category; }"),
    )
    .unwrap();
    let w = Watch::start(root);
    w.settle();
    assert!(
        w.text().starts_with("✓ 2 routes → lib/app.g.dart ("),
        "{}",
        w.text()
    );
    assert!(
        fs::read_to_string(root.join("lib/app.g.dart"))
            .unwrap()
            .contains("Category.values")
    );

    // Not a Dart file: nothing to regenerate.
    fs::write(root.join("lib/models/notes.txt"), "hello").unwrap();
    w.settle();
    assert_eq!(w.lines(), 2, "{}", w.text());

    fs::write(
        root.join("lib/models/category.dart"),
        "enum Kind { shoes, hats }\n",
    )
    .unwrap();
    w.wait_for("error(s)");
    w.settle();
    assert!(w.text().contains("Category"), "{}", w.text());
    let broken = w.lines();
    fs::write(
        root.join("lib/models/category.dart"),
        "enum Category { shoes, hats }\n",
    )
    .unwrap();
    w.wait_for("✓ 2 routes, lib/app.g.dart unchanged");
    w.settle();
    assert!(w.lines() > broken, "{}", w.text());
}

/// `watch` with `format: true` runs `dart format` when the generated code changes, and not
/// when a save leaves it as it was (a widget's `build`, a file the generator doesn't read).
#[cfg(unix)]
#[test]
fn watch_formats_only_code_it_has_not_formatted_before() {
    let dir = project();
    let root = dir.path();
    fs::write(
        root.join("pubspec.yaml"),
        "name: demo\nfespalier:\n  format: true\n",
    )
    .unwrap();
    let dart = root.join("counting-dart");
    write_executable(
        &dart,
        "#!/bin/sh\n[ \"$1\" = format ] || exit 2\necho x >> \"$FAKE_DART_LOG\"\necho '// formatted'\ncat\n",
    );
    let calls = root.join("dart-calls.log");
    let count = || fs::read_to_string(&calls).map_or(0, |s| s.lines().count());
    let env = [
        ("FSP_DART", dart.to_str().unwrap()),
        ("FAKE_DART_LOG", calls.to_str().unwrap()),
    ];
    let w = Watch::start_with(root, &env);
    w.settle();
    assert_eq!(count(), 1, "{}", w.text());
    let output = || fs::read_to_string(root.join("lib/app.g.dart")).unwrap();
    assert!(output().starts_with("// formatted\n"));

    // A save that doesn't change the generated code: the tree is new, the code isn't.
    fs::write(
        root.join("lib/app/page.dart"),
        format!("{}\n// build() changed\n", page("HomePage")),
    )
    .unwrap();
    w.settle();
    // A file the generator doesn't read.
    fs::create_dir_all(root.join("lib/app/_widgets")).unwrap();
    fs::write(root.join("lib/app/_widgets/card.dart"), "class Card {}").unwrap();
    w.settle();
    assert_eq!(count(), 1, "no new output, no `dart`: {}", w.text());
    assert_eq!(w.lines(), 2, "{}", w.text());

    // A new route changes the code: formatted once, and written formatted.
    fs::create_dir_all(root.join("lib/app/about")).unwrap();
    fs::write(root.join("lib/app/about/page.dart"), page("AboutPage")).unwrap();
    w.wait_for("✓ 2 routes → lib/app.g.dart");
    w.settle();
    assert_eq!(count(), 2, "{}", w.text());
    assert!(output().starts_with("// formatted\n") && output().contains("AboutRoute"));

    // Deleting it again writes the smaller code, formatted.
    fs::remove_dir_all(root.join("lib/app/about")).unwrap();
    w.wait_for("✓ 1 route → lib/app.g.dart");
    w.settle();
    assert!(output().starts_with("// formatted\n") && !output().contains("AboutRoute"));
}

// --- routes, --json, --format ------------------------------------------------

/// Like `fsp`, but returns stdout too, and takes extra environment.
fn fsp_full(dir: &Path, args: &[&str], env: &[(&str, &str)]) -> (bool, String, String) {
    let out = output_locked(
        Command::new(env!("CARGO_BIN_EXE_fsp"))
            .args(args)
            .envs(env.iter().copied())
            .current_dir(dir),
    )
    .unwrap();
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn routes_prints_the_table_and_json_lines() {
    let dir = project();
    fs::create_dir_all(dir.path().join("lib/app/products/$id")).unwrap();
    fs::write(
        dir.path().join("lib/app/products/$id/page.dart"),
        "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id, this.tab}); final int id; final String? tab; }",
    )
    .unwrap();
    let (ok, out, err) = fsp_full(dir.path(), &["routes"], &[]);
    assert!(ok, "{err}");
    assert_eq!(
        out,
        "/              HomeRoute     page.dart\n/products/:id  ProductRoute  products/$id/page.dart\n"
    );
    let (ok, out, err) = fsp_full(dir.path(), &["routes", "--json"], &[]);
    assert!(ok, "{err}");
    let rows: Vec<serde_json::Value> = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[1]["pattern"], "/products/:id");
    assert_eq!(rows[1]["route"], "ProductRoute");
    assert_eq!(rows[1]["file"], "lib/app/products/$id/page.dart");
    assert_eq!(rows[1]["tags"], serde_json::json!([]));
    assert_eq!(
        rows[1]["params"],
        serde_json::json!([{"name": "id", "type": "int", "in": "path"}, {"name": "tab", "type": "String?", "in": "query"}])
    );
}

#[test]
fn routes_graph_prints_mermaid_by_default_and_dot_on_request() {
    let dir = project();
    fs::create_dir_all(dir.path().join("lib/app/cart")).unwrap();
    fs::write(dir.path().join("lib/app/cart/page.dart"), page("CartPage")).unwrap();
    let mermaid = "flowchart TD\n  subgraph rootnav[\"root navigator\"]\n    n0[\"/<br/>HomeRoute\"]\n    n1[\"/cart<br/>CartRoute\"]\n  end\n  n0 --> n1\n";
    for args in [
        &["routes", "--graph"][..],
        &["routes", "--graph", "mermaid"],
        &["routes", "--graph=mermaid"],
    ] {
        let (ok, out, err) = fsp_full(dir.path(), args, &[]);
        assert!(ok, "{err}");
        assert_eq!(out, mermaid, "{args:?}");
    }
    let (ok, out, err) = fsp_full(dir.path(), &["routes", "--graph", "dot"], &[]);
    assert!(ok, "{err}");
    assert!(out.starts_with("digraph routes {\n"), "{out}");
    assert!(out.contains("n0 -> n1;"), "{out}");
    // Flags after it are flags, not its value.
    let (ok, out, err) = fsp_full(dir.path(), &["routes", "--graph", "--project", "."], &[]);
    assert!(ok, "{err}");
    assert_eq!(out, mermaid);

    let (ok, _, err) = fsp_full(dir.path(), &["routes", "--graph", "svg"], &[]);
    assert!(
        !ok && err.contains("mermaid") && err.contains("dot"),
        "{err}"
    );
    let (ok, _, err) = fsp_full(dir.path(), &["routes", "--graph", "--json"], &[]);
    assert!(!ok && err.contains("--json"), "{err}");
}

#[test]
fn routes_graph_json_prints_the_tree_the_devtools_extension_reads() {
    let dir = project();
    fs::create_dir_all(dir.path().join("lib/app/cart")).unwrap();
    fs::write(dir.path().join("lib/app/cart/page.dart"), page("CartPage")).unwrap();
    let (ok, out, err) = fsp_full(dir.path(), &["routes", "--graph", "json"], &[]);
    assert!(ok, "{err}");
    // Indented, ending in one newline, and the same on every run.
    assert!(out.starts_with("{\n  \"protocol\": 1,\n"), "{out}");
    assert!(out.ends_with("}\n") && !out.ends_with("\n\n"), "{out}");
    let tree: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(tree["protocol"], 1);
    assert_eq!(tree["appDir"], "lib/app");
    assert_eq!(tree["items"][0]["route"], "HomeRoute");
    assert_eq!(tree["items"][0]["children"][0]["pattern"], "/cart");
    let (_, again, _) = fsp_full(dir.path(), &["routes", "--graph=json"], &[]);
    assert_eq!(again, out);

    // `--json` is the rows, `--graph` the drawings: the two do not mix.
    let (ok, _, err) = fsp_full(dir.path(), &["routes", "--graph", "json", "--json"], &[]);
    assert!(!ok && err.contains("--json"), "{err}");
}

const LINKS: &str = "fespalier:\n  links:\n    domains: [shop.example.com]\n    android_package: com.example.shop\n    android_sha256: [\"14:6D:E9:83:C5:73:06:50:D8:EE:B9:95:2F:34:FC:64:16:A0:83:42:E6:1D:BE:A8:8A:04:96:B2:3F:CF:44:E5\"]\n    ios_app_id: ABCDE12345.com.example.shop\n";

#[test]
fn links_writes_the_files_and_check_follows_them() {
    let dir = project();
    fs::create_dir_all(dir.path().join("lib/app/products/$id")).unwrap();
    fs::write(
        dir.path().join("lib/app/products/$id/page.dart"),
        "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id}); final int id; }",
    )
    .unwrap();
    let pubspec = dir.path().join("pubspec.yaml");
    let base = fs::read_to_string(&pubspec).unwrap();

    // Without a `links:` section it says what to add, and writes nothing.
    let (ok, _, err) = fsp_full(dir.path(), &["links"], &[]);
    assert!(
        !ok && err.contains("no `links:` in the `fespalier:` section"),
        "{err}"
    );
    assert!(!dir.path().join("links").exists());

    fs::write(&pubspec, format!("{base}{LINKS}")).unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["links", "--check"], &[]);
    assert!(!ok, "{err}");
    assert!(err.contains("links/web/sitemap.xml is missing"), "{err}");
    assert!(
        err.contains("5 file(s) out of date; run `fsp links`"),
        "{err}"
    );
    assert!(!dir.path().join("links").exists(), "--check writes nothing");

    let (ok, out, err) = fsp_full(dir.path(), &["links"], &[]);
    assert!(ok && out.is_empty(), "{err}");
    assert!(
        err.contains("wrote links/android/intent-filters.xml"),
        "{err}"
    );
    assert!(
        err.contains("✓ links: 5 files in links (5 written, 0 unchanged)"),
        "{err}"
    );
    let sitemap = fs::read_to_string(dir.path().join("links/web/sitemap.xml")).unwrap();
    assert!(
        sitemap.contains("<loc>https://shop.example.com/</loc>"),
        "{sitemap}"
    );
    let filters = fs::read_to_string(dir.path().join("links/android/intent-filters.xml")).unwrap();
    assert!(
        filters.contains("<data android:pathPattern=\"/products/..*\" />"),
        "{filters}"
    );
    let aasa = fs::read_to_string(
        dir.path()
            .join("links/web/.well-known/apple-app-site-association"),
    )
    .unwrap();
    assert!(aasa.contains("\"/products/?*\""), "{aasa}");

    // Again: nothing to write, and check passes.
    let (ok, _, err) = fsp_full(dir.path(), &["links"], &[]);
    assert!(
        ok && err.contains("(0 written, 5 unchanged)") && !err.contains("wrote"),
        "{err}"
    );
    let (ok, _, err) = fsp_full(dir.path(), &["links", "--check"], &[]);
    assert!(
        ok && err.contains("✓ links: 5 files in links are up to date"),
        "{err}"
    );

    // A new route makes the files stale, and `fsp links` brings them back.
    fs::create_dir_all(dir.path().join("lib/app/about")).unwrap();
    fs::write(
        dir.path().join("lib/app/about/page.dart"),
        page("AboutPage"),
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["links", "--check"], &[]);
    assert!(
        !ok && err.contains("links/web/sitemap.xml is out of date"),
        "{err}"
    );
    assert!(fsp_full(dir.path(), &["links"], &[]).0);
    assert!(fsp_full(dir.path(), &["links", "--check"], &[]).0);

    // `linkable = false` takes the route out again.
    fs::write(
        dir.path().join("lib/app/about/route.dart"),
        "const linkable = false;",
    )
    .unwrap();
    assert!(!fsp_full(dir.path(), &["links", "--check"], &[]).0);
    assert!(fsp_full(dir.path(), &["links"], &[]).0);
    let sitemap = fs::read_to_string(dir.path().join("links/web/sitemap.xml")).unwrap();
    assert!(!sitemap.contains("/about"), "{sitemap}");

    // Dropping a platform from the config leaves its files stale: `--check` says so, `fsp links` removes them.
    let android_only = LINKS.replace("    ios_app_id: ABCDE12345.com.example.shop\n", "");
    fs::write(&pubspec, format!("{base}{android_only}")).unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["links", "--check"], &[]);
    assert!(
        !ok && err.contains(
            "links/web/.well-known/apple-app-site-association is not wanted by this config"
        ),
        "{err}"
    );
    let (ok, _, err) = fsp_full(dir.path(), &["links"], &[]);
    assert!(
        ok && err.contains("removed links/ios/associated-domains.entitlements"),
        "{err}"
    );
    assert!(
        !dir.path()
            .join("links/web/.well-known/apple-app-site-association")
            .exists()
    );
    assert!(
        dir.path()
            .join("links/web/.well-known/assetlinks.json")
            .exists()
    );
    assert!(fsp_full(dir.path(), &["links", "--check"], &[]).0);

    // `out:` moves everything.
    fs::write(
        &pubspec,
        format!("{base}{android_only}    out: deeplinks/x\n"),
    )
    .unwrap();
    assert!(fsp_full(dir.path(), &["links"], &[]).0);
    assert!(dir.path().join("deeplinks/x/web/sitemap.xml").exists());
}

#[test]
fn links_reports_config_and_route_errors_with_a_failing_exit() {
    let dir = project();
    let pubspec = dir.path().join("pubspec.yaml");
    let base = fs::read_to_string(&pubspec).unwrap();
    fs::write(
        &pubspec,
        format!("{base}fespalier:\n  links:\n    scheme: myshop\n"),
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["links"], &[]);
    assert!(
        !ok && err.contains("`fespalier.links.domains` is required"),
        "{err}"
    );
    // The routing commands don't read the values.
    let (ok, _, err) = fsp_full(dir.path(), &["check"], &[]);
    assert!(ok, "{err}");

    fs::write(&pubspec, format!("{base}{LINKS}")).unwrap();
    fs::write(
        dir.path().join("lib/app/route.dart"),
        "const linkable = false;",
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["links"], &[]);
    assert!(!ok && err.contains("no route can be linked"), "{err}");
    fs::write(
        dir.path().join("lib/app/route.dart"),
        "const linkable = nope;",
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["links"], &[]);
    assert!(
        !ok && err.contains("`linkable` must be a `true` or `false` literal"),
        "{err}"
    );
    assert!(err.contains("1 error(s); no links"), "{err}");
    assert!(!dir.path().join("links").exists());
}

#[test]
fn check_reports_a_bad_deferred_with_a_failing_exit() {
    let dir = project();
    let route = dir.path().join("lib/app/route.dart");
    fs::write(&route, "const deferred = nope;").unwrap();
    let (ok, err) = fsp(dir.path(), &["check"]);
    assert!(
        !ok && err.contains("`deferred` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it"),
        "{err}"
    );
    fs::write(&route, "const nothing = 1;").unwrap();
    let (ok, err) = fsp(dir.path(), &["check"]);
    assert!(
        !ok && err.contains("expected `const caseSensitive = false;` (or `true`), `const paths = {'fr': 'produits'};`, `const nest = false;`, `const linkable = false;`, `const remount = Remount.onSegments;`, `const deferred = true;` or `const freshness = Freshness(staleTime: Duration(minutes: 5));`"),
        "{err}"
    );
    // The key in pubspec.yaml is serde's to check.
    fs::write(&route, "const deferred = true;").unwrap();
    let pubspec = dir.path().join("pubspec.yaml");
    fs::write(&pubspec, "name: demo\nfespalier:\n  deferred: maybe\n").unwrap();
    let (ok, err) = fsp(dir.path(), &["check"]);
    assert!(
        !ok && err.contains("invalid pubspec.yaml: fespalier.deferred: invalid type: string \"maybe\", expected a boolean at line 3 column 13"),
        "{err}"
    );
}

#[test]
fn check_says_a_type_in_a_deferred_page_belongs_in_a_file_of_its_own() {
    let dir = project();
    fs::write(
        dir.path().join("lib/app/route.dart"),
        "const deferred = true;",
    )
    .unwrap();
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "enum Sort { name, price }\nclass HomePage extends StatelessWidget { const HomePage({super.key, this.sort}); final Sort? sort; }",
    )
    .unwrap();
    let (ok, err) = fsp(dir.path(), &["check"]);
    assert!(
        !ok && err.contains("`Sort` is declared in this page.dart, which is deferred")
            && err.contains("Move `Sort` to a file of its own"),
        "{err}"
    );
}

#[test]
fn routes_fails_on_errors() {
    let dir = project();
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "class P extends StatelessWidget { const P({required this.x}); final int x; }",
    )
    .unwrap();
    let (ok, out, err) = fsp_full(dir.path(), &["routes"], &[]);
    assert!(
        !ok && out.is_empty() && err.contains("1 error(s)"),
        "{out}{err}"
    );
}

#[test]
fn json_diagnostics_go_to_stdout_as_lines() {
    let dir = project();
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "class P extends StatelessWidget {\n  const P({required this.x});\n  final int x;\n}",
    )
    .unwrap();
    for cmd in ["check", "gen"] {
        let (ok, out, err) = fsp_full(dir.path(), &[cmd, "--json"], &[]);
        assert!(!ok, "{err}");
        assert!(
            !err.contains("┌─"),
            "no codespan rendering with --json: {err}"
        );
        assert!(err.contains("1 error(s)"), "{err}");
        let lines: Vec<serde_json::Value> = out
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 1, "{out}");
        assert_eq!(lines[0]["file"], "lib/app/page.dart");
        assert_eq!(lines[0]["severity"], "error");
        assert_eq!(lines[0]["line"], 2);
        assert!(lines[0]["column"].as_u64().unwrap() >= 1);
        assert!(
            lines[0]["message"]
                .as_str()
                .unwrap()
                .contains("can't fill `x`"),
            "{out}"
        );
    }
    // Clean projects print nothing on stdout.
    fs::write(dir.path().join("lib/app/page.dart"), page("HomePage")).unwrap();
    let (ok, out, _) = fsp_full(dir.path(), &["check", "--json"], &[]);
    assert!(ok && out.is_empty());
}

const NO_ROUTE: &str = "no route matches `/nope/x`, so it shows not-found [unknown_path]";

/// A string path that matches no route is a warning: shown, in the file that has it, and the
/// command still succeeds. With `unknown_path: error` `check` and `gen` fail, and `gen` still
/// writes the output.
#[test]
fn check_warns_about_a_string_path_that_matches_no_route() {
    let dir = project();
    let root = dir.path();
    fs::create_dir_all(root.join("lib/screens")).unwrap();
    fs::write(
        root.join("lib/screens/home.dart"),
        "void f(BuildContext context) {\n  context.go('/');\n  context.go('/nope/x');\n}\n",
    )
    .unwrap();

    let (ok, err) = fsp(root, &["check"]);
    assert!(ok, "{err}");
    assert!(err.contains("warning"), "{err}");
    assert!(err.contains("lib/screens/home.dart"), "{err}");
    assert!(err.contains(NO_ROUTE), "{err}");
    assert!(err.contains("✓ 1 route, no errors"), "{err}");

    let (ok, out, err) = fsp_full(root, &["check", "--json"], &[]);
    assert!(ok, "{err}");
    let lines: Vec<serde_json::Value> = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines.len(), 1, "{out}");
    assert_eq!(lines[0]["file"], "lib/screens/home.dart");
    assert_eq!(lines[0]["severity"], "warning");
    assert_eq!(lines[0]["line"], 3);
    assert_eq!(lines[0]["column"], 14);
    assert_eq!(lines[0]["message"], NO_ROUTE);

    fs::write(
        root.join("pubspec.yaml"),
        "name: demo\nfespalier:\n  lints:\n    unknown_path: error\n",
    )
    .unwrap();
    let (ok, err) = fsp(root, &["check"]);
    assert!(!ok, "{err}");
    assert!(
        err.contains("1 error(s) in string paths (`lints: unknown_path: error`)")
            && !err.contains("is up to date"),
        "{err}"
    );
    assert!(
        !root.join("lib/app.g.dart").exists(),
        "check writes nothing"
    );
    let (ok, err) = fsp(root, &["gen"]);
    assert!(!ok, "{err}");
    assert!(
        err.contains(
            "1 error(s) in string paths (`lints: unknown_path: error`); lib/app.g.dart is up to date"
        ),
        "{err}"
    );
    assert!(root.join("lib/app.g.dart").exists(), "gen still writes");

    // `off` skips it.
    fs::write(
        root.join("pubspec.yaml"),
        "name: demo\nfespalier:\n  lints:\n    unknown_path: off\n",
    )
    .unwrap();
    let (ok, err) = fsp(root, &["check"]);
    assert!(ok && !err.contains("warning"), "{err}");
}

/// `watch` runs again when a Dart file under `lib/` but outside the app folder changes.
#[test]
fn watch_rechecks_string_paths_outside_the_app_folder() {
    let dir = project();
    let root = dir.path();
    fs::create_dir_all(root.join("lib/screens")).unwrap();
    let w = Watch::start(root);
    w.wait_for("✓ 1 route → lib/app.g.dart");
    w.settle();
    let home = root.join("lib/screens/home.dart");

    fs::write(&home, "void f(BuildContext c) { c.go('/nope/x'); }\n").unwrap();
    w.wait_for(NO_ROUTE);
    w.wait_for("lib/screens/home.dart");
    w.settle();

    // Fixed: the success line comes again, and the warning does not.
    let mark = w.text().len();
    fs::write(&home, "void f(BuildContext c) { c.go('/'); }\n").unwrap();
    let end = Instant::now() + Duration::from_secs(10);
    while !w.text()[mark..].contains("✓ 1 route, lib/app.g.dart unchanged") {
        assert!(Instant::now() < end, "timed out; got:\n{}", w.text());
        sleep(Duration::from_millis(50));
    }
    w.settle();
    assert!(
        !w.text()[mark..].contains("no route matches"),
        "{}",
        w.text()
    );
}

/// A stand-in for `dart` whose `format` prepends a marker line to stdin.
#[cfg(unix)]
fn fake_dart(dir: &Path) -> std::path::PathBuf {
    let path = dir.join("fake-dart");
    write_executable(
        &path,
        "#!/bin/sh\n[ \"$1\" = format ] || exit 2\necho '// formatted'\ncat\n",
    );
    path
}

#[cfg(unix)]
#[test]
fn gen_format_formats_and_stays_unchanged_on_rerun() {
    let dir = project();
    let dart = fake_dart(dir.path());
    let env = [("FSP_DART", dart.to_str().unwrap())];
    let (ok, _, err) = fsp_full(dir.path(), &["gen", "--format"], &env);
    assert!(ok && err.contains("→ lib/app.g.dart"), "{err}");
    assert!(
        fs::read_to_string(dir.path().join("lib/app.g.dart"))
            .unwrap()
            .starts_with("// formatted\n// GENERATED")
    );
    let (ok, _, err) = fsp_full(dir.path(), &["gen", "--format"], &env);
    assert!(ok && err.contains("lib/app.g.dart unchanged"), "{err}");
    // Without the flag the file is unformatted again (the default doesn't format).
    let (ok, _, err) = fsp_full(dir.path(), &["gen"], &env);
    assert!(ok && err.contains("→ lib/app.g.dart"), "{err}");
    assert!(
        fs::read_to_string(dir.path().join("lib/app.g.dart"))
            .unwrap()
            .starts_with("// GENERATED")
    );
}

#[cfg(unix)]
#[test]
fn format_key_in_pubspec_turns_it_on() {
    let dir = project();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  format: true\n",
    )
    .unwrap();
    let dart = fake_dart(dir.path());
    let (ok, _, err) = fsp_full(
        dir.path(),
        &["gen"],
        &[("FSP_DART", dart.to_str().unwrap())],
    );
    assert!(ok, "{err}");
    assert!(
        fs::read_to_string(dir.path().join("lib/app.g.dart"))
            .unwrap()
            .starts_with("// formatted\n")
    );
}

#[test]
fn format_without_dart_warns_and_writes_unformatted() {
    let dir = project();
    let (ok, _, err) = fsp_full(
        dir.path(),
        &["gen", "--format"],
        &[("FSP_DART", "/nonexistent/dart")],
    );
    assert!(ok, "{err}");
    assert!(
        err.contains("warning: not formatting") && err.contains("not on PATH"),
        "{err}"
    );
    assert!(
        fs::read_to_string(dir.path().join("lib/app.g.dart"))
            .unwrap()
            .starts_with("// GENERATED")
    );
}

// --- route manifest ----------------------------------------------------------

/// The shape of `fsp routes --json`, pinned: keys, their order and their values for
/// a page in a group with a layout, a tab, a redirect and a meta.dart.
#[test]
fn routes_json_pins_the_manifest_fields() {
    let dir = project();
    let root = dir.path();
    let write = |rel: &str, body: &str| {
        let p = root.join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    };
    write(
        "(buyer)/layout.dart",
        "class BuyerLayout extends StatelessWidget { const BuyerLayout({super.key, required this.child}); final Widget child; }",
    );
    write(
        "(buyer)/products/$id/page.dart",
        "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id, this.tab, required this.data}); final int id; final String? tab; final Item data; }",
    );
    write(
        "(buyer)/products/$id/data.dart",
        "Future<Item> data(Ref ref, {required int id}) async => x;",
    );
    write(
        "(buyer)/products/$id/meta.dart",
        "const meta = PageMeta(code: 'B04');",
    );
    write("old/redirect.dart", "String redirect() => '/';");
    write(
        "(tabs)/layout.dart",
        "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.shell}); final StatefulNavigationShell shell; }",
    );
    write("(tabs)/one/page.dart", &page("OnePage"));
    write(
        "docs/$$rest/page.dart",
        "class DocsPage extends StatelessWidget { const DocsPage({super.key, required this.rest}); final List<String> rest; }",
    );
    write(
        "files/$$$path/page.dart",
        "class FilesPage extends StatelessWidget { const FilesPage({super.key, required this.path}); final List<String> path; }",
    );
    // A route on the root navigator (`navigator.dart`, inherited by the folder below it) and one
    // whose page the app builds (`present.dart`, which implies the root navigator).
    write("(tabs)/one/full/page.dart", &page("FullPage"));
    write(
        "(tabs)/one/full/navigator.dart",
        "const navigator = RouteNavigator.root;",
    );
    write("sheet/page.dart", &page("SheetPage"));
    write(
        "sheet/present.dart",
        "Page<void> present(LocalKey key, Widget child) => MySheet(key: key, child: child);",
    );
    let (ok, out, err) = fsp_full(root, &["routes", "--json"], &[]);
    assert!(ok, "{err}");
    let rows: Vec<&str> = out.lines().collect();
    assert_eq!(rows.len(), 8, "{out}");
    let row = |pattern: &str| {
        rows.iter()
            .find(|r| serde_json::from_str::<serde_json::Value>(r).unwrap()["pattern"] == pattern)
            .unwrap()
            .to_string()
    };
    // Key order is part of the shape (serde_json keeps it), so compare the text.
    assert_eq!(
        row("/products/:id"),
        r#"{"pattern":"/products/:id","route":"ProductRoute","file":"lib/app/(buyer)/products/$id/page.dart","tags":["data"],"params":[{"name":"id","type":"int","in":"path"},{"name":"tab","type":"String?","in":"query"}],"folder":"(buyer)/products/$id","presentation":"page","groups":["(buyer)"],"layouts":["(buyer)"],"tabs":[],"data_keys":["id"],"meta":"lib/app/(buyer)/products/$id/meta.dart","catch_all":null}"#
    );
    assert_eq!(
        row("/old"),
        r#"{"pattern":"/old","route":"OldRoute","file":"lib/app/old/redirect.dart","tags":["redirect"],"params":[],"folder":"old","presentation":"redirect","groups":[],"layouts":[],"tabs":[],"data_keys":null,"meta":null,"catch_all":null}"#
    );
    assert_eq!(
        row("/one"),
        r#"{"pattern":"/one","route":"OneRoute","file":"lib/app/(tabs)/one/page.dart","tags":[],"params":[],"folder":"(tabs)/one","presentation":"page","groups":["(tabs)"],"layouts":["(tabs)"],"tabs":[{"layout":"(tabs)","index":0,"branch":"one"}],"data_keys":null,"meta":null,"catch_all":null}"#
    );
    assert_eq!(
        row("/one/full"),
        r#"{"pattern":"/one/full","route":"FullRoute","file":"lib/app/(tabs)/one/full/page.dart","tags":["root"],"params":[],"folder":"(tabs)/one/full","presentation":"root","groups":["(tabs)"],"layouts":["(tabs)"],"tabs":[{"layout":"(tabs)","index":0,"branch":"one"}],"data_keys":null,"meta":null,"catch_all":null}"#
    );
    assert_eq!(
        row("/sheet"),
        r#"{"pattern":"/sheet","route":"SheetRoute","file":"lib/app/sheet/page.dart","tags":["present","root"],"params":[],"folder":"sheet","presentation":"custom","groups":[],"layouts":[],"tabs":[],"data_keys":null,"meta":null,"catch_all":null}"#
    );
    // A catch-all is the last path parameter, a List<String>, and named in `catch_all`.
    assert_eq!(
        row("/docs/*rest"),
        r#"{"pattern":"/docs/*rest","route":"DocsRoute","file":"lib/app/docs/$$rest/page.dart","tags":[],"params":[{"name":"rest","type":"List<String>","in":"path"}],"folder":"docs/$$rest","presentation":"page","groups":[],"layouts":[],"tabs":[],"data_keys":null,"meta":null,"catch_all":{"name":"rest","optional":false}}"#
    );
    let files: serde_json::Value = serde_json::from_str(&row("/files/*path?")).unwrap();
    assert_eq!(
        files["catch_all"],
        serde_json::json!({"name": "path", "optional": true})
    );
    // The app folder's own page has an empty folder.
    let home: serde_json::Value = serde_json::from_str(&row("/")).unwrap();
    assert_eq!(home["folder"], "");
    assert_eq!(home["layouts"], serde_json::json!([]));
}

/// Localized paths through the binary: the route table and `--json` list the spellings, and a
/// spelling that collides with another route fails `check` with a frame on both files.
#[test]
fn routes_lists_localized_spellings_and_check_reports_a_collision() {
    let dir = project();
    let root = dir.path();
    let write = |rel: &str, body: &str| {
        let p = root.join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    };
    write("products/page.dart", &page("ProductsPage"));
    write(
        "products/route.dart",
        "const paths = {'fr': 'produits', 'de': 'produkte'};",
    );
    write("about/page.dart", &page("AboutPage"));
    let (ok, out, err) = fsp_full(root, &["routes"], &[]);
    assert!(ok, "{err}");
    let lines: Vec<&str> = out.lines().collect();
    assert!(lines[1].starts_with("/about "), "{out}");
    assert!(lines[2].starts_with("/products "), "{out}");
    assert_eq!(&lines[3..], ["  fr  /produits", "  de  /produkte"], "{out}");
    let (ok, out, err) = fsp_full(root, &["routes", "--json"], &[]);
    assert!(ok, "{err}");
    let rows: Vec<serde_json::Value> = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let products = rows.iter().find(|r| r["pattern"] == "/products").unwrap();
    assert_eq!(
        products["paths"],
        serde_json::json!({"fr": "/produits", "de": "/produkte"})
    );
    assert!(
        rows.iter()
            .find(|r| r["pattern"] == "/about")
            .unwrap()
            .get("paths")
            .is_none()
    );
    assert_eq!(
        fsp(root, &["check"]),
        (true, "✓ 3 routes, no errors\n".into())
    );

    write("products/route.dart", "const paths = {'fr': 'about'};");
    let (ok, err) = fsp(root, &["check"]);
    assert!(!ok && err.contains("2 error(s)"), "{err}");
    assert!(
        err.contains("lib/app/products/route.dart") && err.contains("lib/app/about/page.dart"),
        "{err}"
    );
    assert!(
        err.contains("`fr: 'about'` makes /about, which about/page.dart serves too"),
        "{err}"
    );
}

#[test]
fn output_manifest_writes_a_second_library_that_check_knows_about() {
    let dir = project();
    let root = dir.path();
    fs::write(
        root.join("pubspec.yaml"),
        "name: demo\nfespalier:\n  output_manifest: lib/app.routes.g.dart\n",
    )
    .unwrap();
    assert_eq!(
        fsp(root, &["check"]),
        (true, "✓ 1 route, no errors\n".into())
    );
    assert!(
        !root.join("lib/app.routes.g.dart").exists(),
        "check must not write"
    );
    assert_eq!(
        fsp(root, &["gen"]),
        (
            true,
            "✓ 1 route → lib/app.g.dart, lib/app.routes.g.dart\n".into()
        )
    );
    let manifest = fs::read_to_string(root.join("lib/app.routes.g.dart")).unwrap();
    assert!(
        manifest.contains("abstract final class AppManifest {")
            && manifest.contains("import 'app.g.dart';"),
        "{manifest}"
    );
    assert!(
        !fs::read_to_string(root.join("lib/app.g.dart"))
            .unwrap()
            .contains("AppManifest")
    );
    assert_eq!(
        fsp(root, &["gen"]),
        (
            true,
            "✓ 1 route, lib/app.g.dart, lib/app.routes.g.dart unchanged\n".into()
        )
    );

    // With `meta: required`, a route without a meta.dart is an error naming its folder.
    fs::write(
        root.join("pubspec.yaml"),
        "name: demo\nfespalier:\n  meta: required\n",
    )
    .unwrap();
    let (ok, err) = fsp(root, &["check"]);
    assert!(
        !ok && err.contains("the app folder has no meta.dart") && err.contains("1 error(s)"),
        "{err}"
    );
    fs::write(root.join("lib/app/meta.dart"), "const meta = 'home';").unwrap();
    assert_eq!(
        fsp(root, &["check"]),
        (true, "✓ 1 route, no errors\n".into())
    );
}

#[test]
fn watch_ignores_a_manifest_file_inside_the_app_folder() {
    let dir = project();
    let root = dir.path();
    fs::write(
        root.join("pubspec.yaml"),
        "name: demo\nfespalier:\n  output_manifest: lib/app/routes.g.dart\n",
    )
    .unwrap();
    let w = Watch::start(root);
    w.settle();
    sleep(Duration::from_secs(1));
    // Writing the manifest into the watched folder must not loop.
    assert_eq!(w.lines(), 2, "{}", w.text());
    assert!(root.join("lib/app/routes.g.dart").exists());
}

/// `action.dart` through the binary: the route table and `--json` tag the route `action`
/// (the editors read `tags`, which only gains a value), and a misplaced one fails `check` with
/// a code frame.
#[test]
fn routes_tags_a_route_with_an_action_and_check_frames_a_bad_one() {
    let dir = project();
    let root = dir.path();
    let write = |rel: &str, body: &str| {
        let p = root.join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    };
    write(
        "orders/$id/page.dart",
        "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }",
    );
    write(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, required Object input}) async {}",
    );
    let (ok, out, err) = fsp_full(root, &["routes"], &[]);
    assert!(ok, "{err}");
    assert!(
        out.contains("OrderRoute  orders/$id/page.dart  (action)"),
        "{out}"
    );
    let (ok, out, err) = fsp_full(root, &["routes", "--json"], &[]);
    assert!(ok, "{err}");
    let row = out
        .lines()
        .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap())
        .find(|r| r["pattern"] == "/orders/:id")
        .unwrap();
    assert_eq!(row["tags"], serde_json::json!(["action"]));

    // Without `input`: the error points at the function.
    write(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id}) async {}",
    );
    let (ok, _, err) = fsp_full(root, &["check"], &[]);
    assert!(!ok);
    assert!(err.contains("action() needs an `input` parameter"), "{err}");
    assert!(
        err.contains("┌─ lib/app/orders/$id/action.dart:1:"),
        "{err}"
    );
    assert!(
        err.contains("Future<void> action(Ref ref, {required int id}) async {}"),
        "{err}"
    );
}

const MAESTRO: &str = "fespalier:\n  semantics_ids: true\n  maestro:\n    url: http://localhost:8080\n    link: http://localhost:8080/#\n    samples:\n      products/$id: 1\n";

#[test]
fn maestro_writes_the_flows_and_check_follows_them() {
    let dir = project();
    fs::create_dir_all(dir.path().join("lib/app/products/$id")).unwrap();
    fs::write(
        dir.path().join("lib/app/products/$id/page.dart"),
        "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id}); final int id; }",
    )
    .unwrap();
    fs::create_dir_all(dir.path().join("lib/app/orders/$id")).unwrap();
    fs::write(
        dir.path().join("lib/app/orders/$id/page.dart"),
        "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }",
    )
    .unwrap();
    let pubspec = dir.path().join("pubspec.yaml");
    let base = fs::read_to_string(&pubspec).unwrap();
    let flow = |name: &str| dir.path().join(".maestro/routes").join(name);

    // Without a `maestro:` section it says what to add, and writes nothing.
    let (ok, out, err) = fsp_full(dir.path(), &["maestro"], &[]);
    assert!(!ok && out.is_empty(), "{err}");
    assert_eq!(
        err,
        "no `maestro:` in the `fespalier:` section of pubspec.yaml; say what the flows open, e.g.\n  fespalier:\n    semantics_ids: true\n    maestro:\n      app_id: com.example.shop\n"
    );
    assert!(!dir.path().join(".maestro").exists());

    // Without `semantics_ids` there is no identifier for a flow to wait for.
    let no_ids = MAESTRO.replace("  semantics_ids: true\n", "");
    fs::write(&pubspec, format!("{base}{no_ids}")).unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["maestro"], &[]);
    assert!(!ok, "{err}");
    assert_eq!(
        err,
        "`fsp maestro` finds each page by its semantics identifier: set `semantics_ids: true` in the `fespalier:` section of pubspec.yaml, then run `fsp gen`\n"
    );

    fs::write(&pubspec, format!("{base}{MAESTRO}")).unwrap();
    let (ok, out, err) = fsp_full(dir.path(), &["maestro", "--check"], &[]);
    assert!(!ok && out.is_empty(), "{err}");
    assert!(
        err.contains(".maestro/routes/home_route.yaml is missing"),
        "{err}"
    );
    assert!(
        err.contains("2 flow(s) out of date; run `fsp maestro`"),
        "{err}"
    );
    assert!(
        !dir.path().join(".maestro").exists(),
        "--check writes nothing"
    );

    let (ok, out, err) = fsp_full(dir.path(), &["maestro"], &[]);
    assert!(ok && out.is_empty(), "{err}");
    assert!(
        err.contains("  wrote .maestro/routes/home_route.yaml\n"),
        "{err}"
    );
    assert!(
        err.contains(
            "  skipped /orders/:id: no sample for orders/$id in `fespalier.maestro.samples`\n"
        ),
        "{err}"
    );
    assert!(
        err.ends_with(
            "✓ maestro: 2 flows in .maestro/routes (2 written, 0 unchanged); 1 route skipped\n"
        ),
        "{err}"
    );
    let product = fs::read_to_string(flow("product_route.yaml")).unwrap();
    assert!(
        product.contains("- openLink: \"http://localhost:8080/#/products/1\"\n"),
        "{product}"
    );
    assert!(
        product.contains("      id: \"route:/products/:id\"\n"),
        "{product}"
    );

    // Again: nothing to write, and check passes (a skip is not a failure).
    let (ok, _, err) = fsp_full(dir.path(), &["maestro"], &[]);
    assert!(
        ok && err.contains("(0 written, 2 unchanged); 1 route skipped") && !err.contains("wrote"),
        "{err}"
    );
    let (ok, _, err) = fsp_full(dir.path(), &["maestro", "--check"], &[]);
    assert!(
        ok && err.contains("  skipped /orders/:id")
            && err.ends_with("✓ maestro: 2 flows in .maestro/routes are up to date\n"),
        "{err}"
    );

    // A hand-written flow is never read, reported or removed.
    fs::write(flow("journey.yaml"), "appId: x\n---\n- launchApp\n").unwrap();
    fs::write(flow("config.yaml"), "flows: []\n").unwrap();

    // A new page makes the flows stale, and `fsp maestro` brings them back.
    fs::create_dir_all(dir.path().join("lib/app/about")).unwrap();
    fs::write(
        dir.path().join("lib/app/about/page.dart"),
        page("AboutPage"),
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["maestro", "--check"], &[]);
    assert!(
        !ok && err.contains(".maestro/routes/about_route.yaml is missing"),
        "{err}"
    );
    assert!(fsp_full(dir.path(), &["maestro"], &[]).0);
    assert!(fsp_full(dir.path(), &["maestro", "--check"], &[]).0);

    // Changing what a flow opens makes it out of date.
    let moved = MAESTRO.replace("products/$id: 1", "products/$id: 2");
    fs::write(&pubspec, format!("{base}{moved}")).unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["maestro", "--check"], &[]);
    assert!(
        !ok && err.contains(".maestro/routes/product_route.yaml is out of date")
            && err.contains("1 flow(s) out of date; run `fsp maestro`"),
        "{err}"
    );
    assert!(fsp_full(dir.path(), &["maestro"], &[]).0);

    // Deleting a page leaves its flow behind: `--check` says so, and `fsp maestro` removes it.
    fs::remove_dir_all(dir.path().join("lib/app/about")).unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["maestro", "--check"], &[]);
    assert!(
        !ok && err.contains(".maestro/routes/about_route.yaml is no longer a route's flow"),
        "{err}"
    );
    assert!(flow("about_route.yaml").exists());
    let (ok, _, err) = fsp_full(dir.path(), &["maestro"], &[]);
    assert!(
        ok && err.contains("  removed .maestro/routes/about_route.yaml\n"),
        "{err}"
    );
    assert!(!flow("about_route.yaml").exists());
    assert_eq!(
        fs::read_to_string(flow("journey.yaml")).unwrap(),
        "appId: x\n---\n- launchApp\n"
    );
    assert_eq!(
        fs::read_to_string(flow("config.yaml")).unwrap(),
        "flows: []\n"
    );
    assert!(fsp_full(dir.path(), &["maestro", "--check"], &[]).0);

    // A guard flow that is not there is named.
    let guarded = MAESTRO.replace(
        "    samples:",
        "    guard_flow: .maestro/sign-in.yaml\n    samples:",
    );
    fs::write(&pubspec, format!("{base}{guarded}")).unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["maestro"], &[]);
    assert!(
        !ok && err == "`fespalier.maestro.guard_flow`: .maestro/sign-in.yaml does not exist\n",
        "{err}"
    );
}

#[test]
fn maestro_reports_config_and_route_errors_with_a_failing_exit() {
    let dir = project();
    let pubspec = dir.path().join("pubspec.yaml");
    let base = fs::read_to_string(&pubspec).unwrap();
    fs::write(
        &pubspec,
        format!("{base}fespalier:\n  semantics_ids: true\n  maestro:\n    out: flows\n"),
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["maestro"], &[]);
    assert!(
        !ok && err
            .starts_with("`fespalier.maestro` needs `app_id` (Android and iOS) or `url` (the web)"),
        "{err}"
    );
    // A route error stops it before anything is written.
    let only_url =
        "fespalier:\n  semantics_ids: true\n  maestro:\n    url: http://localhost:8080\n";
    fs::write(&pubspec, format!("{base}{only_url}")).unwrap();
    fs::create_dir_all(dir.path().join("lib/app/bad name")).unwrap();
    fs::write(
        dir.path().join("lib/app/bad name/page.dart"),
        page("BadPage"),
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["maestro"], &[]);
    assert!(!ok && err.ends_with("1 error(s); no flows\n"), "{err}");
    assert!(!dir.path().join(".maestro").exists());
}

/// A build of `examples/shop`: a trimmed `main.dart.js` from a real release build (it holds the
/// table of deferred parts) and part files of the lengths that build had.
fn shop_build(shared_part: usize) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/shop-build/main.dart.js"),
        dir.path().join("main.dart.js"),
    )
    .unwrap();
    for (n, len) in [(1, 1090), (2, shared_part), (3, 1813)] {
        fs::write(
            dir.path().join(format!("main.dart.js_{n}.part.js")),
            vec![b'x'; len],
        )
        .unwrap();
    }
    dir
}

fn shop() -> String {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../examples/shop")
        .display()
        .to_string()
}

#[test]
fn size_reports_each_deferred_route_and_check_follows_the_budgets() {
    let (shop, cwd) = (shop(), tempfile::tempdir().unwrap());
    let build = shop_build(4169);
    let build_dir = build.path().display().to_string();
    let within = |more: &[&str]| {
        let mut a = vec!["size", "--project", &shop, "--build", &build_dir];
        a.extend(more);
        fsp_full(cwd.path(), &a, &[])
    };

    let (ok, out, err) = within(&[]);
    assert!(ok, "{err}");
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 4, "{out}");
    assert!(lines[0].starts_with("main.dart.js  ") && lines[0].ends_with("budget 3.0 MB"));
    assert!(lines[1].starts_with("/checkout      CheckoutRoute  checkout/page.dart  "));
    assert!(lines[1].contains("own 1090 B, shared 4169 B"));
    assert_eq!(
        lines[3],
        "shared  main.dart.js_2.part.js  4169 B (4.1 KB): /checkout, /products/:id"
    );
    assert_eq!(
        err,
        "✓ size: 6 routes, 2 deferred, 3 parts, within budget\n"
    );

    let (ok, out, err) = within(&["--json", "--check"]);
    assert!(ok, "{err}");
    let kinds: Vec<String> = out
        .lines()
        .map(|l| {
            let v: serde_json::Value = serde_json::from_str(l).unwrap();
            v["kind"].as_str().unwrap().to_string()
        })
        .collect();
    assert_eq!(kinds, ["main", "route", "route", "part", "part", "part"]);
    assert!(err.ends_with("within budget\n"), "{err}");

    // A bigger shared part puts both routes over their 8 KB.
    let big = shop_build(10_000);
    let big_dir = big.path().display().to_string();
    let over = |more: &[&str]| {
        let mut a = vec!["size", "--project", &shop, "--build", &big_dir];
        a.extend(more);
        fsp_full(cwd.path(), &a, &[])
    };
    let (ok, out, err) = over(&[]);
    assert!(ok, "{err}");
    assert!(out.contains("OVER budget 8.0 KB by 2898 B"), "{out}");
    assert!(out.contains("OVER budget 8.0 KB by 3621 B"), "{out}");
    assert_eq!(err, "✓ size: 6 routes, 2 deferred, 3 parts\n");
    let (ok, out, err) = over(&["--check"]);
    assert!(!ok);
    assert!(out.contains("OVER budget 8.0 KB by 2898 B"), "{out}");
    assert_eq!(err, "2 over budget: /checkout, /products/:id\n");
}

#[test]
fn size_check_needs_budgets_and_a_build() {
    let dir = project();
    let (ok, out, err) = fsp_full(dir.path(), &["size", "--check"], &[]);
    assert!(!ok && out.is_empty());
    assert_eq!(
        err,
        "`fsp size --check` checks the budgets in `fespalier.size` (`main`, `route`, `routes`), and there are none\n"
    );
    let (ok, out, err) = fsp_full(dir.path(), &["size"], &[]);
    assert!(!ok && out.is_empty());
    assert_eq!(
        err,
        "no main.dart.js in build/web: run `flutter build web` first (`fsp size` reads the JavaScript build)\n"
    );
}

// --- fsp test ---------------------------------------------------------------

#[test]
fn test_writes_the_file_and_check_follows_it() {
    let dir = project();
    fs::create_dir_all(dir.path().join("lib/app/cart")).unwrap();
    fs::write(dir.path().join("lib/app/cart/page.dart"), page("CartPage")).unwrap();
    fs::create_dir_all(dir.path().join("lib/app/members")).unwrap();
    fs::write(
        dir.path().join("lib/app/members/page.dart"),
        page("MembersPage"),
    )
    .unwrap();
    fs::write(
        dir.path().join("lib/app/members/guard.dart"),
        "String? guard(Ref ref) => null;",
    )
    .unwrap();
    let file = dir.path().join("test/routes/routes_test.dart");

    // Not written yet: `--check` says so and writes nothing.
    let (ok, out, err) = fsp_full(dir.path(), &["test", "--check"], &[]);
    assert!(!ok && out.is_empty(), "{err}");
    assert!(
        err.ends_with("  skipped /members: guarded by members/guard.dart; give test/routes/setup.dart an `overrides(String pattern)` that gets past it\ntest/routes/routes_test.dart is missing; run `fsp test`\n"),
        "{err}"
    );
    assert!(!dir.path().join("test").exists());

    let (ok, out, err) = fsp_full(dir.path(), &["test"], &[]);
    assert!(ok && out.is_empty(), "{err}");
    assert_eq!(
        err,
        "  skipped /members: guarded by members/guard.dart; give test/routes/setup.dart an `overrides(String pattern)` that gets past it\n  wrote test/routes/routes_test.dart\n✓ test: 2 routes in test/routes/routes_test.dart; 1 route skipped\n"
    );
    let written = fs::read_to_string(&file).unwrap();
    assert!(
        written.starts_with("// Written by `fsp test` from lib/app/: don't edit it, run `fsp test` again.\n// dart format off\n"),
        "{written}"
    );
    assert!(written.contains("'/cart at /cart'"), "{written}");
    assert!(
        written.contains("page: find.byType(\n        _i1.CartPage,\n      ),"),
        "{written}"
    );
    assert!(!written.contains("'/members at"), "{written}");

    let (ok, _, err) = fsp_full(dir.path(), &["test", "--check"], &[]);
    assert!(
        ok && err.ends_with("✓ test: test/routes/routes_test.dart is up to date (2 routes)\n"),
        "{err}"
    );
    let (ok, _, err) = fsp_full(dir.path(), &["test"], &[]);
    assert!(
        ok && !err.contains("wrote")
            && err.ends_with(
                "✓ test: 2 routes in test/routes/routes_test.dart (unchanged); 1 route skipped\n"
            ),
        "{err}"
    );

    // A new page makes the file stale, and only `fsp test` brings it back.
    fs::create_dir_all(dir.path().join("lib/app/about")).unwrap();
    fs::write(
        dir.path().join("lib/app/about/page.dart"),
        page("AboutPage"),
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["test", "--check"], &[]);
    assert!(
        !ok && err.ends_with("test/routes/routes_test.dart is out of date; run `fsp test`\n"),
        "{err}"
    );
    assert_eq!(fs::read_to_string(&file).unwrap(), written);
    assert!(fsp_full(dir.path(), &["test"], &[]).0);
    assert!(fsp_full(dir.path(), &["test", "--check"], &[]).0);

    // A setup with `overrides` gets a guarded route its test.
    fs::write(
        dir.path().join("test/routes/setup.dart"),
        "List<Override> overrides(String pattern) => [];\n",
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["test"], &[]);
    assert!(
        ok && !err.contains("skipped")
            && err.ends_with("✓ test: 4 routes in test/routes/routes_test.dart\n"),
        "{err}"
    );
    let with_setup = fs::read_to_string(&file).unwrap();
    assert!(
        with_setup.contains("import 'setup.dart' as setup;")
            && with_setup.contains("  // Guarded by members/guard.dart.\n"),
        "{with_setup}"
    );
}

#[test]
fn test_reports_config_and_file_errors_with_a_failing_exit() {
    let dir = project();
    let pubspec = dir.path().join("pubspec.yaml");
    let base = fs::read_to_string(&pubspec).unwrap();
    let file = dir.path().join("test/routes/routes_test.dart");

    fs::write(
        &pubspec,
        format!("{base}fespalier:\n  test:\n    timeout: 5\n"),
    )
    .unwrap();
    let (ok, out, err) = fsp_full(dir.path(), &["test"], &[]);
    assert!(!ok && out.is_empty(), "{err}");
    assert_eq!(
        err,
        "`fespalier.test.timeout` is in milliseconds of the test's fake clock, from 1000 to 600000, got `5`\n"
    );

    fs::write(
        &pubspec,
        format!("{base}fespalier:\n  test:\n    folder: test\n"),
    )
    .unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["test"], &[]);
    assert!(
        !ok && err.contains(
            "unknown field `folder`, expected one of `out`, `setup`, `timeout`, `samples`, `skip`"
        ),
        "{err}"
    );
    // The section is only read by `fsp test`: `fsp gen` and `fsp check` don't see it.
    fs::write(
        &pubspec,
        format!("{base}fespalier:\n  test:\n    timeout: 5\n"),
    )
    .unwrap();
    assert!(fsp_full(dir.path(), &["check"], &[]).0);

    // A file of that name that `fsp test` did not write is never overwritten.
    fs::write(&pubspec, &base).unwrap();
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, "void main() {}\n").unwrap();
    let (ok, _, err) = fsp_full(dir.path(), &["test"], &[]);
    assert_eq!(
        err,
        "test/routes/routes_test.dart was not written by `fsp test` (its first line isn't ``// Written by `fsp test` ``); move it, or set `fespalier.test.out` to another folder\n"
    );
    assert!(!ok);
    assert_eq!(fs::read_to_string(&file).unwrap(), "void main() {}\n");
}

// ---- fsp telemetry ----------------------------------------------------------------------------

/// A folder with a stand-in `docker`: it logs `cwd|args|bind|cors` per call to `$FAKE_LOG`, and
/// answers `compose version --short` with `$FAKE_VERSION` (default 2.29.7). `$FAKE_INFO`,
/// `$FAKE_UP`, `$FAKE_WAIT` and `$FAKE_DOWN` are the exit codes of `info`, `up -d`,
/// `wait dashboards` and `down`; `$FAKE_PS` is what `ps --services` lists and `$FAKE_RUN` the exit
/// code of the report run.
#[cfg(unix)]
fn fake_docker(dir: &Path) -> std::path::PathBuf {
    let bin = dir.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let path = bin.join("docker");
    write_executable(
        &path,
        r#"#!/bin/sh
echo "$PWD|$*|bind=$FSP_OTLP_BIND|cors=$FSP_OTLP_CORS_ORIGIN" >> "$FAKE_LOG"
case "$*" in
  "compose version --short") echo "${FAKE_VERSION:-2.29.7}"; exit 0 ;;
  "info --format {{.ServerVersion}}") exit "${FAKE_INFO:-0}" ;;
  *" up -d") exit "${FAKE_UP:-0}" ;;
  *" wait dashboards") exit "${FAKE_WAIT:-0}" ;;
  *" ps --status running --services") printf '%b' "${FAKE_PS-collector\nopenobserve\ndashboards\n}"; exit 0 ;;
  *" run --rm --no-deps -T dashboards python3 /fespalier/report.py") echo "the report"; exit "${FAKE_RUN:-0}" ;;
  *" down"*) exit "${FAKE_DOWN:-0}" ;;
esac
exit 9
"#,
    );
    bin
}

/// `fsp telemetry` in a folder with no project, the fake docker first on PATH and the stack in
/// `<root>/stack`. Returns success, stderr and the docker calls, with the stack path as `STACK`.
#[cfg(unix)]
fn telemetry(root: &Path, args: &[&str], extra: &[(&str, &str)]) -> (bool, String, Vec<String>) {
    let work = root.join("work");
    fs::create_dir_all(&work).unwrap();
    telemetry_from(root, &work, args, extra)
}

/// [`telemetry`] run from `work` instead of a folder with no project.
#[cfg(unix)]
fn telemetry_from(
    root: &Path,
    work: &Path,
    args: &[&str],
    extra: &[(&str, &str)],
) -> (bool, String, Vec<String>) {
    let bin = fake_docker(root);
    let log = root.join("docker.log");
    let stack = root.join("stack");
    let mut all = vec![
        ("PATH", bin.to_str().unwrap()),
        ("FAKE_LOG", log.to_str().unwrap()),
        ("FSP_TELEMETRY_DIR", stack.to_str().unwrap()),
    ];
    all.extend_from_slice(extra);
    let (ok, out, err) = fsp_full(work, &[&["telemetry"], args].concat(), &all);
    assert!(out.is_empty(), "stdout: {out}");
    let stack = stack.to_str().unwrap();
    let calls = fs::read_to_string(&log)
        .unwrap_or_default()
        .lines()
        .map(|l| l.replace(stack, "STACK"))
        .collect();
    (ok, err.replace(stack, "STACK"), calls)
}

#[test]
fn telemetry_no_start_writes_the_stack_without_docker_or_a_project() {
    let root = tempfile::tempdir().unwrap();
    let stack = root.path().join("stack");
    let work = root.path().join("work");
    fs::create_dir_all(&work).unwrap();
    // No pubspec.yaml above `work`, and no docker on PATH.
    let args = ["telemetry", "--no-start", "--dir", stack.to_str().unwrap()];
    let (ok, out, err) = fsp_full(&work, &args, &[("PATH", "")]);
    assert!(ok && out.is_empty(), "{out}{err}");
    assert_eq!(
        err,
        format!(
            "✓ wrote the telemetry stack to {}\n  start it in that folder: docker compose up -d   \
             (add --profile grafana for Grafana)\n",
            stack.display()
        )
    );
    for file in [
        "compose.yaml",
        ".env",
        "env.example",
        "collector/config.yaml",
        "openobserve/import.py",
        "openobserve/fields.json",
        "openobserve/report.py",
        "openobserve/dashboards/health.json",
        "grafana/dashboards/errors.json",
        "grafana/provisioning/datasources/fespalier.yaml",
    ] {
        assert!(stack.join(file).is_file(), "{file}");
    }
    // A second run keeps an edited .env.
    fs::write(stack.join(".env"), "FSP_O2_PORT=6000\n").unwrap();
    let (ok, _, _) = fsp_full(&work, &args, &[("PATH", "")]);
    assert!(ok);
    assert_eq!(
        fs::read_to_string(stack.join(".env")).unwrap(),
        "FSP_O2_PORT=6000\n"
    );
}

#[test]
fn telemetry_flags_that_exclude_each_other_are_clap_errors() {
    let dir = tempfile::tempdir().unwrap();
    for (flags, message) in [
        (
            ["--stop", "--grafana"],
            "error: the argument '--stop' cannot be used with '--grafana'",
        ),
        (
            ["--stop", "--reset"],
            "error: the argument '--stop' cannot be used with '--reset'",
        ),
        (
            ["--lan", "--reset"],
            "error: the argument '--lan' cannot be used with '--reset'",
        ),
        (
            ["--no-start", "--stop"],
            "error: the argument '--no-start' cannot be used with '--stop'",
        ),
        (
            ["--report", "--grafana"],
            "error: the argument '--report' cannot be used with '--grafana'",
        ),
        (
            ["--report", "--stop"],
            "error: the argument '--report' cannot be used with '--stop'",
        ),
    ] {
        let args = ["telemetry", flags[0], flags[1]];
        let (ok, _, err) = fsp_full(dir.path(), &args, &[]);
        assert!(!ok && err.starts_with(message), "{flags:?}: {err}");
    }
}

#[test]
fn telemetry_without_a_home_folder_asks_for_one() {
    let dir = tempfile::tempdir().unwrap();
    let out = output_locked(
        Command::new(env!("CARGO_BIN_EXE_fsp"))
            .arg("telemetry")
            .env_clear()
            .current_dir(dir.path()),
    )
    .unwrap();
    assert!(!out.status.success());
    assert_eq!(
        String::from_utf8_lossy(&out.stderr),
        "fsp telemetry can't find your home folder: pass --dir or set FSP_TELEMETRY_DIR\n"
    );
}

#[cfg(unix)]
#[test]
fn telemetry_stop_without_docker_says_so() {
    let root = tempfile::tempdir().unwrap();
    let empty = root.path().join("empty");
    fs::create_dir_all(&empty).unwrap();
    let stack = root.path().join("stack");
    let args = ["telemetry", "--stop", "--dir", stack.to_str().unwrap()];
    let (ok, _, err) = fsp_full(root.path(), &args, &[("PATH", empty.to_str().unwrap())]);
    assert!(!ok);
    assert_eq!(
        err,
        format!(
            "fsp telemetry needs Docker with Compose v2.20 or later: `docker compose version` \
             failed (No such file or directory (os error 2)). The stack's files are in {}; start \
             them with `docker compose up -d` in that folder.\n",
            stack.display()
        )
    );
    assert!(!stack.exists(), "--stop writes nothing");
}

#[cfg(unix)]
#[test]
fn telemetry_starts_the_stack_and_waits_for_the_importer() {
    let root = tempfile::tempdir().unwrap();
    let (ok, err, calls) = telemetry(root.path(), &[], &[]);
    assert!(ok, "{err}");
    assert_eq!(
        err,
        "✓ telemetry stack running: 4 dashboards in OpenObserve, folder fespalier; start with \
         fespalier · App health\n  \
         OpenObserve  http://localhost:5080  dev@fespalier.local / Fespalier-local-1\n  \
         OTLP         http://localhost:4318 (HTTP), localhost:4317 (gRPC)\n  \
         The app      FespalierOtel.endpoint() reaches it from an emulator, a simulator, desktop \
         and the web\n"
    );
    assert_eq!(calls.len(), 4, "{calls:?}");
    assert!(
        calls[0].ends_with("|compose version --short|bind=|cors="),
        "{calls:?}"
    );
    assert!(
        calls[1].ends_with("|info --format {{.ServerVersion}}|bind=|cors="),
        "{calls:?}"
    );
    assert_eq!(calls[2], "STACK|compose up -d|bind=|cors=");
    assert_eq!(calls[3], "STACK|compose wait dashboards|bind=|cors=");
}

/// `fsp telemetry --report` with the fake docker: success, stdout, stderr and the docker calls.
#[cfg(unix)]
fn telemetry_report(root: &Path, extra: &[(&str, &str)]) -> (bool, String, String, Vec<String>) {
    let work = root.join("work");
    fs::create_dir_all(&work).unwrap();
    let bin = fake_docker(root);
    let log = root.join("docker.log");
    let stack = root.join("stack");
    let mut all = vec![
        ("PATH", bin.to_str().unwrap()),
        ("FAKE_LOG", log.to_str().unwrap()),
        ("FSP_TELEMETRY_DIR", stack.to_str().unwrap()),
    ];
    all.extend_from_slice(extra);
    let (ok, out, err) = fsp_full(&work, &["telemetry", "--report"], &all);
    let calls = fs::read_to_string(&log)
        .unwrap_or_default()
        .lines()
        .map(|l| l.replace(stack.to_str().unwrap(), "STACK"))
        .collect();
    (
        ok,
        out,
        err.replace(stack.to_str().unwrap(), "STACK"),
        calls,
    )
}

#[cfg(unix)]
#[test]
fn telemetry_report_runs_the_report_in_the_importer_container() {
    let root = tempfile::tempdir().unwrap();
    let (ok, out, err, calls) = telemetry_report(root.path(), &[]);
    assert!(ok, "{err}");
    assert_eq!(out, "the report\n");
    assert_eq!(err, "");
    assert_eq!(calls.len(), 4, "{calls:?}");
    assert_eq!(
        calls[2],
        "STACK|compose ps --status running --services|bind=|cors="
    );
    assert_eq!(
        calls[3],
        "STACK|compose run --rm --no-deps -T dashboards python3 /fespalier/report.py|bind=|cors="
    );
    // It writes the stack first, so an older folder gets report.py.
    assert!(root.path().join("stack/openobserve/report.py").is_file());
}

#[cfg(unix)]
#[test]
fn telemetry_report_needs_the_stack_running() {
    let root = tempfile::tempdir().unwrap();
    let (ok, out, err, calls) = telemetry_report(root.path(), &[("FAKE_PS", "collector\n")]);
    assert!(!ok);
    assert_eq!(out, "");
    assert_eq!(
        err,
        "fsp telemetry --report needs the stack running: start it with `fsp telemetry`\n"
    );
    assert_eq!(calls.len(), 3, "{calls:?}");
}

#[cfg(unix)]
#[test]
fn telemetry_report_names_the_exit_code_when_the_report_fails() {
    let root = tempfile::tempdir().unwrap();
    let (ok, _, err, _) = telemetry_report(root.path(), &[("FAKE_RUN", "1")]);
    assert!(!ok);
    assert_eq!(err, "the report failed (exit 1); the lines above say why\n");
}

const TELEMETRY_W1: &str = "⚠ this app sends no fespalier spans yet: set `telemetry: true` under `fespalier:` in pubspec.yaml and install FespalierOtel (docs/observability.md, \"Telemetry\")\n";

#[cfg(unix)]
#[test]
fn telemetry_warns_when_the_project_it_runs_in_has_telemetry_off() {
    let root = tempfile::tempdir().unwrap();
    let app = project();
    let (ok, err, _) = telemetry_from(root.path(), app.path(), &[], &[]);
    assert!(ok, "{err}");
    // After the import, before the summary; the exit code is 0 and the summary is as ever.
    assert!(
        err.starts_with(&format!(
            "{TELEMETRY_W1}✓ telemetry stack running: 4 dashboards in OpenObserve"
        )),
        "{err}"
    );
    assert_eq!(err.matches('⚠').count(), 1, "{err}");

    // A folder below the project finds it too.
    let below = app.path().join("lib/app");
    let (ok, err, _) = telemetry_from(root.path(), &below, &[], &[]);
    assert!(ok && err.starts_with(TELEMETRY_W1), "{err}");

    // `--project` names a project from anywhere else.
    let elsewhere = tempfile::tempdir().unwrap();
    let project_dir = app.path().to_str().unwrap();
    let (ok, err, _) = telemetry_from(
        root.path(),
        elsewhere.path(),
        &["--project", project_dir],
        &[],
    );
    assert!(ok && err.starts_with(TELEMETRY_W1), "{err}");
}

#[cfg(unix)]
#[test]
fn telemetry_does_not_warn_with_telemetry_on_nor_outside_a_project() {
    let root = tempfile::tempdir().unwrap();
    let app = project();
    fs::write(
        app.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  telemetry: true\n",
    )
    .unwrap();
    let (ok, err, _) = telemetry_from(root.path(), app.path(), &[], &[]);
    assert!(ok && !err.contains('⚠'), "{err}");
    assert!(err.starts_with("✓ telemetry stack running"), "{err}");

    // No project above the working folder: nothing to warn about.
    let (ok, err, _) = telemetry(root.path(), &[], &[]);
    assert!(ok && !err.contains('⚠'), "{err}");

    // A project whose config does not load is not this command's business.
    fs::write(
        app.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  nope: 1\n",
    )
    .unwrap();
    let (ok, err, _) = telemetry_from(root.path(), app.path(), &[], &[]);
    assert!(ok && !err.contains('⚠'), "{err}");
}

#[cfg(unix)]
#[test]
fn telemetry_warns_only_on_a_start() {
    let root = tempfile::tempdir().unwrap();
    let app = project();
    // A stack to stop: the files from a `--no-start` run (which does not warn either).
    let (ok, err, _) = telemetry_from(root.path(), app.path(), &["--no-start"], &[]);
    assert!(ok && !err.contains('⚠'), "{err}");
    let (ok, err, _) = telemetry_from(root.path(), app.path(), &["--stop"], &[]);
    assert!(ok && !err.contains('⚠'), "{err}");
    let (ok, err, _) = telemetry_from(root.path(), app.path(), &["--no-start"], &[]);
    assert!(ok && !err.contains('⚠'), "{err}");
}

#[cfg(unix)]
#[test]
fn telemetry_grafana_adds_the_profile_and_its_line() {
    let root = tempfile::tempdir().unwrap();
    let (ok, err, calls) = telemetry(root.path(), &["--grafana"], &[]);
    assert!(ok, "{err}");
    assert!(
        err.contains("\n  Grafana      http://localhost:3000  admin / Fespalier-local-1\n"),
        "{err}"
    );
    assert!(calls.contains(&"STACK|compose --profile grafana up -d|bind=|cors=".to_string()));
    assert!(
        calls.contains(&"STACK|compose --profile grafana wait dashboards|bind=|cors=".to_string())
    );
}

#[cfg(unix)]
#[test]
fn telemetry_reads_ports_from_the_env_file() {
    let root = tempfile::tempdir().unwrap();
    let stack = root.path().join("stack");
    fs::create_dir_all(&stack).unwrap();
    fs::write(
        stack.join(".env"),
        "# mine\nFSP_O2_PORT=6000\nFSP_OTLP_HTTP_PORT=4400\n",
    )
    .unwrap();
    let (ok, err, _) = telemetry(root.path(), &[], &[]);
    assert!(ok, "{err}");
    assert!(
        err.contains("OpenObserve  http://localhost:6000  "),
        "{err}"
    );
    assert!(
        err.contains("OTLP         http://localhost:4400 (HTTP), localhost:4317 (gRPC)"),
        "{err}"
    );
}

#[cfg(unix)]
#[test]
fn telemetry_lan_binds_otlp_to_every_interface_and_writes_the_dart_defines() {
    let root = tempfile::tempdir().unwrap();
    let (ok, err, calls) = telemetry(root.path(), &["--lan"], &[]);
    if !ok {
        // A machine with no route to a network has no address to give out.
        assert_eq!(
            err,
            "fsp telemetry --lan can't find this computer's address on your network; start \
             without --lan and pass --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://<this \
             computer's address>:4318 yourself\n"
        );
        return;
    }
    let up = calls.iter().find(|c| c.contains("compose up -d")).unwrap();
    assert!(up.contains("|bind=0.0.0.0|cors=http://"), "{up}");
    assert!(up.ends_with(":*"), "{up}");
    let defines = fs::read_to_string(root.path().join("stack/dart-defines.json")).unwrap();
    assert!(
        defines.starts_with("{\"OTEL_EXPORTER_OTLP_ENDPOINT\": \"http://"),
        "{defines}"
    );
    assert!(defines.ends_with(":4318\"}\n"), "{defines}");
    assert!(
        err.contains("\n  A phone      flutter run --dart-define-from-file="),
        "{err}"
    );
    // The next run without --lan binds to loopback again.
    let (ok, _, calls) = telemetry(root.path(), &[], &[]);
    assert!(ok);
    let up = calls.iter().rev().find(|c| c.contains("up -d")).unwrap();
    assert!(up.ends_with("|bind=|cors="), "{up}");
}

#[cfg(unix)]
#[test]
fn telemetry_errors_say_what_failed() {
    let root = tempfile::tempdir().unwrap();
    let (ok, err, _) = telemetry(root.path(), &[], &[("FAKE_VERSION", "2.19.1")]);
    assert!(!ok);
    assert_eq!(
        err,
        "fsp telemetry needs Docker Compose v2.20 or later (for `docker compose wait`); this one \
         is 2.19.1\n"
    );
    let (ok, err, _) = telemetry(root.path(), &[], &[("FAKE_INFO", "1")]);
    assert!(!ok);
    assert_eq!(
        err,
        "fsp telemetry needs a running Docker daemon: `docker info` failed (exit 1). The stack's \
         files are in STACK; start Docker, then run `fsp telemetry` again.\n"
    );
    let (ok, err, _) = telemetry(root.path(), &[], &[("FAKE_UP", "1")]);
    assert!(!ok);
    assert_eq!(
        err,
        "docker compose up failed (exit 1); its output is above. A port in use? Set \
         FSP_OTLP_HTTP_PORT, FSP_OTLP_GRPC_PORT, FSP_O2_PORT or FSP_GRAFANA_PORT in STACK/.env\n"
    );
    let (ok, err, _) = telemetry(root.path(), &[], &[("FAKE_WAIT", "3")]);
    assert!(!ok);
    assert_eq!(
        err,
        "the dashboards were not imported into OpenObserve (exit 3); `docker compose logs \
         dashboards` in STACK says why\n"
    );
}

#[cfg(unix)]
#[test]
fn telemetry_stop_and_reset_run_down_with_the_grafana_profile() {
    let root = tempfile::tempdir().unwrap();
    let (ok, err, _) = telemetry(root.path(), &["--stop"], &[]);
    assert!(!ok);
    assert_eq!(
        err,
        "there is no telemetry stack in STACK (no compose.yaml): nothing to stop or reset\n"
    );
    let (ok, _, _) = telemetry(root.path(), &["--no-start"], &[]);
    assert!(ok);
    let (ok, err, calls) = telemetry(root.path(), &["--stop"], &[]);
    assert!(ok, "{err}");
    assert_eq!(
        err,
        "✓ telemetry stack stopped; its data is kept (fsp telemetry --reset deletes it)\n"
    );
    assert!(calls.contains(&"STACK|compose --profile grafana down|bind=|cors=".to_string()));
    let (ok, err, calls) = telemetry(root.path(), &["--reset"], &[]);
    assert!(ok, "{err}");
    assert_eq!(err, "✓ telemetry stack stopped and its data deleted\n");
    assert!(calls.contains(&"STACK|compose --profile grafana down -v|bind=|cors=".to_string()));
    let (ok, err, _) = telemetry(root.path(), &["--stop"], &[("FAKE_DOWN", "4")]);
    assert!(!ok);
    assert_eq!(
        err,
        "docker compose down failed (exit 4); its output is above\n"
    );
}

// --- fsp dev, fsp build and fsp run ------------------------------------------------------------
//
// A stand-in `flutter` (a shell script) speaks the daemon protocol of `flutter run --machine`,
// so these run the real `fsp` against it. Nothing sleeps to wait for something: each test polls
// the log it is waiting on, with a limit.

/// A folder with a stand-in `flutter` in `bin/`. It logs its arguments to `$FAKE_LOG`; `devices`
/// prints `$FAKE_DEVICES` (one Android emulator by default), `build` exits `$FAKE_BUILD_EXIT`,
/// and `run` answers the daemon protocol: `app.restart` is logged (`app.restart fullRestart=...`)
/// and answered, `app.stop` is logged and ends it. With `$FAKE_RUN_EXIT` set it exits at once.
#[cfg(unix)]
fn fake_flutter(root: &Path) -> std::path::PathBuf {
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let path = bin.join("flutter");
    write_executable(
        &path,
        r#"#!/bin/sh
echo "$*" >> "$FAKE_LOG"
ONE='[{"name":"Fake","id":"fake-1","isSupported":true,"targetPlatform":"android-arm64","emulator":true}]'
case "$1" in
  devices) printf '%s\n' "${FAKE_DEVICES:-$ONE}"; exit 0 ;;
  build) exit "${FAKE_BUILD_EXIT:-0}" ;;
  run) ;;
  *) exit 9 ;;
esac
echo '[{"event":"daemon.connected","params":{"version":"0.6.1","pid":1}}]'
echo '[{"event":"app.start","params":{"appId":"a1","deviceId":"fake-1","directory":"'"$PWD"'","supportsRestart":true,"launchMode":"run","mode":"debug"}}]'
echo '[{"event":"app.debugPort","params":{"appId":"a1","port":1,"wsUri":"ws://127.0.0.1:1/x=/ws"}}]'
echo '[{"event":"app.devTools","params":{"appId":"a1","uri":"http://127.0.0.1:2/?uri=ws://127.0.0.1:1/x=/ws"}}]'
echo '[{"event":"app.started","params":{"appId":"a1"}}]'
echo '[{"event":"app.log","params":{"appId":"a1","log":"hello from the app"}}]'
[ -n "$FAKE_RUN_EXIT" ] && exit "$FAKE_RUN_EXIT"
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *'"app.restart"'*)
      full=false
      case "$line" in *'"fullRestart":true'*) full=true ;; esac
      echo "app.restart fullRestart=$full" >> "$FAKE_LOG"
      echo "[{\"id\":$id,\"result\":{\"code\":0,\"message\":\"Reloaded 1 of 9 libraries\"}}]" ;;
    *'"app.stop"'*)
      echo "app.stop" >> "$FAKE_LOG"
      echo "[{\"id\":$id,\"result\":true}]"
      echo '[{"event":"app.stop","params":{"appId":"a1"}}]'
      exit 0 ;;
  esac
done
"#,
    );
    bin
}

/// `PATH` with the stand-in first.
#[cfg(unix)]
fn path_with(bin: &Path) -> String {
    format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    )
}

/// A project with a pubspec that has a `fespalier:` section of `tasks_yaml` (indented under
/// `tasks:`), and a stand-in flutter. Returns the project folder (the stand-in's folder is in it).
#[cfg(unix)]
fn dev_project(tasks_yaml: &str) -> tempfile::TempDir {
    let dir = project();
    if !tasks_yaml.is_empty() {
        fs::write(
            dir.path().join("pubspec.yaml"),
            format!("name: demo\nfespalier:\n  tasks:\n{tasks_yaml}"),
        )
        .unwrap();
    }
    fake_flutter(dir.path());
    dir
}

/// A running `fsp dev --no-tui`: stdin is a pipe, stderr a file.
#[cfg(unix)]
struct Dev {
    child: Child,
    stdin: Option<std::process::ChildStdin>,
    err: std::path::PathBuf,
    log: std::path::PathBuf,
}

#[cfg(unix)]
impl Dev {
    fn start(root: &Path, args: &[&str]) -> Dev {
        Dev::start_with(root, args, &[], true)
    }

    fn start_with(root: &Path, args: &[&str], env: &[(&str, &str)], keep_stdin: bool) -> Dev {
        let err = root.join("dev.err");
        let log = root.join("flutter.log");
        let mut child = spawn_locked(
            Command::new(env!("CARGO_BIN_EXE_fsp"))
                .arg("dev")
                .arg("--no-tui")
                .args(args)
                .env("PATH", path_with(&root.join("bin")))
                .env("FAKE_LOG", &log)
                .envs(env.iter().copied())
                .env_remove("NO_COLOR")
                .current_dir(root)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(fs::File::create(&err).unwrap()),
        )
        .unwrap();
        let stdin = child.stdin.take();
        Dev {
            child,
            stdin: if keep_stdin { stdin } else { None },
            err,
            log,
        }
    }

    fn err(&self) -> String {
        fs::read_to_string(&self.err).unwrap_or_default()
    }

    fn flog(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    fn wait_until(&self, what: &str, mut done: impl FnMut() -> bool) {
        let end = Instant::now() + Duration::from_secs(30);
        while !done() {
            assert!(
                Instant::now() < end,
                "timed out waiting for {what}\n--- fsp dev:\n{}\n--- flutter log:\n{}",
                self.err(),
                self.flog()
            );
            sleep(Duration::from_millis(20));
        }
    }

    fn wait_err(&self, needle: &str) {
        self.wait_until(&format!("`{needle}` on stderr"), || {
            self.err().contains(needle)
        });
    }

    fn wait_log(&self, needle: &str) {
        self.wait_until(&format!("`{needle}` in the flutter log"), || {
            self.flog().contains(needle)
        });
    }

    /// Waits for fsp to be running the app and watching: ready for a change on disk.
    fn wait_ready(&self) {
        self.wait_err("[fsp] app running on");
        self.wait_err("[fsp] watching lib/app/");
    }

    fn send(&mut self, line: &str) {
        let stdin = self.stdin.as_mut().expect("stdin is open");
        stdin.write_all(format!("{line}\n").as_bytes()).unwrap();
        stdin.flush().unwrap();
    }

    fn signal(&self, name: &str) {
        let status = status_locked(
            Command::new("kill")
                .arg(format!("-{name}"))
                .arg(self.child.id().to_string()),
        )
        .unwrap();
        assert!(status.success());
    }

    /// The exit code, once fsp has exited.
    fn wait_exit(&mut self) -> Option<i32> {
        let end = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return status.code();
            }
            assert!(
                Instant::now() < end,
                "fsp dev did not exit\n--- fsp dev:\n{}\n--- flutter log:\n{}",
                self.err(),
                self.flog()
            );
            sleep(Duration::from_millis(20));
        }
    }
}

#[cfg(unix)]
impl Drop for Dev {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            // Let it stop what it started; a test that failed must not leave processes behind.
            let _ = status_locked(Command::new("kill").arg(self.child.id().to_string()));
            let end = Instant::now() + Duration::from_secs(15);
            while self.child.try_wait().ok().flatten().is_none() && Instant::now() < end {
                sleep(Duration::from_millis(20));
            }
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

/// The lines of a log that start with `prefix`.
#[cfg(unix)]
fn log_calls(log: &str, prefix: &str) -> Vec<String> {
    log.lines()
        .filter(|l| l.starts_with(prefix))
        .map(str::to_string)
        .collect()
}

#[cfg(unix)]
#[test]
fn dev_with_no_config_runs_flutter_and_follows_the_files() {
    let dir = dev_project("");
    let root = dir.path();
    let mut d = Dev::start(root, &[]);
    d.wait_ready();
    d.wait_err("[flutter] hello from the app");
    // It asked flutter for the devices, then ran it on the one device.
    let log = d.flog();
    let devices = log.lines().position(|l| l == "devices --machine").unwrap();
    let run = log
        .lines()
        .position(|l| l == "run --machine -d fake-1")
        .unwrap();
    assert!(devices < run, "{log}");
    let err = d.err();
    assert!(err.contains("[fsp] app running on Fake (fake-1)"), "{err}");
    assert!(err.contains("[fsp] DevTools: http://127.0.0.1:2/"), "{err}");
    assert!(
        err.contains("[fsp] keys: r reload · R restart · q quit (type the letter, then Enter)"),
        "{err}"
    );

    // A new route changes app.g.dart: a hot restart.
    fs::create_dir_all(root.join("lib/app/about")).unwrap();
    fs::write(root.join("lib/app/about/page.dart"), page("AboutPage")).unwrap();
    d.wait_log("app.restart fullRestart=true");
    d.wait_err("[fsp] ✓ hot restart in");
    assert!(
        d.err()
            .contains("[fsp] hot restart: lib/app.g.dart changed")
    );

    // A change to a page's body leaves app.g.dart alone: a hot reload.
    fs::write(
        root.join("lib/app/page.dart"),
        format!("{}\n// a change\n", page("HomePage")),
    )
    .unwrap();
    d.wait_log("app.restart fullRestart=false");
    d.wait_err("[fsp] ✓ hot reload in");
    assert!(d.err().contains("(Reloaded 1 of 9 libraries)"));

    // A key typed as a line.
    d.send("r");
    d.wait_until("a second reload", || {
        log_calls(&d.flog(), "app.restart fullRestart=false").len() == 2
    });

    d.send("q");
    d.wait_log("app.stop");
    assert_eq!(d.wait_exit(), Some(0), "{}", d.err());
    assert!(d.err().contains("stopping flutter…"));
}

#[cfg(unix)]
#[test]
fn dev_passes_what_follows_the_dashes_to_flutter_and_skips_the_device_listing() {
    let dir = dev_project("");
    let mut d = Dev::start(dir.path(), &["--", "-d", "chrome", "--flavor", "x"]);
    d.wait_err("[fsp] app running on");
    let log = d.flog();
    assert!(log_calls(&log, "devices").is_empty(), "{log}");
    assert_eq!(
        log_calls(&log, "run"),
        ["run --machine -d chrome --flavor x"],
        "{log}"
    );
    d.send("q");
    assert_eq!(d.wait_exit(), Some(0));
}

#[cfg(unix)]
#[test]
fn dev_with_two_devices_and_no_terminal_says_which_flag_to_use() {
    let dir = dev_project("");
    let two = r#"[{"name":"macOS","id":"macos","isSupported":true,"targetPlatform":"darwin"},{"name":"Chrome","id":"chrome","isSupported":true,"targetPlatform":"web-javascript"}]"#;
    let mut d = Dev::start_with(dir.path(), &[], &[("FAKE_DEVICES", two)], true);
    assert_eq!(d.wait_exit(), Some(1));
    let err = d.err();
    assert!(
        err.contains(
            "more than one device: pick one with `fsp dev -- -d <id>` (ids: macos, chrome)"
        ),
        "{err}"
    );
    assert!(log_calls(&d.flog(), "run").is_empty(), "{}", d.flog());
}

#[cfg(unix)]
#[test]
fn dev_with_no_supported_device_says_so() {
    let dir = dev_project("");
    let none =
        r#"[{"name":"Linux","id":"linux","isSupported":false,"targetPlatform":"linux-x64"}]"#;
    let mut d = Dev::start_with(dir.path(), &[], &[("FAKE_DEVICES", none)], true);
    assert_eq!(d.wait_exit(), Some(1));
    assert!(
        d.err().contains("no device to run on: `flutter devices` lists none that this project supports. Start an emulator or a simulator, connect a phone, or enable a platform with `flutter create --platforms=web .`"),
        "{}",
        d.err()
    );
}

#[cfg(unix)]
#[test]
fn a_failing_before_step_stops_dev_with_its_exit_code() {
    let dir = dev_project("    dev:\n      before: exit 3\n");
    let mut d = Dev::start(dir.path(), &[]);
    assert_eq!(d.wait_exit(), Some(3));
    let err = d.err();
    assert!(err.contains("› exit 3\n"), "{err}");
    assert!(
        err.contains("`before` step 1 of `dev` failed (exit 3): exit 3"),
        "{err}"
    );
    assert!(
        log_calls(&d.flog(), "run").is_empty(),
        "flutter was started"
    );
}

#[cfg(unix)]
#[test]
fn before_steps_run_in_order_and_with_the_tasks_env() {
    let dir = dev_project(
        "    dev:\n      env:\n        GREETING: hello\n      before:\n        - echo \"one $GREETING\" >> order.txt\n        - [sh, -c, 'echo two >> order.txt']\n",
    );
    let mut d = Dev::start(dir.path(), &["--", "-d", "x"]);
    d.wait_err("[fsp] app running on");
    d.send("q");
    assert_eq!(d.wait_exit(), Some(0));
    assert_eq!(
        fs::read_to_string(dir.path().join("order.txt")).unwrap(),
        "one hello\ntwo\n"
    );
    let err = d.err();
    assert!(
        err.contains("› echo \"one $GREETING\" >> order.txt\n"),
        "{err}"
    );
    assert!(err.contains("› sh -c 'echo two >> order.txt'\n"), "{err}");
}

/// A `with` command is stopped with fsp, and so is what it started: the group is stopped, not
/// only the shell.
#[cfg(unix)]
#[test]
fn a_with_command_and_what_it_started_stop_with_dev() {
    let dir = dev_project(
        "    dev:\n      with:\n        ticker: 'sleep 300 & echo $! > ticker.pid; echo hello; wait'\n",
    );
    let mut d = Dev::start(dir.path(), &["--", "-d", "x"]);
    d.wait_err("[ticker] hello");
    d.wait_ready();
    let pid = fs::read_to_string(dir.path().join("ticker.pid"))
        .unwrap()
        .trim()
        .to_string();
    let alive = |pid: &str| {
        status_locked(Command::new("kill").args(["-0", pid]).stderr(Stdio::null()))
            .unwrap()
            .success()
    };
    assert!(alive(&pid), "the process is not running to begin with");
    d.send("q");
    assert_eq!(d.wait_exit(), Some(0), "{}", d.err());
    d.wait_until("the process the command started to be gone", || {
        !alive(&pid)
    });
}

#[cfg(unix)]
#[test]
fn a_with_command_that_exits_is_reported_and_dev_keeps_running() {
    let dir = dev_project("    dev:\n      with:\n        once: 'echo bye; exit 4'\n");
    let mut d = Dev::start(dir.path(), &["--", "-d", "x"]);
    d.wait_err("[fsp] [once] exited (exit 4); fsp dev keeps running");
    d.wait_err("[once] bye");
    d.wait_err("[fsp] app running on");
    d.send("q");
    assert_eq!(d.wait_exit(), Some(0));
}

#[cfg(unix)]
#[test]
fn a_sigterm_stops_flutter_first_and_exits_130() {
    let dir = dev_project("");
    let mut d = Dev::start(dir.path(), &[]);
    d.wait_ready();
    d.signal("TERM");
    d.wait_log("app.stop");
    assert_eq!(d.wait_exit(), Some(130), "{}", d.err());
}

#[cfg(unix)]
#[test]
fn flutter_exiting_by_itself_ends_dev_with_its_code_and_skips_after() {
    let dir = dev_project("    dev:\n      after: touch after.marker\n");
    let mut d = Dev::start_with(
        dir.path(),
        &["--", "-d", "x"],
        &[("FAKE_RUN_EXIT", "1")],
        true,
    );
    assert_eq!(d.wait_exit(), Some(1), "{}", d.err());
    assert!(
        d.err().contains("flutter run exited (exit 1)"),
        "{}",
        d.err()
    );
    assert!(!dir.path().join("after.marker").exists());
}

#[cfg(unix)]
#[test]
fn after_runs_when_dev_is_stopped_by_the_user() {
    let dir = dev_project("    dev:\n      after: echo done >> after.marker\n");
    let mut d = Dev::start(dir.path(), &["--", "-d", "x"]);
    d.wait_err("[fsp] app running on");
    d.send("q");
    assert_eq!(d.wait_exit(), Some(0), "{}", d.err());
    assert_eq!(
        fs::read_to_string(dir.path().join("after.marker")).unwrap(),
        "done\n"
    );
    assert!(
        d.err().contains("› echo done >> after.marker"),
        "{}",
        d.err()
    );
}

/// An end of input (a closed pipe, `</dev/null`, an IDE's run panel) does not quit.
#[cfg(unix)]
#[test]
fn dev_keeps_running_when_stdin_ends() {
    let dir = dev_project("");
    let mut d = Dev::start_with(dir.path(), &[], &[], false);
    d.wait_ready();
    fs::create_dir_all(dir.path().join("lib/app/about")).unwrap();
    fs::write(
        dir.path().join("lib/app/about/page.dart"),
        page("AboutPage"),
    )
    .unwrap();
    d.wait_log("app.restart fullRestart=true");
    d.wait_err("[fsp] ✓ hot restart in");
    d.signal("TERM");
    assert_eq!(d.wait_exit(), Some(130), "{}", d.err());
}

#[cfg(unix)]
#[test]
fn an_initial_generation_error_with_no_output_stops_dev() {
    let dir = dev_project("");
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "// no widget in here\n",
    )
    .unwrap();
    let mut d = Dev::start(dir.path(), &[]);
    assert_eq!(d.wait_exit(), Some(1));
    let err = d.err();
    assert!(
        err.contains(
            "fsp dev needs lib/app.g.dart: fix the errors above, then run `fsp dev` again"
        ),
        "{err}"
    );
    assert!(d.flog().is_empty(), "flutter was started: {}", d.flog());
}

#[cfg(unix)]
#[test]
fn an_initial_generation_error_with_an_output_warns_and_goes_on() {
    let dir = dev_project("");
    // The first run writes the output ...
    let mut first = Dev::start(dir.path(), &["--", "-d", "x"]);
    first.wait_ready();
    first.send("q");
    assert_eq!(first.wait_exit(), Some(0));
    assert!(dir.path().join("lib/app.g.dart").is_file());
    // ... which a later run keeps when the app has an error.
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "// no widget in here\n",
    )
    .unwrap();
    let mut d = Dev::start(dir.path(), &["--", "-d", "x"]);
    d.wait_err("[fsp] app running on");
    let err = d.err();
    assert!(
        err.contains("warning: lib/app.g.dart is out of date until the errors above are fixed; fsp dev keeps watching"),
        "{err}"
    );
    d.send("q");
    assert_eq!(d.wait_exit(), Some(0));
}

// --- `fsp run` and `fsp build` -----------------------------------------------------------------

/// Runs `fsp` with the stand-in flutter first on PATH; returns the exit code, stdout and stderr.
#[cfg(unix)]
fn fsp_task(root: &Path, args: &[&str], env: &[(&str, &str)]) -> (Option<i32>, String, String) {
    let out = output_locked(
        Command::new(env!("CARGO_BIN_EXE_fsp"))
            .args(args)
            .env("PATH", path_with(&root.join("bin")))
            .env("FAKE_LOG", root.join("flutter.log"))
            .envs(env.iter().copied())
            .current_dir(root),
    )
    .unwrap();
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[cfg(unix)]
#[test]
fn run_lists_the_tasks_on_stdout() {
    let dir = dev_project("    codegen: dart run build_runner build -d\n");
    let (code, out, _) = fsp_task(dir.path(), &["run"], &[]);
    assert_eq!(code, Some(0));
    assert_eq!(
        out,
        "dev      flutter run   (fsp dev)\nbuild    flutter build (fsp build <target>)\ncodegen  dart run build_runner build -d\n"
    );
    // With no section at all: the built-ins.
    let dir = dev_project("");
    let (code, out, _) = fsp_task(dir.path(), &["run"], &[]);
    assert_eq!(code, Some(0));
    assert_eq!(
        out,
        "dev    flutter run   (fsp dev)\nbuild  flutter build (fsp build <target>)\n"
    );
}

#[cfg(unix)]
#[test]
fn run_runs_a_task_with_the_args_and_passes_its_exit_code_on() {
    let dir = dev_project(
        "    codegen: [sh, -c, 'echo \"$@\" > codegen.out; echo \"$GREETING\" >> codegen.out; exit 4', sh]\n    greet:\n      run: echo\n      env:\n        GREETING: hi\n",
    );
    let (code, out, err) = fsp_task(dir.path(), &["run", "codegen", "--", "--x", "a b"], &[]);
    assert_eq!(code, Some(4), "{err}");
    assert!(out.is_empty() && err.is_empty(), "{out}{err}");
    assert_eq!(
        fs::read_to_string(dir.path().join("codegen.out")).unwrap(),
        "--x a b\n\n"
    );
    // A shell string gets the args appended as quoted words, and the task's env.
    let (code, out, _) = fsp_task(dir.path(), &["run", "greet", "--", "a b", "$HOME"], &[]);
    assert_eq!(code, Some(0));
    assert_eq!(out, "a b $HOME\n");
}

#[cfg(unix)]
#[test]
fn run_says_what_is_wrong_with_the_name() {
    let dir = dev_project("    codegen: echo hi\n");
    let (code, _, err) = fsp_task(dir.path(), &["run", "nope"], &[]);
    assert_eq!(code, Some(1));
    assert_eq!(
        err,
        "no task `nope` in `fespalier: tasks:` of pubspec.yaml; the tasks are: dev, build, codegen\n"
    );
    let dir = dev_project("");
    let (code, _, err) = fsp_task(dir.path(), &["run", "nope"], &[]);
    assert_eq!(code, Some(1));
    assert_eq!(
        err,
        "no task `nope` in `fespalier: tasks:` of pubspec.yaml; there are none yet (docs/cli.md, \"Tasks: commands around `flutter run`\")\n"
    );
    let (code, _, err) = fsp_task(dir.path(), &["run", "dev"], &[]);
    assert_eq!(code, Some(1));
    assert_eq!(
        err,
        "`dev` is the task `fsp dev` runs, with the watcher, the device and hot reload: run `fsp dev`\n"
    );
    let (code, _, err) = fsp_task(dir.path(), &["run", "build"], &[]);
    assert_eq!(code, Some(1));
    assert_eq!(
        err,
        "`build` is the task `fsp build <target>` runs, after `fsp gen`: run `fsp build web` (or apk, ipa, macos, ...)\n"
    );
}

#[cfg(unix)]
#[test]
fn a_mistake_in_tasks_is_reported_by_run_and_not_by_gen() {
    let dir = dev_project("    codegen: 5\n");
    let (code, _, err) = fsp_task(dir.path(), &["run", "codegen"], &[]);
    assert_eq!(code, Some(1));
    assert!(
        err.starts_with("`fespalier.tasks.codegen` must be a command (a string, or a list of words) or a map with `run`, `before`, `with`, `after`, `env` and `hot_reload`, got `5`"),
        "{err}"
    );
    let (code, _, err) = fsp_task(dir.path(), &["gen"], &[]);
    assert_eq!(code, Some(0), "{err}");
}

#[cfg(unix)]
#[test]
fn build_generates_first_then_runs_before_flutter_build_and_after() {
    let dir = dev_project(
        "    build:\n      before: echo before >> \"$FAKE_LOG\"\n      after: echo after >> \"$FAKE_LOG\"\n",
    );
    let (code, _, err) = fsp_task(dir.path(), &["build", "web", "--", "--release"], &[]);
    assert_eq!(code, Some(0), "{err}");
    // The output is written first (`gen`'s own line), then the steps and flutter.
    assert!(err.starts_with("✓ 1 route → lib/app.g.dart\n"), "{err}");
    assert!(dir.path().join("lib/app.g.dart").is_file());
    let log = fs::read_to_string(dir.path().join("flutter.log")).unwrap();
    assert_eq!(log, "before\nbuild web --release\nafter\n");
}

#[cfg(unix)]
#[test]
fn build_passes_a_failure_on_and_skips_after() {
    let dir = dev_project("    build:\n      after: echo after >> \"$FAKE_LOG\"\n");
    let (code, _, _) = fsp_task(dir.path(), &["build", "apk"], &[("FAKE_BUILD_EXIT", "2")]);
    assert_eq!(code, Some(2));
    let log = fs::read_to_string(dir.path().join("flutter.log")).unwrap();
    assert_eq!(log, "build apk\n");
}

#[cfg(unix)]
#[test]
fn build_sets_the_target_for_its_commands() {
    let dir = dev_project("    build:\n      before: echo \"$FSP_BUILD_TARGET\" > target.out\n");
    let (code, _, err) = fsp_task(dir.path(), &["build", "ipa"], &[]);
    assert_eq!(code, Some(0), "{err}");
    assert_eq!(
        fs::read_to_string(dir.path().join("target.out")).unwrap(),
        "ipa\n"
    );
}

#[cfg(unix)]
#[test]
fn build_stops_when_the_generation_fails() {
    let dir = dev_project("");
    fs::write(dir.path().join("lib/app/page.dart"), "// no widget\n").unwrap();
    let (code, _, err) = fsp_task(dir.path(), &["build", "web"], &[]);
    assert_eq!(code, Some(1));
    assert!(
        err.contains("1 error(s); lib/app.g.dart left unchanged"),
        "{err}"
    );
    assert!(!dir.path().join("flutter.log").exists(), "flutter was run");
}

#[cfg(unix)]
#[test]
fn fsp_in_a_command_is_this_fsp() {
    let dir = dev_project("    check:\n      before: fsp check\n      run: [fsp, routes]\n");
    let (code, out, err) = fsp_task(dir.path(), &["run", "check"], &[]);
    assert_eq!(code, Some(0), "{err}");
    assert!(
        err.contains("› fsp check\n") && err.contains("✓ 1 route, no errors"),
        "{err}"
    );
    assert!(out.contains('/'), "{out}");
}

#[cfg(unix)]
#[test]
fn dry_runs_print_the_plan_and_run_nothing() {
    let dir = dev_project(
        "    dev:\n      before: dart run build_runner build -d\n      with:\n        build_runner: dart run build_runner watch -d\n      env:\n        API_URL: http://localhost:8080\n    codegen:\n      run: dart run build_runner build -d\n      after: echo done\n",
    );
    let root = dir.path().display().to_string();
    let (code, out, err) = fsp_task(dir.path(), &["dev", "--dry-run", "--", "-d", "chrome"], &[]);
    assert_eq!(code, Some(0));
    assert!(out.is_empty());
    assert_eq!(
        err,
        format!(
            "\
fsp dev in {root}
  gen     lib/app.g.dart, kept current while it runs
  before  dart run build_runner build -d
  with    build_runner: dart run build_runner watch -d
  run     flutter run --machine -d chrome
  after   (nothing)
  env     API_URL=http://localhost:8080
  hot reload after a save; hot restart when lib/app.g.dart changes
"
        )
    );
    let (code, _, err) = fsp_task(
        dir.path(),
        &["build", "web", "--dry-run", "--", "--release"],
        &[],
    );
    assert_eq!(code, Some(0));
    assert_eq!(
        err,
        format!(
            "\
fsp build web in {root}
  gen     lib/app.g.dart
  before  (nothing)
  with    (nothing)
  run     flutter build web --release
  after   (nothing)
  env     (nothing)
"
        )
    );
    let (code, _, err) = fsp_task(
        dir.path(),
        &["run", "codegen", "--dry-run", "--", "--x"],
        &[],
    );
    assert_eq!(code, Some(0));
    assert_eq!(
        err,
        format!(
            "\
fsp run codegen in {root}
  before  (nothing)
  with    (nothing)
  run     dart run build_runner build -d --x
  after   echo done
  env     (nothing)
"
        )
    );
    // Nothing ran: no flutter, no output written.
    assert!(!dir.path().join("flutter.log").exists());
    assert!(!dir.path().join("lib/app.g.dart").exists());
}

/// `fespalier: adapters:` (since 0.9.0) writes the generated `main()` on its own, calling
/// `AppAdapters`, which `app.g.dart` defines; `main: manual` keeps `AppAdapters` and writes no
/// main (since 0.11.0, it used to be refused).
#[test]
fn adapters_write_the_main_and_main_manual_keeps_them() {
    let dir = project();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\ndependencies:\n  fespalier_sentry: ^1.0.0\nfespalier:\n  adapters: [fespalier_sentry]\n",
    )
    .unwrap();
    assert_eq!(
        fsp(dir.path(), &["gen"]),
        (
            true,
            "✓ 1 route → lib/app.g.dart, lib/app.main.g.dart\n".into()
        )
    );
    let main = fs::read_to_string(dir.path().join("lib/app.main.g.dart")).unwrap();
    assert!(
        main.contains("static Future<void> run() => AppAdapters.zone(_main);")
            && !main.contains("fespalier_adapter.dart"),
        "{main}"
    );
    let app_g = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(
        app_g.contains("import 'package:fespalier_sentry/fespalier_adapter.dart' as _a0;")
            && app_g.contains("FespalierAdapters([_a0.adapter])"),
        "{app_g}"
    );
    assert_eq!(
        fsp(dir.path(), &["check"]),
        (true, "✓ 1 route, no errors\n".into())
    );

    fs::remove_file(dir.path().join("lib/app.main.g.dart")).unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\ndependencies:\n  fespalier_sentry: ^1.0.0\nfespalier:\n  main: manual\n  adapters: [fespalier_sentry]\n",
    )
    .unwrap();
    assert_eq!(
        fsp(dir.path(), &["gen"]),
        (true, "✓ 1 route, lib/app.g.dart unchanged\n".into())
    );
    assert!(!dir.path().join("lib/app.main.g.dart").exists());
    let app_g = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(
        app_g.contains("abstract final class AppAdapters"),
        "{app_g}"
    );
    assert_eq!(
        fsp(dir.path(), &["check"]),
        (true, "✓ 1 route, no errors\n".into())
    );
}

#[test]
fn links_edits_the_platform_files_and_check_follows_them() {
    let dir = project();
    let root = dir.path();
    let pubspec = root.join("pubspec.yaml");
    let base = fs::read_to_string(&pubspec).unwrap();
    let manifest_path = "android/app/src/main/AndroidManifest.xml";
    let plist_path = "ios/Runner/Runner.entitlements";
    let keys = format!(
        "{LINKS}    android_manifest: {manifest_path}\n    ios_entitlements: {plist_path}\n"
    );
    fs::write(&pubspec, format!("{base}{keys}")).unwrap();

    // The manifest has to exist: `fsp` edits it, it does not create it.
    let (ok, _, err) = fsp_full(root, &["links"], &[]);
    assert!(
        !ok && err.contains(&format!(
            "{manifest_path} not found (`fespalier.links.android_manifest`); run `flutter create --platforms android .`, or fix the path"
        )),
        "{err}"
    );
    assert!(!root.join("links").exists(), "an error writes nothing");

    fs::create_dir_all(root.join("android/app/src/main")).unwrap();
    let template = include_str!("fixtures/links/AndroidManifest.xml");
    fs::write(root.join(manifest_path), template).unwrap();
    fs::create_dir_all(root.join("ios/Runner.xcodeproj")).unwrap();
    fs::create_dir_all(root.join("ios/Runner")).unwrap();
    fs::write(
        root.join("ios/Runner.xcodeproj/project.pbxproj"),
        "CODE_SIGN_ENTITLEMENTS = Runner/Other.entitlements;\n",
    )
    .unwrap();

    // `--check` names what is missing and writes nothing.
    let (ok, _, err) = fsp_full(root, &["links", "--check"], &[]);
    assert!(!ok, "{err}");
    assert!(
        err.contains(&format!("{manifest_path} has no fsp links markers yet")),
        "{err}"
    );
    assert!(err.contains(&format!("{plist_path} is missing")), "{err}");
    assert!(
        err.contains("7 file(s) out of date; run `fsp links`"),
        "{err}"
    );
    assert_eq!(
        fs::read_to_string(root.join(manifest_path)).unwrap(),
        template
    );
    assert!(!root.join(plist_path).exists());

    // `fsp links` edits and writes them, and says the Xcode project doesn't use the file.
    let (ok, _, err) = fsp_full(root, &["links"], &[]);
    assert!(ok, "{err}");
    assert!(err.contains(&format!("  edited {manifest_path}")), "{err}");
    assert!(err.contains(&format!("  wrote {plist_path}")), "{err}");
    assert!(
        err.contains(&format!(
            "warning: {plist_path} is not set as CODE_SIGN_ENTITLEMENTS in ios/Runner.xcodeproj/project.pbxproj, so no build uses it: add the Associated Domains capability in Xcode, or point the build setting at this file"
        )),
        "{err}"
    );
    assert!(
        err.contains("and 2 platform files (1 written, 1 edited, 0 unchanged)"),
        "{err}"
    );
    let manifest = fs::read_to_string(root.join(manifest_path)).unwrap();
    assert!(manifest.contains("<!-- fsp links: begin. "), "{manifest}");
    assert!(
        manifest.contains("<data android:host=\"shop.example.com\" />"),
        "{manifest}"
    );
    assert!(
        fs::read_to_string(root.join(plist_path))
            .unwrap()
            .contains("<string>applinks:shop.example.com</string>")
    );

    // The paste files say `fsp` does the pasting, and no temporary file stays behind.
    let paste = fs::read_to_string(root.join("links/android/intent-filters.xml")).unwrap();
    assert!(
        paste.contains("this file is a copy to read, don't paste it"),
        "{paste}"
    );
    let paste = fs::read_to_string(root.join("links/ios/associated-domains.entitlements")).unwrap();
    assert!(
        paste.contains("this file is a copy to read, don't paste it"),
        "{paste}"
    );
    assert!(
        !root
            .join("ios/Runner/.Runner.entitlements.fsp-tmp")
            .exists()
    );

    // Pointing the build setting at it quiets the warning; everything is up to date.
    fs::write(
        root.join("ios/Runner.xcodeproj/project.pbxproj"),
        "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\n",
    )
    .unwrap();
    let (ok, _, err) = fsp_full(root, &["links", "--check"], &[]);
    assert!(
        ok && err.contains("✓ links: 5 files in links are up to date, and 2 platform files")
            && !err.contains("warning"),
        "{err}"
    );
    let (ok, _, err) = fsp_full(root, &["links"], &[]);
    assert!(
        ok && !err.contains("  edited ") && err.contains("(0 written, 0 edited, 2 unchanged)"),
        "{err}"
    );

    // A new route makes the manifest stale: `--check` names it, `fsp links` fixes it.
    fs::create_dir_all(root.join("lib/app/about")).unwrap();
    fs::write(root.join("lib/app/about/page.dart"), page("AboutPage")).unwrap();
    let (ok, _, err) = fsp_full(root, &["links", "--check"], &[]);
    assert!(
        !ok && err.contains(&format!(
            "{manifest_path}: the intent filters between the fsp links markers are out of date"
        )),
        "{err}"
    );
    let stale = fs::read_to_string(root.join(manifest_path)).unwrap();
    assert_eq!(stale, manifest, "--check writes nothing");
    assert!(fsp_full(root, &["links"], &[]).0);
    assert!(fsp_full(root, &["links", "--check"], &[]).0);

    // A changed domain makes the entitlements stale.
    let moved = keys.replace("shop.example.com]", "shop.example.com, www.example.com]");
    fs::write(&pubspec, format!("{base}{moved}")).unwrap();
    let (ok, _, err) = fsp_full(root, &["links", "--check"], &[]);
    assert!(
        !ok && err.contains(&format!(
            "{plist_path}: the applinks: entries of com.apple.developer.associated-domains are out of date"
        )),
        "{err}"
    );
    assert!(fsp_full(root, &["links"], &[]).0);
    assert!(
        fs::read_to_string(root.join(plist_path))
            .unwrap()
            .contains("applinks:www.example.com")
    );
    assert!(fsp_full(root, &["links", "--check"], &[]).0);

    // A filter of the app's own outside the markers is a warning, not a failure.
    let with_own = fs::read_to_string(root.join(manifest_path))
        .unwrap()
        .replacen(
            "        </activity>\n",
            "            <intent-filter>\n                <action android:name=\"android.intent.action.VIEW\"/>\n                <data android:scheme=\"https\" android:host=\"shop.example.com\"/>\n            </intent-filter>\n        </activity>\n",
            1,
        );
    fs::write(root.join(manifest_path), with_own).unwrap();
    let (ok, _, err) = fsp_full(root, &["links", "--check"], &[]);
    assert!(
        ok && err.contains(&format!("warning: {manifest_path}:"))
            && err.contains(
                "an <intent-filter> for `shop.example.com` outside the fsp links markers"
            ),
        "{err}"
    );
}

/// Flutter's own deep linking switch turned off is a warning of `fsp links`, in both files, and
/// neither file is touched by it.
#[test]
fn links_warns_when_flutter_deep_linking_is_off() {
    let dir = project();
    let root = dir.path();
    let pubspec = root.join("pubspec.yaml");
    let base = fs::read_to_string(&pubspec).unwrap();
    let manifest_path = "android/app/src/main/AndroidManifest.xml";
    let plist_path = "ios/Runner/Runner.entitlements";
    fs::write(
        &pubspec,
        format!(
            "{base}{LINKS}    android_manifest: {manifest_path}\n    ios_entitlements: {plist_path}\n"
        ),
    )
    .unwrap();
    fs::create_dir_all(root.join("android/app/src/main")).unwrap();
    fs::create_dir_all(root.join("ios/Runner")).unwrap();
    let template = include_str!("fixtures/links/AndroidManifest.xml");
    fs::write(root.join(manifest_path), template).unwrap();
    let (ok, _, err) = fsp_full(root, &["links"], &[]);
    assert!(
        ok && !err.contains("eeplinking") && !err.contains("eepLinking"),
        "{err}"
    );

    // Off in the manifest and in Info.plist: two warnings, `--check` still passes.
    let off = fs::read_to_string(root.join(manifest_path)).unwrap().replacen(
        "<intent-filter>\n                <action android:name=\"android.intent.action.MAIN\"/>",
        "<meta-data android:name=\"flutter_deeplinking_enabled\" android:value=\"false\" />\n            <intent-filter>\n                <action android:name=\"android.intent.action.MAIN\"/>",
        1,
    );
    fs::write(root.join(manifest_path), &off).unwrap();
    let info = "<plist version=\"1.0\">\n<dict>\n\t<key>FlutterDeepLinkingEnabled</key>\n\t<false/>\n</dict>\n</plist>\n";
    fs::write(root.join("ios/Runner/Info.plist"), info).unwrap();
    let (ok, _, err) = fsp_full(root, &["links", "--check"], &[]);
    assert!(
        ok && err.contains(&format!(
            "warning: flutter_deeplinking_enabled is false in {manifest_path}: Flutter will not hand links to the router"
        )) && err.contains(
            "warning: FlutterDeepLinkingEnabled is false in ios/Runner/Info.plist: Flutter will not hand links to the router"
        ),
        "{err}"
    );
    assert_eq!(fs::read_to_string(root.join(manifest_path)).unwrap(), off);
    assert_eq!(
        fs::read_to_string(root.join("ios/Runner/Info.plist")).unwrap(),
        info
    );
    let (ok, _, err) = fsp_full(root, &["links"], &[]);
    assert!(
        ok && err.contains("warning: flutter_deeplinking_enabled is false"),
        "{err}"
    );
    assert_eq!(
        fs::read_to_string(root.join("ios/Runner/Info.plist")).unwrap(),
        info
    );
}

/// Without `android_manifest:` the manifest is still read, at the path `flutter create` uses,
/// and never written.
#[test]
fn links_reads_the_default_manifest_for_flutter_deep_linking() {
    let dir = project();
    let root = dir.path();
    let pubspec = root.join("pubspec.yaml");
    let base = fs::read_to_string(&pubspec).unwrap();
    fs::write(&pubspec, format!("{base}{LINKS}")).unwrap();
    let manifest_path = "android/app/src/main/AndroidManifest.xml";
    fs::create_dir_all(root.join("android/app/src/main")).unwrap();
    let manifest = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">\n  <application>\n    <activity android:name=\".MainActivity\">\n      <meta-data android:name=\"flutter_deeplinking_enabled\" android:value=\"false\" />\n    </activity>\n  </application>\n</manifest>\n";
    fs::write(root.join(manifest_path), manifest).unwrap();
    let (ok, _, err) = fsp_full(root, &["links"], &[]);
    assert!(
        ok && err.contains(&format!(
            "warning: flutter_deeplinking_enabled is false in {manifest_path}: Flutter will not hand links to the router"
        )),
        "{err}"
    );
    assert_eq!(
        fs::read_to_string(root.join(manifest_path)).unwrap(),
        manifest
    );
}
