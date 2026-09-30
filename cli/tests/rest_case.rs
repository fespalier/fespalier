//! Runs the built `fsp` binary on typed catch-alls and per-folder `caseSensitive`: what
//! the code frames say, and what `fsp routes --json` reports.

use std::fs;
use std::path::Path;
use std::process::Command;

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

fn project(pubspec: &str, files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), pubspec).unwrap();
    fs::create_dir_all(dir.path().join("lib/app")).unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

/// Runs `fsp`, returning success, stdout and stderr.
fn fsp(dir: &Path, args: &[&str]) -> (bool, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_fsp")).args(args).current_dir(dir).output().unwrap();
    (out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
}

const IDS_PAGE: &str = "class IdsPage extends StatelessWidget { const IdsPage({super.key, required this.ids}); final List<int> ids; }";

#[test]
fn a_typed_catch_all_generates_and_shows_its_type_in_the_json_table() {
    let dir = project("name: demo\n", &[("page.dart", HOME), ("compare/$$ids/page.dart", IDS_PAGE)]);
    let (ok, _, err) = fsp(dir.path(), &["gen"]);
    assert!(ok, "{err}");
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(code.contains("(ids: Segment.asIntRest(s, 'ids'))") && code.contains("final List<int> ids;"), "{code}");

    let (ok, out, err) = fsp(dir.path(), &["routes", "--json"]);
    assert!(ok, "{err}");
    let rows: Vec<serde_json::Value> = out.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    let row = rows.iter().find(|r| r["route"] == "IdsRoute").unwrap();
    assert_eq!(row["params"][0]["type"], "List<int>");
    assert_eq!(row["catch_all"]["name"], "ids");
}

#[test]
fn a_type_mismatch_between_files_is_a_code_frame_naming_both() {
    let data = "Future<int> data(Ref ref, {required List<String> ids}) async => 1;";
    let dir = project("name: demo\n", &[("compare/$$ids/page.dart", IDS_PAGE), ("compare/$$ids/data.dart", data)]);
    let (ok, _, err) = fsp(dir.path(), &["check"]);
    assert!(!ok, "{err}");
    assert!(err.contains("`$ids` is List<String> in compare/$$ids/data.dart:1 but List<int> here"), "{err}");
    // The frame quotes the line that disagrees, under the file it is in.
    assert!(err.contains("lib/app/compare/$$ids/page.dart:1:") && err.contains("final List<int> ids;"), "{err}");
}

#[test]
fn an_unsupported_element_type_says_what_is_supported() {
    let page = "class IdsPage extends StatelessWidget { const IdsPage({super.key, required this.ids}); final List<Object> ids; }";
    let dir = project("name: demo\n", &[("compare/$$ids/page.dart", page)]);
    let (ok, _, err) = fsp(dir.path(), &["check"]);
    assert!(!ok && err.contains("a `List` of String, int, double, num, bool or DateTime"), "{err}");
}

#[test]
fn a_route_dart_changes_only_its_folder() {
    let dir = project(
        "name: demo\n",
        &[
            ("page.dart", HOME),
            ("shop/route.dart", "const caseSensitive = false;\n"),
            ("shop/page.dart", "class ShopPage extends StatelessWidget { const ShopPage({super.key}); }"),
        ],
    );
    let (ok, _, err) = fsp(dir.path(), &["gen"]);
    assert!(ok, "{err}");
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert_eq!(code.matches("caseSensitive: false,").count(), 1, "{code}");
    // The file is read, never imported.
    assert!(!code.contains("route.dart"), "{code}");
    let (ok, _, err) = fsp(dir.path(), &["check"]);
    assert!(ok && err.contains("no errors"), "{err}");
}

#[test]
fn a_route_dart_that_is_not_a_literal_is_a_code_frame() {
    let dir = project(
        "name: demo\n",
        &[("page.dart", HOME), ("shop/route.dart", "const caseSensitive = kStrict;\n"), ("shop/page.dart", HOME)],
    );
    let (ok, _, err) = fsp(dir.path(), &["check"]);
    assert!(!ok, "{err}");
    assert!(err.contains("lib/app/shop/route.dart:1:7") && err.contains("const caseSensitive = kStrict;"), "{err}");
    assert!(err.contains("`caseSensitive` must be a `true` or `false` literal"), "{err}");
}
