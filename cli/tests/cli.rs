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
