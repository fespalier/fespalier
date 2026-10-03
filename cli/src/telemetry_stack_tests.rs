use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use clap::Parser;

use super::{
    FILES, HOME_TITLE, REPORT_NEEDS_STACK, TelemetryCmd, dashboard_count, is_running,
    parse_compose_version, parse_env, read_env, report_failed, resolve_dir, stopped_line,
    summary_lines, write_stack, wrote_lines,
};

#[derive(Parser)]
struct Wrapper {
    #[command(flatten)]
    cmd: TelemetryCmd,
}

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
fn the_stack_carries_four_dashboards() {
    assert_eq!(dashboard_count(), 4);
    for backend in ["openobserve", "grafana"] {
        let mut names: Vec<&str> = FILES
            .iter()
            .filter_map(|(rel, _)| rel.strip_prefix(&format!("{backend}/dashboards/")))
            .collect();
        names.sort_unstable();
        assert_eq!(
            names,
            ["actions.json", "errors.json", "health.json", "screens.json"]
        );
    }
    assert!(FILES.iter().any(|(rel, _)| *rel == "openobserve/report.py"));
}

#[test]
fn the_home_title_is_the_title_of_the_generated_health_dashboard() {
    for backend in ["openobserve", "grafana"] {
        let (_, json) = FILES
            .iter()
            .find(|(rel, _)| *rel == format!("{backend}/dashboards/health.json"))
            .unwrap();
        let dashboard: serde_json::Value = serde_json::from_str(json).unwrap();
        assert_eq!(dashboard["title"], HOME_TITLE, "{backend}");
    }
    let compose = FILES
        .iter()
        .find(|(rel, _)| *rel == "compose.yaml")
        .unwrap()
        .1;
    assert!(compose.contains("/etc/fespalier/grafana-dashboards/health.json"));
}

#[test]
fn a_dashboard_an_earlier_version_wrote_is_deleted_and_nothing_else() {
    let dir = tempfile::tempdir().unwrap();
    write_stack(dir.path()).unwrap();
    for stale in [
        "openobserve/dashboards/navigation.json",
        "grafana/dashboards/guards.json",
    ] {
        fs::write(dir.path().join(stale), "{}").unwrap();
    }
    fs::write(dir.path().join("notes.txt"), "mine").unwrap();
    fs::write(dir.path().join("openobserve/dashboards/notes.txt"), "mine").unwrap();
    fs::write(dir.path().join(".env"), "FSP_O2_PORT=6000\n").unwrap();
    write_stack(dir.path()).unwrap();
    assert!(
        !dir.path()
            .join("openobserve/dashboards/navigation.json")
            .exists()
    );
    assert!(!dir.path().join("grafana/dashboards/guards.json").exists());
    for (rel, content) in FILES {
        assert_eq!(
            &fs::read_to_string(dir.path().join(rel)).unwrap(),
            content,
            "{rel}"
        );
    }
    assert_eq!(
        fs::read_to_string(dir.path().join("notes.txt")).unwrap(),
        "mine"
    );
    assert_eq!(
        fs::read_to_string(dir.path().join("openobserve/dashboards/notes.txt")).unwrap(),
        "mine"
    );
    assert_eq!(
        fs::read_to_string(dir.path().join(".env")).unwrap(),
        "FSP_O2_PORT=6000\n"
    );
}

#[test]
fn report_conflicts_with_every_start_and_stop_flag() {
    assert!(
        Wrapper::try_parse_from(["fsp", "--report"])
            .unwrap()
            .cmd
            .report
    );
    assert!(Wrapper::try_parse_from(["fsp", "--report", "--dir", "x"]).is_ok());
    for flag in ["--grafana", "--lan", "--no-start", "--stop", "--reset"] {
        let error = Wrapper::try_parse_from(["fsp", "--report", flag])
            .err()
            .unwrap()
            .to_string();
        assert!(error.contains("cannot be used with"), "{flag}: {error}");
    }
}

#[test]
fn the_report_messages() {
    assert_eq!(
        REPORT_NEEDS_STACK,
        "fsp telemetry --report needs the stack running: start it with `fsp telemetry`"
    );
    assert_eq!(
        report_failed("1"),
        "the report failed (exit 1); the lines above say why"
    );
    assert!(is_running("collector\nopenobserve\n"));
    assert!(!is_running("collector\ngrafana\n"));
    assert!(!is_running(""));
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
            "✓ telemetry stack running: 4 dashboards in OpenObserve, folder fespalier; start with fespalier · App health",
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
