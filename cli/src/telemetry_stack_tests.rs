use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use super::{
    FILES, dashboard_count, parse_compose_version, parse_env, read_env, resolve_dir, stopped_line,
    summary_lines, write_stack, wrote_lines,
};

fn walk(dir: &Path, root: &Path, found: &mut BTreeSet<String>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            walk(&path, root, found);
        } else {
            let rel = path.strip_prefix(root).unwrap();
            found.insert(rel.to_string_lossy().replace('\\', "/"));
        }
    }
}

#[test]
fn files_lists_every_file_under_the_template_folder() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("templates/telemetry");
    let mut on_disk = BTreeSet::new();
    walk(&root, &root, &mut on_disk);
    let listed: BTreeSet<String> = FILES.iter().map(|(rel, _)| (*rel).to_string()).collect();
    assert_eq!(listed, on_disk);
    assert_eq!(listed.len(), FILES.len(), "a path is listed twice");
}

#[test]
fn the_stack_carries_six_dashboards() {
    assert_eq!(dashboard_count(), 6);
}

#[test]
fn writes_every_file_into_an_empty_folder() {
    let dir = tempfile::tempdir().unwrap();
    write_stack(dir.path()).unwrap();
    for (rel, content) in FILES {
        assert_eq!(
            &fs::read_to_string(dir.path().join(rel)).unwrap(),
            content,
            "{rel}"
        );
    }
    let env = fs::read_to_string(dir.path().join(".env")).unwrap();
    assert_eq!(
        env,
        fs::read_to_string(dir.path().join("env.example")).unwrap()
    );
}

#[test]
fn env_is_written_once_and_never_overwritten() {
    let dir = tempfile::tempdir().unwrap();
    write_stack(dir.path()).unwrap();
    fs::write(dir.path().join(".env"), "FSP_O2_PORT=6000\n").unwrap();
    write_stack(dir.path()).unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join(".env")).unwrap(),
        "FSP_O2_PORT=6000\n"
    );
}

#[test]
fn a_changed_file_is_rewritten_and_an_unrelated_one_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    write_stack(dir.path()).unwrap();
    fs::write(dir.path().join("compose.yaml"), "edited").unwrap();
    fs::write(dir.path().join("notes.txt"), "mine").unwrap();
    write_stack(dir.path()).unwrap();
    let compose = FILES
        .iter()
        .find(|(rel, _)| *rel == "compose.yaml")
        .unwrap()
        .1;
    assert_eq!(
        fs::read_to_string(dir.path().join("compose.yaml")).unwrap(),
        compose
    );
    assert_eq!(
        fs::read_to_string(dir.path().join("notes.txt")).unwrap(),
        "mine"
    );
}

#[test]
fn a_file_that_cannot_be_written_names_the_path() {
    let dir = tempfile::tempdir().unwrap();
    // A file where a folder must go.
    fs::write(dir.path().join("collector"), "in the way").unwrap();
    let error = write_stack(dir.path()).unwrap_err().to_string();
    assert!(
        error.starts_with(&format!(
            "can't write {}",
            dir.path().join("collector").display()
        )),
        "{error}"
    );
}

#[test]
fn parses_the_compose_versions_docker_prints() {
    assert_eq!(parse_compose_version("2.20.0"), Some((2, 20)));
    assert_eq!(parse_compose_version("v2.29.7-desktop.1"), Some((2, 29)));
    assert_eq!(parse_compose_version("2.29.7-desktop.1\n"), Some((2, 29)));
    assert_eq!(parse_compose_version("5.1.1"), Some((5, 1)));
    assert_eq!(parse_compose_version("2.19.1"), Some((2, 19)));
    assert!(parse_compose_version("2.19.1").unwrap() < super::MIN_COMPOSE);
    assert!(parse_compose_version("2.20.0").unwrap() >= super::MIN_COMPOSE);
    assert!(parse_compose_version("5.1.1").unwrap() >= super::MIN_COMPOSE);
    assert_eq!(parse_compose_version("dev"), None);
    assert_eq!(parse_compose_version(""), None);
}

#[test]
fn reads_env_files() {
    let env = parse_env("# comment\n\nFSP_O2_PORT=6000\n  FSP_O2_EMAIL = a@b.c \nnot a pair\n");
    assert_eq!(env.get("FSP_O2_PORT").map(String::as_str), Some("6000"));
    assert_eq!(env.get("FSP_O2_EMAIL").map(String::as_str), Some("a@b.c"));
    assert_eq!(env.len(), 2);
}

#[test]
fn the_folders_env_overrides_the_defaults_and_missing_keys_fall_back() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(
        read_env(dir.path()).get("FSP_O2_PORT").map(String::as_str),
        Some("5080")
    );
    fs::write(dir.path().join(".env"), "FSP_O2_PORT=6000\n").unwrap();
    let env = read_env(dir.path());
    assert_eq!(env.get("FSP_O2_PORT").map(String::as_str), Some("6000"));
    assert_eq!(
        env.get("FSP_OTLP_HTTP_PORT").map(String::as_str),
        Some("4318")
    );
}

#[test]
fn the_summary_for_a_default_run() {
    let dir = tempfile::tempdir().unwrap();
    let lines = summary_lines(&read_env(dir.path()), Path::new("/stack"), false, None);
    assert_eq!(
        lines,
        vec![
            "✓ telemetry stack running: 6 dashboards in OpenObserve, folder fespalier",
            "  OpenObserve  http://localhost:5080  dev@fespalier.local / Fespalier-local-1",
            "  OTLP         http://localhost:4318 (HTTP), localhost:4317 (gRPC)",
            "  The app      FespalierOtel.endpoint() reaches it from an emulator, a simulator, desktop and the web",
        ]
    );
}

#[test]
fn the_summary_with_grafana_lan_and_a_custom_env() {
    let env = parse_env("FSP_O2_PORT=6000\nFSP_GRAFANA_PORT=3100\nFSP_OTLP_HTTP_PORT=4400\n");
    let mut full = read_env(Path::new("/nonexistent"));
    full.extend(env);
    let lines = summary_lines(&full, Path::new("/stack"), true, Some("192.168.1.20"));
    assert_eq!(
        lines[1],
        "  OpenObserve  http://localhost:6000  dev@fespalier.local / Fespalier-local-1"
    );
    assert_eq!(
        lines[2],
        "  Grafana      http://localhost:3100  admin / Fespalier-local-1"
    );
    assert_eq!(
        lines[3],
        "  OTLP         http://localhost:4400 (HTTP), localhost:4317 (gRPC)"
    );
    assert_eq!(
        lines[5],
        "  A phone      flutter run --dart-define-from-file=/stack/dart-defines.json  (http://192.168.1.20:4400)"
    );
    assert_eq!(lines.len(), 6);
}

#[test]
fn the_other_lines() {
    assert_eq!(
        wrote_lines(Path::new("/s")),
        vec![
            "✓ wrote the telemetry stack to /s",
            "  start it in that folder: docker compose up -d   (add --profile grafana for Grafana)",
        ]
    );
    assert_eq!(
        stopped_line(false),
        "✓ telemetry stack stopped; its data is kept (fsp telemetry --reset deletes it)"
    );
    assert_eq!(
        stopped_line(true),
        "✓ telemetry stack stopped and its data deleted"
    );
}

#[test]
fn chooses_the_folder() {
    let vars = |pairs: &'static [(&str, &str)]| {
        move |name: &str| {
            pairs
                .iter()
                .find(|(k, _)| *k == name)
                .map(|(_, v)| (*v).to_string())
        }
    };
    let explicit = PathBuf::from("ops/telemetry");
    assert_eq!(
        resolve_dir(
            Some(&explicit),
            &vars(&[("FSP_TELEMETRY_DIR", "/x"), ("HOME", "/h")])
        ),
        Some(explicit.clone())
    );
    assert_eq!(
        resolve_dir(None, &vars(&[("FSP_TELEMETRY_DIR", "/x"), ("HOME", "/h")])),
        Some(PathBuf::from("/x"))
    );
    assert_eq!(
        resolve_dir(None, &vars(&[("FSP_TELEMETRY_DIR", ""), ("HOME", "/h")])),
        Some(PathBuf::from("/h/.fespalier/telemetry"))
    );
    assert_eq!(
        resolve_dir(None, &vars(&[("USERPROFILE", "C:\\Users\\a")])),
        Some(
            PathBuf::from("C:\\Users\\a")
                .join(".fespalier")
                .join("telemetry")
        )
    );
    assert_eq!(resolve_dir(None, &vars(&[])), None);
}
