//! Runs the built `fsp` binary on the two spellings of `not_found.dart`, and on
//! function views.

use std::fs;
use std::path::Path;
use std::process::Command;

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";
const NF: &str = "class NotFoundPage extends StatelessWidget { const NotFoundPage({super.key, required this.uri}); final Uri uri; }";

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
    let out = Command::new(env!("CARGO_BIN_EXE_fsp"))
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn either_spelling_of_not_found_checks_and_generates() {
    for file in ["not_found.dart", "not-found.dart"] {
        let dir = project("name: demo\n", &[("page.dart", HOME), (file, NF)]);
        let (ok, _, err) = fsp(dir.path(), &["gen"]);
        assert!(ok, "{file}: {err}");
        let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
        assert!(
            code.contains(&format!("import 'app/{file}' as _i1;")),
            "{file}: {code}"
        );
        assert!(
            code.contains("_i1.NotFoundPage(uri: uri)"),
            "{file}: {code}"
        );
        // The configured style doesn't matter for reading.
        let (ok, _, err) = fsp(dir.path(), &["check"]);
        assert!(ok, "{file}: {err}");
    }
    // Whatever `file_style` says.
    let dir = project(
        "name: demo\nfespalier:\n  file_style: kebab\n",
        &[("page.dart", HOME), ("not_found.dart", NF)],
    );
    assert!(fsp(dir.path(), &["check"]).0);
    let dir = project(
        "name: demo\nfespalier:\n  file_style: snake\n",
        &[("page.dart", HOME), ("not-found.dart", NF)],
    );
    assert!(fsp(dir.path(), &["check"]).0);
}

#[test]
fn both_spellings_are_an_error_with_a_code_frame_for_each() {
    let dir = project(
        "name: demo\n",
        &[
            ("page.dart", HOME),
            ("not_found.dart", NF),
            ("not-found.dart", NF),
        ],
    );
    let (ok, _, err) = fsp(dir.path(), &["check"]);
    assert!(!ok, "{err}");
    assert!(
        err.contains("lib/app/not_found.dart:1:1") && err.contains("lib/app/not-found.dart:1:1"),
        "{err}"
    );
    // A frame each: the source line is quoted under both.
    assert_eq!(err.matches("class NotFoundPage").count(), 2, "{err}");
    assert!(
        err.contains("are the same view and both are in this folder; keep one"),
        "{err}"
    );
    assert!(err.contains("2 error(s)"), "{err}");

    let (ok, out, _) = fsp(dir.path(), &["check", "--json"]);
    assert!(!ok);
    let mut files: Vec<String> = out
        .lines()
        .map(|l| {
            serde_json::from_str::<serde_json::Value>(l).unwrap()["file"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect();
    files.sort();
    assert_eq!(files, ["lib/app/not-found.dart", "lib/app/not_found.dart"]);
}

#[test]
fn init_writes_the_configured_style() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  file_style: kebab\n",
    )
    .unwrap();
    let (ok, _, err) = fsp(dir.path(), &["init"]);
    assert!(ok, "{err}");
    assert!(err.contains("new   lib/app/not-found.dart"), "{err}");
    assert!(
        dir.path().join("lib/app/not-found.dart").exists()
            && !dir.path().join("lib/app/not_found.dart").exists()
    );
    let (ok, _, err) = fsp(dir.path(), &["check"]);
    assert!(ok, "{err}");

    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    assert!(fsp(dir.path(), &["init"]).0);
    assert!(
        dir.path().join("lib/app/not_found.dart").exists()
            && !dir.path().join("lib/app/not-found.dart").exists()
    );
}

#[test]
fn an_unknown_file_style_is_rejected() {
    let dir = project(
        "name: demo\nfespalier:\n  file_style: camel\n",
        &[("page.dart", HOME)],
    );
    let (ok, _, err) = fsp(dir.path(), &["check"]);
    assert!(!ok && err.contains("kebab"), "{err}");
}

#[test]
fn function_views_show_in_the_route_table() {
    let dir = project(
        "name: demo\n",
        &[
            ("page.dart", HOME),
            (
                "(kyc)/shop/name/page.dart",
                "Widget page() => const Text('shop');",
            ),
            (
                "(kyc)/person/name/page.dart",
                "const routeName = 'KycPersonName';\nWidget page({String? back}) => Text('$back');",
            ),
        ],
    );
    let (ok, out, err) = fsp(dir.path(), &["routes", "--json"]);
    assert!(ok, "{err}");
    let rows: Vec<serde_json::Value> = out
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let by = |route: &str| {
        rows.iter()
            .find(|r| r["route"] == route)
            .unwrap_or_else(|| panic!("{route} in {out}"))
    };
    assert_eq!(
        by("ShopNameRoute")["file"],
        "lib/app/(kyc)/shop/name/page.dart"
    );
    assert_eq!(by("KycPersonNameRoute")["params"][0]["name"], "back");
}
