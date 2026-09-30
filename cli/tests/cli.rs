//! Runs the built `fsp` binary: success lines, `fsp new`, and `fsp watch`.

use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

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
    let out = Command::new(env!("CARGO_BIN_EXE_fsp")).args(args).current_dir(dir).output().unwrap();
    assert!(out.stdout.is_empty(), "stdout: {}", String::from_utf8_lossy(&out.stdout));
    (out.status.success(), String::from_utf8_lossy(&out.stderr).into_owned())
}

#[test]
fn gen_and_check_report_success() {
    let dir = project();
    assert_eq!(fsp(dir.path(), &["check"]), (true, "✓ 1 route, no errors\n".into()));
    assert!(!dir.path().join("lib/app.g.dart").exists(), "check must not write");
    assert_eq!(fsp(dir.path(), &["gen"]), (true, "✓ 1 route → lib/app.g.dart\n".into()));
    assert_eq!(fsp(dir.path(), &["gen"]), (true, "✓ 1 route, lib/app.g.dart unchanged\n".into()));
    assert_eq!(fsp(dir.path(), &["check"]), (true, "✓ 1 route, no errors\n".into()));
}

#[test]
fn check_failure_keeps_its_exit_code() {
    let dir = project();
    fs::write(dir.path().join("lib/app/page.dart"), "class P extends StatelessWidget { const P({required this.x}); final int x; }").unwrap();
    let (ok, err) = fsp(dir.path(), &["check"]);
    assert!(!ok && err.contains("1 error(s)") && !err.contains('✓'), "{err}");
}

#[test]
fn new_generates_typed_routes_and_says_so() {
    let dir = project();
    let (ok, err) = fsp(dir.path(), &["new", "products/[id]"]);
    assert!(ok, "{err}");
    assert!(err.contains("  new   lib/app/products/$id/page.dart"), "{err}");
    assert!(err.trim_end().ends_with("✓ 2 routes → lib/app.g.dart"), "{err}");
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(code.contains("final class ProductsIdRoute extends TypedLocation"), "{code}");
}

#[test]
fn new_group_layout_needs_no_page() {
    let dir = project();
    let (ok, err) = fsp(dir.path(), &["new", "(account)", "--layout"]);
    assert!(ok, "{err}");
    assert!(dir.path().join("lib/app/(account)/layout.dart").exists());
    assert!(!dir.path().join("lib/app/(account)/page.dart").exists());
    assert!(err.trim_end().ends_with("✓ 1 route → lib/app.g.dart"), "{err}");
}

#[test]
fn new_names_the_files_it_left_behind_when_gen_fails() {
    let dir = project();
    // A bare group has nothing to scaffold.
    let (ok, err) = fsp(dir.path(), &["new", "(oops)"]);
    assert!(!ok);
    assert!(err.contains("nothing to create"), "{err}");
    // Break the tree, then scaffold something: gen fails, and the message lists what was written.
    fs::write(dir.path().join("lib/app/page.dart"), "class P extends StatelessWidget { const P({required this.x}); final int x; }").unwrap();
    let (ok, err) = fsp(dir.path(), &["new", "docs"]);
    assert!(!ok);
    assert!(err.contains("`fsp new` created:\n  lib/app/docs/page.dart\n"), "{err}");
    assert!(err.contains("Fix or delete them"), "{err}");
}

// --- watch -------------------------------------------------------------------

struct Watch {
    child: Child,
    log: std::path::PathBuf,
}

impl Watch {
    fn start(dir: &Path) -> Watch {
        let log = dir.join("watch.log");
        let file = fs::File::create(&log).unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_fsp"))
            .arg("watch")
            .current_dir(dir)
            .stdout(Stdio::null())
            .stderr(file)
            .spawn()
            .unwrap();
        let w = Watch { child, log };
        w.wait_for("watching lib/app/");
        w
    }

    fn text(&self) -> String {
        let mut s = String::new();
        fs::File::open(&self.log).unwrap().read_to_string(&mut s).unwrap();
        s
    }

    fn lines(&self) -> usize {
        self.text().lines().count()
    }

    fn wait_for(&self, needle: &str) {
        let end = Instant::now() + Duration::from_secs(10);
        while !self.text().contains(needle) {
            assert!(Instant::now() < end, "timed out waiting for `{needle}`; got:\n{}", self.text());
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
    assert!(text.starts_with("✓ 1 route → lib/app.g.dart (") && text.ends_with(")\nwatching lib/app/ …\n"), "{text}");
    assert_eq!(w.lines(), 2, "{}", w.text());

    // A new page regenerates once.
    fs::create_dir_all(root.join("lib/app/about")).unwrap();
    fs::write(root.join("lib/app/about/page.dart"), page("AboutPage")).unwrap();
    w.wait_for("✓ 2 routes → lib/app.g.dart");
    w.settle();
    assert_eq!(w.lines(), 3, "{}", w.text());
    assert!(fs::read_to_string(root.join("lib/app.g.dart")).unwrap().contains("AboutRoute"));

    // Rewriting a file with the same content changes nothing, so it prints nothing.
    fs::write(root.join("lib/app/about/page.dart"), page("AboutPage")).unwrap();
    w.settle();
    assert_eq!(w.lines(), 3, "{}", w.text());

    // Deleting a folder regenerates.
    fs::remove_dir_all(root.join("lib/app/about")).unwrap();
    w.wait_for("✓ 1 route → lib/app.g.dart (");
    w.settle();
    assert_eq!(w.lines(), 4, "{}", w.text());
    assert!(!fs::read_to_string(root.join("lib/app.g.dart")).unwrap().contains("AboutRoute"));

    // An invalid file prints its error once, and fixing it says so.
    fs::write(root.join("lib/app/page.dart"), "class P extends StatelessWidget { const P({required this.x}); final int x; }").unwrap();
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
    fs::write(root.join("pubspec.yaml"), "name: demo\nfespalier:\n  output: lib/app/routes.g.dart\n").unwrap();
    let w = Watch::start(root);
    w.settle();
    sleep(Duration::from_secs(1));
    // Writing routes.g.dart into the watched folder must not loop.
    assert_eq!(w.lines(), 2, "{}", w.text());
}

// --- routes, --json, --format ------------------------------------------------

/// Like `fsp`, but returns stdout too, and takes extra environment.
fn fsp_full(dir: &Path, args: &[&str], env: &[(&str, &str)]) -> (bool, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_fsp")).args(args).envs(env.iter().copied()).current_dir(dir).output().unwrap();
    (out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
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
    assert_eq!(out, "/              HomeRoute     page.dart\n/products/:id  ProductRoute  products/$id/page.dart\n");
    let (ok, out, err) = fsp_full(dir.path(), &["routes", "--json"], &[]);
    assert!(ok, "{err}");
    let rows: Vec<serde_json::Value> = out.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
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
fn routes_fails_on_errors() {
    let dir = project();
    fs::write(dir.path().join("lib/app/page.dart"), "class P extends StatelessWidget { const P({required this.x}); final int x; }").unwrap();
    let (ok, out, err) = fsp_full(dir.path(), &["routes"], &[]);
    assert!(!ok && out.is_empty() && err.contains("1 error(s)"), "{out}{err}");
}

#[test]
fn json_diagnostics_go_to_stdout_as_lines() {
    let dir = project();
    fs::write(dir.path().join("lib/app/page.dart"), "class P extends StatelessWidget {\n  const P({required this.x});\n  final int x;\n}").unwrap();
    for cmd in ["check", "gen"] {
        let (ok, out, err) = fsp_full(dir.path(), &[cmd, "--json"], &[]);
        assert!(!ok, "{err}");
        assert!(!err.contains("┌─"), "no codespan rendering with --json: {err}");
        assert!(err.contains("1 error(s)"), "{err}");
        let lines: Vec<serde_json::Value> = out.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(lines.len(), 1, "{out}");
        assert_eq!(lines[0]["file"], "lib/app/page.dart");
        assert_eq!(lines[0]["severity"], "error");
        assert_eq!(lines[0]["line"], 2);
        assert!(lines[0]["column"].as_u64().unwrap() >= 1);
        assert!(lines[0]["message"].as_str().unwrap().contains("can't fill `x`"), "{out}");
    }
    // Clean projects print nothing on stdout.
    fs::write(dir.path().join("lib/app/page.dart"), page("HomePage")).unwrap();
    let (ok, out, _) = fsp_full(dir.path(), &["check", "--json"], &[]);
    assert!(ok && out.is_empty());
}

/// A stand-in for `dart` whose `format` prepends a marker line to stdin.
#[cfg(unix)]
fn fake_dart(dir: &Path) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("fake-dart");
    fs::write(&path, "#!/bin/sh\n[ \"$1\" = format ] || exit 2\necho '// formatted'\ncat\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
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
    assert!(fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap().starts_with("// formatted\n// GENERATED"));
    let (ok, _, err) = fsp_full(dir.path(), &["gen", "--format"], &env);
    assert!(ok && err.contains("lib/app.g.dart unchanged"), "{err}");
    // Without the flag the file is unformatted again (the default doesn't format).
    let (ok, _, err) = fsp_full(dir.path(), &["gen"], &env);
    assert!(ok && err.contains("→ lib/app.g.dart"), "{err}");
    assert!(fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap().starts_with("// GENERATED"));
}

#[cfg(unix)]
#[test]
fn format_key_in_pubspec_turns_it_on() {
    let dir = project();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\nfespalier:\n  format: true\n").unwrap();
    let dart = fake_dart(dir.path());
    let (ok, _, err) = fsp_full(dir.path(), &["gen"], &[("FSP_DART", dart.to_str().unwrap())]);
    assert!(ok, "{err}");
    assert!(fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap().starts_with("// formatted\n"));
}

#[test]
fn format_without_dart_warns_and_writes_unformatted() {
    let dir = project();
    let (ok, _, err) = fsp_full(dir.path(), &["gen", "--format"], &[("FSP_DART", "/nonexistent/dart")]);
    assert!(ok, "{err}");
    assert!(err.contains("warning: not formatting") && err.contains("not on PATH"), "{err}");
    assert!(fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap().starts_with("// GENERATED"));
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
    write("(buyer)/layout.dart", "class BuyerLayout extends StatelessWidget { const BuyerLayout({super.key, required this.child}); final Widget child; }");
    write(
        "(buyer)/products/$id/page.dart",
        "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id, this.tab, required this.data}); final int id; final String? tab; final Item data; }",
    );
    write("(buyer)/products/$id/data.dart", "Future<Item> data(Ref ref, {required int id}) async => x;");
    write("(buyer)/products/$id/meta.dart", "const meta = PageMeta(code: 'B04');");
    write("old/redirect.dart", "String redirect() => '/';");
    write("(tabs)/layout.dart", "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.shell}); final StatefulNavigationShell shell; }");
    write("(tabs)/one/page.dart", &page("OnePage"));
    let (ok, out, err) = fsp_full(root, &["routes", "--json"], &[]);
    assert!(ok, "{err}");
    let rows: Vec<&str> = out.lines().collect();
    assert_eq!(rows.len(), 4, "{out}");
    let row = |pattern: &str| {
        rows.iter().find(|r| serde_json::from_str::<serde_json::Value>(r).unwrap()["pattern"] == pattern).unwrap().to_string()
    };
    // Key order is part of the shape (serde_json keeps it), so compare the text.
    assert_eq!(
        row("/products/:id"),
        r#"{"pattern":"/products/:id","route":"ProductRoute","file":"lib/app/(buyer)/products/$id/page.dart","tags":["data"],"params":[{"name":"id","type":"int","in":"path"},{"name":"tab","type":"String?","in":"query"}],"folder":"(buyer)/products/$id","presentation":"page","groups":["(buyer)"],"layouts":["(buyer)"],"tabs":[],"data_keys":["id"],"meta":"lib/app/(buyer)/products/$id/meta.dart"}"#
    );
    assert_eq!(
        row("/old"),
        r#"{"pattern":"/old","route":"OldRoute","file":"lib/app/old/redirect.dart","tags":["redirect"],"params":[],"folder":"old","presentation":"redirect","groups":[],"layouts":[],"tabs":[],"data_keys":null,"meta":null}"#
    );
    assert_eq!(
        row("/one"),
        r#"{"pattern":"/one","route":"OneRoute","file":"lib/app/(tabs)/one/page.dart","tags":[],"params":[],"folder":"(tabs)/one","presentation":"page","groups":["(tabs)"],"layouts":["(tabs)"],"tabs":[{"layout":"(tabs)","index":0,"branch":"one"}],"data_keys":null,"meta":null}"#
    );
    // The app folder's own page has an empty folder.
    let home: serde_json::Value = serde_json::from_str(&row("/")).unwrap();
    assert_eq!(home["folder"], "");
    assert_eq!(home["layouts"], serde_json::json!([]));
}

#[test]
fn output_manifest_writes_a_second_library_that_check_knows_about() {
    let dir = project();
    let root = dir.path();
    fs::write(root.join("pubspec.yaml"), "name: demo\nfespalier:\n  output_manifest: lib/app.routes.g.dart\n").unwrap();
    assert_eq!(fsp(root, &["check"]), (true, "✓ 1 route, no errors\n".into()));
    assert!(!root.join("lib/app.routes.g.dart").exists(), "check must not write");
    assert_eq!(fsp(root, &["gen"]), (true, "✓ 1 route → lib/app.g.dart, lib/app.routes.g.dart\n".into()));
    let manifest = fs::read_to_string(root.join("lib/app.routes.g.dart")).unwrap();
    assert!(manifest.contains("abstract final class AppManifest {") && manifest.contains("import 'app.g.dart';"), "{manifest}");
    assert!(!fs::read_to_string(root.join("lib/app.g.dart")).unwrap().contains("AppManifest"));
    assert_eq!(fsp(root, &["gen"]), (true, "✓ 1 route, lib/app.g.dart, lib/app.routes.g.dart unchanged\n".into()));

    // With `meta: required`, a route without a meta.dart is an error naming its folder.
    fs::write(root.join("pubspec.yaml"), "name: demo\nfespalier:\n  meta: required\n").unwrap();
    let (ok, err) = fsp(root, &["check"]);
    assert!(!ok && err.contains("the app folder has no meta.dart") && err.contains("1 error(s)"), "{err}");
    fs::write(root.join("lib/app/meta.dart"), "const meta = 'home';").unwrap();
    assert_eq!(fsp(root, &["check"]), (true, "✓ 1 route, no errors\n".into()));
}

#[test]
fn watch_ignores_a_manifest_file_inside_the_app_folder() {
    let dir = project();
    let root = dir.path();
    fs::write(root.join("pubspec.yaml"), "name: demo\nfespalier:\n  output_manifest: lib/app/routes.g.dart\n").unwrap();
    let w = Watch::start(root);
    w.settle();
    sleep(Duration::from_secs(1));
    // Writing the manifest into the watched folder must not loop.
    assert_eq!(w.lines(), 2, "{}", w.text());
    assert!(root.join("lib/app/routes.g.dart").exists());
}
