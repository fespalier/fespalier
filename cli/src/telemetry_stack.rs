//! `fsp telemetry`: a local OpenTelemetry stack with fespalier's dashboards (since 0.8.1).
//!
//! The stack is the folder `cli/templates/telemetry/`: a Docker Compose file, an OpenTelemetry
//! collector, OpenObserve with its dashboards, a one-shot importer that loads them, and Grafana
//! (behind `--grafana`) with the same dashboards. The folder runs as it is, and `fsp` embeds it:
//! this command writes it to one per-user folder (`~/.fespalier/telemetry`) and runs
//! `docker compose` there. Nothing is written into the app's repository.
//!
//! The dashboards, `fields.json` and the collector's dimension list in that folder are generated
//! by `scripts/telemetry/build_dashboards.py` from one spec; never edit them by hand.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::net::UdpSocket;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Result, bail};
use clap::Args;

use crate::config::Config;

/// Every file of the stack, by its path in the stack folder. A test compares this list with the
/// files under `cli/templates/telemetry`, so a new file cannot be forgotten.
pub const FILES: &[(&str, &str)] = &[
    (
        "compose.yaml",
        include_str!("../templates/telemetry/compose.yaml"),
    ),
    (
        "env.example",
        include_str!("../templates/telemetry/env.example"),
    ),
    (
        "collector/config.yaml",
        include_str!("../templates/telemetry/collector/config.yaml"),
    ),
    (
        "openobserve/import.py",
        include_str!("../templates/telemetry/openobserve/import.py"),
    ),
    (
        "openobserve/fields.json",
        include_str!("../templates/telemetry/openobserve/fields.json"),
    ),
    (
        "openobserve/report.py",
        include_str!("../templates/telemetry/openobserve/report.py"),
    ),
    (
        "openobserve/dashboards/actions.json",
        include_str!("../templates/telemetry/openobserve/dashboards/actions.json"),
    ),
    (
        "openobserve/dashboards/errors.json",
        include_str!("../templates/telemetry/openobserve/dashboards/errors.json"),
    ),
    (
        "openobserve/dashboards/health.json",
        include_str!("../templates/telemetry/openobserve/dashboards/health.json"),
    ),
    (
        "openobserve/dashboards/screens.json",
        include_str!("../templates/telemetry/openobserve/dashboards/screens.json"),
    ),
    (
        "grafana/provisioning/datasources/fespalier.yaml",
        include_str!("../templates/telemetry/grafana/provisioning/datasources/fespalier.yaml"),
    ),
    (
        "grafana/provisioning/dashboards/fespalier.yaml",
        include_str!("../templates/telemetry/grafana/provisioning/dashboards/fespalier.yaml"),
    ),
    (
        "grafana/dashboards/actions.json",
        include_str!("../templates/telemetry/grafana/dashboards/actions.json"),
    ),
    (
        "grafana/dashboards/errors.json",
        include_str!("../templates/telemetry/grafana/dashboards/errors.json"),
    ),
    (
        "grafana/dashboards/health.json",
        include_str!("../templates/telemetry/grafana/dashboards/health.json"),
    ),
    (
        "grafana/dashboards/screens.json",
        include_str!("../templates/telemetry/grafana/dashboards/screens.json"),
    ),
];

/// `docker compose wait` appeared in Compose 2.20.
const MIN_COMPOSE: (u32, u32) = (2, 20);

/// The dashboard to start with: its title in OpenObserve and Grafana (a test compares it with the
/// generated `health.json`).
const HOME_TITLE: &str = "fespalier · App health";

/// What `--report` says when the stack is not running.
const REPORT_NEEDS_STACK: &str =
    "fsp telemetry --report needs the stack running: start it with `fsp telemetry`";

#[derive(Args)]
pub struct TelemetryCmd {
    /// Also start Grafana, with the same dashboards (on port 3000)
    #[arg(long, conflicts_with_all = ["stop", "reset"])]
    pub grafana: bool,
    /// Accept OTLP from phones on your network (binds 4317 and 4318 to every interface) and
    /// write dart-defines.json with this computer's address
    #[arg(long, conflicts_with_all = ["stop", "reset"])]
    pub lan: bool,
    /// Where the stack's files go (default: ~/.fespalier/telemetry, or FSP_TELEMETRY_DIR)
    #[arg(long, value_name = "DIR")]
    pub dir: Option<PathBuf>,
    /// Write the files and print the command that starts them; don't run Docker
    #[arg(long, conflicts_with_all = ["stop", "reset"])]
    pub no_start: bool,
    /// Stop the stack and keep its data
    #[arg(long, conflicts_with = "reset")]
    pub stop: bool,
    /// Stop the stack and delete its data (the OpenObserve and Grafana volumes)
    #[arg(long)]
    pub reset: bool,
    /// Print how each app is doing, in plain words (the stack must be running)
    #[arg(long, conflicts_with_all = ["grafana", "lan", "no_start", "stop", "reset"])]
    pub report: bool,
}

/// W1: printed after a successful start when the project `fsp` runs in (the working folder or
/// `--project`) has `telemetry` off, so the app would send the stack nothing.
const W1: &str = "⚠ this app sends no fespalier spans yet: set `telemetry: true` under `fespalier:` in pubspec.yaml and install FespalierOtel (README, \"Telemetry\")";

/// Whether W1 applies: a project was found and its config loads with `telemetry` off. A config
/// that does not load is not this command's business.
fn app_sends_nothing(project: Option<&Path>) -> bool {
    project.is_some_and(|p| Config::load(p).is_ok_and(|config| !config.telemetry))
}

/// `fsp telemetry`. Needs no project: the stack is per user, not per app. [`project`] is the
/// project found from the working folder or `--project`, if any; it only decides whether W1 is
/// printed.
pub fn run(cmd: &TelemetryCmd, project: Option<&Path>) -> Result<()> {
    let Some(dir) = resolve_dir(cmd.dir.as_deref(), &|name| std::env::var(name).ok()) else {
        bail!("fsp telemetry can't find your home folder: pass --dir or set FSP_TELEMETRY_DIR");
    };
    let dir = std::path::absolute(&dir).unwrap_or(dir);
    if cmd.stop || cmd.reset {
        return stop(&dir, cmd.reset);
    }
    write_stack(&dir)?;
    if cmd.report {
        check_compose(&dir)?;
        return report(&dir);
    }
    if cmd.no_start {
        eprintln!("{}", wrote_lines(&dir).join("\n"));
        return Ok(());
    }
    check_compose(&dir)?;
    let lan = if cmd.lan { Some(lan_address()?) } else { None };
    let env = read_env(&dir);
    if let Some(ip) = &lan {
        write_dart_defines(&dir, ip, &setting(&env, "FSP_OTLP_HTTP_PORT"))?;
    }
    start(&dir, cmd.grafana, lan.as_deref())?;
    if app_sends_nothing(project) {
        eprintln!("{W1}");
    }
    let env = read_env(&dir);
    eprintln!(
        "{}",
        summary_lines(&env, &dir, cmd.grafana, lan.as_deref()).join("\n")
    );
    Ok(())
}

/// `--dir`, else `FSP_TELEMETRY_DIR`, else `<home>/.fespalier/telemetry`.
fn resolve_dir(explicit: Option<&Path>, var: &dyn Fn(&str) -> Option<String>) -> Option<PathBuf> {
    if let Some(dir) = explicit {
        return Some(dir.to_path_buf());
    }
    let set = |name: &str| var(name).filter(|v| !v.is_empty());
    if let Some(dir) = set("FSP_TELEMETRY_DIR") {
        return Some(PathBuf::from(dir));
    }
    let home = set("HOME").or_else(|| set("USERPROFILE"))?;
    Some(PathBuf::from(home).join(".fespalier").join("telemetry"))
}

/// Writes each file that is missing or differs, and deletes a dashboard file an earlier `fsp`
/// wrote and this one no longer ships. `.env` is written once from `env.example` and never
/// overwritten; nothing else in the folder is touched.
fn write_stack(dir: &Path) -> Result<()> {
    for (rel, content) in FILES {
        write_if_changed(&dir.join(rel), content)?;
    }
    remove_stale_dashboards(dir)?;
    let env = dir.join(".env");
    if !env.exists() {
        write_if_changed(&env, example_env())?;
    }
    Ok(())
}

/// The two dashboard folders belong to `fsp`: a `*.json` in them that `FILES` does not list is
/// a dashboard of an earlier version.
fn remove_stale_dashboards(dir: &Path) -> Result<()> {
    for folder in ["openobserve/dashboards", "grafana/dashboards"] {
        let Ok(entries) = fs::read_dir(dir.join(folder)) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            let listed = FILES
                .iter()
                .any(|(rel, _)| *rel == format!("{folder}/{name}"));
            if !listed
                && path.is_file()
                && name.ends_with(".json")
                && let Err(e) = fs::remove_file(&path)
            {
                bail!("can't remove {}: {e}", path.display());
            }
        }
    }
    Ok(())
}

fn example_env() -> &'static str {
    FILES
        .iter()
        .find(|(rel, _)| *rel == "env.example")
        .map_or("", |(_, content)| content)
}

fn write_if_changed(path: &Path, content: &str) -> Result<()> {
    if fs::read(path).is_ok_and(|have| have == content.as_bytes()) {
        return Ok(());
    }
    let write = || -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, content)
    };
    if let Err(e) = write() {
        bail!("can't write {}: {e}", path.display());
    }
    Ok(())
}

fn wrote_lines(dir: &Path) -> Vec<String> {
    vec![
        format!("✓ wrote the telemetry stack to {}", dir.display()),
        "  start it in that folder: docker compose up -d   (add --profile grafana for Grafana)"
            .to_string(),
    ]
}

/// `docker compose version --short`, and the Compose 2.20 floor.
fn check_compose(dir: &Path) -> Result<()> {
    match probe(&["compose", "version", "--short"]) {
        Err(error) => bail!(
            "fsp telemetry needs Docker with Compose v2.20 or later: `docker compose version` \
             failed ({error}). The stack's files are in {}; start them with \
             `docker compose up -d` in that folder.",
            dir.display()
        ),
        Ok(version) => {
            if parse_compose_version(&version).is_some_and(|v| v < MIN_COMPOSE) {
                bail!(
                    "fsp telemetry needs Docker Compose v2.20 or later (for `docker compose wait`); \
                     this one is {version}"
                );
            }
        }
    }
    // `docker compose version` needs no daemon, and `up -d` without one fails with a message
    // about the Docker API that reads like a port problem.
    if let Err(error) = probe(&["info", "--format", "{{.ServerVersion}}"]) {
        bail!(
            "fsp telemetry needs a running Docker daemon: `docker info` failed ({error}). The \
             stack's files are in {}; start Docker, then run `fsp telemetry` again.",
            dir.display()
        );
    }
    Ok(())
}

/// Runs `docker <args>`: its trimmed stdout, or why it failed (the first line of stderr).
fn probe(args: &[&str]) -> std::result::Result<String, String> {
    let out = Command::new("docker")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).trim().to_string());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    Err(stderr.lines().find(|l| !l.trim().is_empty()).map_or_else(
        || format!("exit {}", exit_code(out.status)),
        |l| l.trim().to_string(),
    ))
}

fn exit_code(status: std::process::ExitStatus) -> String {
    status
        .code()
        .map_or_else(|| "killed by a signal".to_string(), |c| c.to_string())
}

/// `2.29.7-desktop.1` and `v2.29.7` give (2, 29); `5.1.1` gives (5, 1).
fn parse_compose_version(text: &str) -> Option<(u32, u32)> {
    let mut parts = text.trim().trim_start_matches('v').split('.');
    let number = |part: Option<&str>| -> Option<u32> {
        let digits: String = part?.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    };
    let major = number(parts.next())?;
    let minor = number(parts.next())?;
    Some((major, minor))
}

/// A `.env` file: `KEY=VALUE` lines, blank lines and `#` comments.
fn parse_env(text: &str) -> BTreeMap<String, String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.split_once('='))
        .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        .collect()
}

/// The folder's `.env` over the defaults in `env.example`.
fn read_env(dir: &Path) -> BTreeMap<String, String> {
    let mut env = parse_env(example_env());
    if let Ok(text) = fs::read_to_string(dir.join(".env")) {
        env.extend(parse_env(&text));
    }
    env
}

fn setting(env: &BTreeMap<String, String>, key: &str) -> String {
    env.get(key).cloned().unwrap_or_default()
}

/// This computer's IPv4 address on the network, found without sending a packet: connecting a UDP
/// socket to a TEST-NET-1 address only picks the route.
fn lan_address() -> Result<String> {
    let ip = UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| s.connect("192.0.2.1:9").and_then(|()| s.local_addr()))
        .ok()
        .map(|a| a.ip())
        .filter(|ip| !ip.is_loopback() && !ip.is_unspecified());
    match ip {
        Some(ip) => Ok(ip.to_string()),
        None => bail!(
            "fsp telemetry --lan can't find this computer's address on your network; start without \
             --lan and pass --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://<this computer's \
             address>:4318 yourself"
        ),
    }
}

fn write_dart_defines(dir: &Path, ip: &str, http_port: &str) -> Result<()> {
    let content = format!("{{\"OTEL_EXPORTER_OTLP_ENDPOINT\": \"http://{ip}:{http_port}\"}}\n");
    write_if_changed(&dir.join("dart-defines.json"), &content)
}

fn compose(dir: &Path, grafana: bool, args: &[&str]) -> Command {
    let mut command = Command::new("docker");
    command.arg("compose");
    if grafana {
        command.args(["--profile", "grafana"]);
    }
    command.args(args).current_dir(dir).stdin(Stdio::null());
    command
}

/// `docker compose up -d`, then wait for the importer.
fn start(dir: &Path, grafana: bool, lan: Option<&str>) -> Result<()> {
    let mut up = compose(dir, grafana, &["up", "-d"]);
    if let Some(ip) = lan {
        up.env("FSP_OTLP_BIND", "0.0.0.0")
            .env("FSP_OTLP_CORS_ORIGIN", format!("http://{ip}:*"));
    }
    let status = up.status()?;
    if !status.success() {
        bail!(
            "docker compose up failed (exit {}); its output is above. A port in use? Set \
             FSP_OTLP_HTTP_PORT, FSP_OTLP_GRPC_PORT, FSP_O2_PORT or FSP_GRAFANA_PORT in {}/.env",
            exit_code(status),
            dir.display()
        );
    }
    let status = compose(dir, grafana, &["wait", "dashboards"]).status()?;
    if !status.success() {
        bail!(
            "the dashboards were not imported into OpenObserve (exit {}); \
             `docker compose logs dashboards` in {} says why",
            exit_code(status),
            dir.display()
        );
    }
    Ok(())
}

/// `--report`: the importer's Python container runs `report.py`, which asks the running
/// OpenObserve the very questions App health asks and prints the answers in words.
fn report(dir: &Path) -> Result<()> {
    let output = compose(dir, false, &["ps", "--status", "running", "--services"])
        .stderr(Stdio::inherit())
        .output()?;
    if !output.status.success() || !is_running(&String::from_utf8_lossy(&output.stdout)) {
        bail!("{REPORT_NEEDS_STACK}");
    }
    let status = compose(
        dir,
        false,
        &[
            "run",
            "--rm",
            "--no-deps",
            "-T",
            "dashboards",
            "python3",
            "/fespalier/report.py",
        ],
    )
    .status()?;
    if !status.success() {
        bail!("{}", report_failed(&exit_code(status)));
    }
    Ok(())
}

/// Whether `docker compose ps --services` lists OpenObserve.
fn is_running(services: &str) -> bool {
    services.lines().any(|l| l.trim() == "openobserve")
}

fn report_failed(code: &str) -> String {
    format!("the report failed (exit {code}); the lines above say why")
}

/// `--stop` and `--reset`. `--profile grafana` matters: without it `down` leaves a Grafana
/// container that an earlier `--grafana` run started.
fn stop(dir: &Path, reset: bool) -> Result<()> {
    check_compose(dir)?;
    if !dir.join("compose.yaml").is_file() {
        bail!(
            "there is no telemetry stack in {} (no compose.yaml): nothing to stop or reset",
            dir.display()
        );
    }
    let args: &[&str] = if reset { &["down", "-v"] } else { &["down"] };
    let status = compose(dir, true, args).status()?;
    if !status.success() {
        bail!(
            "docker compose down failed (exit {}); its output is above",
            exit_code(status)
        );
    }
    eprintln!("{}", stopped_line(reset));
    Ok(())
}

fn stopped_line(reset: bool) -> &'static str {
    if reset {
        "✓ telemetry stack stopped and its data deleted"
    } else {
        "✓ telemetry stack stopped; its data is kept (fsp telemetry --reset deletes it)"
    }
}

/// How many dashboards the stack carries (its OpenObserve files).
fn dashboard_count() -> usize {
    FILES
        .iter()
        .filter(|(rel, _)| rel.starts_with("openobserve/dashboards/"))
        .count()
}

fn summary_lines(
    env: &BTreeMap<String, String>,
    dir: &Path,
    grafana: bool,
    lan: Option<&str>,
) -> Vec<String> {
    let get = |key: &str| setting(env, key);
    let mut lines = vec![
        format!(
            "✓ telemetry stack running: {} dashboards in OpenObserve, folder fespalier; start with {HOME_TITLE}",
            dashboard_count()
        ),
        format!(
            "  OpenObserve  http://localhost:{}  {} / {}",
            get("FSP_O2_PORT"),
            get("FSP_O2_EMAIL"),
            get("FSP_O2_PASSWORD")
        ),
    ];
    if grafana {
        lines.push(format!(
            "  Grafana      http://localhost:{}  admin / {}",
            get("FSP_GRAFANA_PORT"),
            get("FSP_GRAFANA_PASSWORD")
        ));
    }
    lines.push(format!(
        "  OTLP         http://localhost:{} (HTTP), localhost:{} (gRPC)",
        get("FSP_OTLP_HTTP_PORT"),
        get("FSP_OTLP_GRPC_PORT")
    ));
    lines.push(
        "  The app      FespalierOtel.endpoint() reaches it from an emulator, a simulator, \
         desktop and the web"
            .to_string(),
    );
    if let Some(ip) = lan {
        lines.push(format!(
            "  A phone      flutter run --dart-define-from-file={}/dart-defines.json  (http://{ip}:{})",
            dir.display(),
            get("FSP_OTLP_HTTP_PORT")
        ));
    }
    lines
}

#[cfg(test)]
#[path = "telemetry_stack_tests.rs"]
mod tests;
