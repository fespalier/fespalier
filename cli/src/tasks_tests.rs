//! `tasks:` in pubspec.yaml: every shape, every message, the commands built from them, and the
//! text of `--dry-run` and of `fsp run` with no name.

use std::fs;
use std::path::Path;

use serde_yaml_ng::Value;

use crate::config::{Config, Pubspec};
use crate::dev;
use crate::tasks::{Cmd, Env, Task, Tasks, prepare, quote_cmd, quote_sh, resolve_windows};

fn parse(yaml: &str) -> anyhow::Result<Tasks> {
    let v: Value = serde_yaml_ng::from_str(yaml).unwrap();
    Tasks::from_value(Some(&v))
}

fn err(yaml: &str) -> String {
    format!("{:#}", parse(yaml).unwrap_err())
}

fn sh(s: &str) -> Cmd {
    Cmd::Shell(s.to_string())
}

fn argv(words: &[&str]) -> Cmd {
    Cmd::Argv(words.iter().map(|w| (*w).to_string()).collect())
}

fn task(tasks: &Tasks, name: &str) -> Task {
    tasks
        .0
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, t)| t.clone())
        .unwrap()
}

// --- shapes ------------------------------------------------------------------------------------

#[test]
fn no_section_is_no_tasks() {
    assert_eq!(Tasks::from_value(None).unwrap(), Tasks::default());
    assert_eq!(
        Tasks::from_config(&Config::default()).unwrap(),
        Tasks::default()
    );
}

#[test]
fn a_task_can_be_a_string_a_list_or_a_map() {
    let t = parse(
        "
codegen: dart run build_runner build -d
check: [flutter, test]
web:
  run: fsp build web --release
  after: fsp size --check
",
    )
    .unwrap();
    assert_eq!(
        task(&t, "codegen").run,
        Some(sh("dart run build_runner build -d"))
    );
    assert_eq!(task(&t, "check").run, Some(argv(&["flutter", "test"])));
    assert_eq!(task(&t, "web").run, Some(sh("fsp build web --release")));
    assert_eq!(task(&t, "web").after, vec![sh("fsp size --check")]);
    // In the order the pubspec has them.
    assert_eq!(
        t.0.iter().map(|(n, _)| n.as_str()).collect::<Vec<_>>(),
        ["codegen", "check", "web"]
    );
}

#[test]
fn before_and_after_take_a_command_or_a_list_of_commands() {
    let t = parse(
        "
dev:
  before: dart run build_runner build -d
  after: [echo one, [echo, two]]
build:
  before: [dart, run, x]
  run: flutter build
",
    )
    .unwrap();
    assert_eq!(
        task(&t, "dev").before,
        vec![sh("dart run build_runner build -d")]
    );
    assert_eq!(
        task(&t, "dev").after,
        vec![sh("echo one"), argv(&["echo", "two"])]
    );
    // A list of strings is a list of shell commands: three of them, not one argv.
    assert_eq!(
        task(&t, "build").before,
        vec![sh("dart"), sh("run"), sh("x")]
    );
}

#[test]
fn with_keeps_its_order_and_env_values_become_text() {
    let t = parse(
        "
dev:
  with:
    zebra: echo z
    alpha: [tail, -f, log]
  env:
    API_URL: http://localhost:8080
    PORT: 8080
    RATIO: 1.5
    VERBOSE: true
  hot_reload: false
",
    )
    .unwrap();
    let dev = task(&t, "dev");
    assert_eq!(
        dev.with,
        vec![
            ("zebra".to_string(), sh("echo z")),
            ("alpha".to_string(), argv(&["tail", "-f", "log"])),
        ]
    );
    assert_eq!(
        dev.env,
        vec![
            ("API_URL".to_string(), "http://localhost:8080".to_string()),
            ("PORT".to_string(), "8080".to_string()),
            ("RATIO".to_string(), "1.5".to_string()),
            ("VERBOSE".to_string(), "true".to_string()),
        ]
    );
    assert_eq!(dev.hot_reload, Some(false));
}

#[test]
fn dev_and_build_have_defaults() {
    let none = Tasks::default();
    let dev = none.dev();
    assert_eq!(dev.run, argv(&["flutter", "run"]));
    assert!(dev.run_is_default);
    assert!(dev.hot_reload);
    assert!(dev.before.is_empty() && dev.with.is_empty() && dev.after.is_empty());
    let build = none.build();
    assert_eq!(build.run, argv(&["flutter", "build"]));
    assert!(build.run_is_default);

    let set = parse("dev:\n  run: fvm flutter run\nbuild:\n  before: echo x\n").unwrap();
    assert_eq!(set.dev().run, sh("fvm flutter run"));
    assert!(!set.dev().run_is_default);
    assert_eq!(set.build().run, argv(&["flutter", "build"]));
    assert_eq!(set.build().before, vec![sh("echo x")]);
}

// --- messages ----------------------------------------------------------------------------------

#[test]
fn c1_tasks_must_be_a_map() {
    let want = "`fespalier.tasks` must be a map of task names to tasks, e.g. `codegen: dart run build_runner build -d`";
    assert_eq!(err("[a, b]"), want);
    assert_eq!(err("just a string"), want);
}

#[test]
fn c2_a_task_name_is_lower_case() {
    for name in ["Dev", "1x", "a b", "_x"] {
        assert_eq!(
            err(&format!("'{name}': echo hi")),
            format!(
                "`fespalier.tasks`: `{name}` is not a task name; use lower-case letters, digits, `_` and `-`, starting with a letter"
            )
        );
    }
    assert!(parse("a-b_c1: echo hi").is_ok());
}

#[test]
fn c3_a_task_is_a_command_or_a_map() {
    let tail = "must be a command (a string, or a list of words) or a map with `run`, `before`, `with`, `after`, `env` and `hot_reload`, got";
    assert_eq!(
        err("codegen: 5"),
        format!("`fespalier.tasks.codegen` {tail} `5`")
    );
    assert_eq!(
        err("codegen: true"),
        format!("`fespalier.tasks.codegen` {tail} `true`")
    );
    assert_eq!(
        err("codegen:"),
        format!("`fespalier.tasks.codegen` {tail} `null`")
    );
}

#[test]
fn c4_an_unknown_key() {
    assert_eq!(
        err("dev:\n  watch: true"),
        "`fespalier.tasks.dev` has an unknown key `watch`; a task takes `run`, `before`, `with`, `after`, `env` and `hot_reload`"
    );
}

#[test]
fn c5_run_is_a_command() {
    let tail = "must be a command: a string the shell runs, or a list of words run without a shell (`[flutter, run]`), got";
    assert_eq!(
        err("dev:\n  run: 3"),
        format!("`fespalier.tasks.dev.run` {tail} `3`")
    );
    assert_eq!(
        err("dev:\n  run: ''"),
        format!("`fespalier.tasks.dev.run` {tail} ``")
    );
    assert_eq!(
        err("dev:\n  run: []"),
        format!("`fespalier.tasks.dev.run` {tail} `[]`")
    );
    assert_eq!(
        err("dev:\n  run: [flutter, 1]"),
        format!("`fespalier.tasks.dev.run` {tail} `[\"flutter\",1]`")
    );
    // The shorthand is a `run` too.
    assert_eq!(
        err("codegen: ''"),
        format!("`fespalier.tasks.codegen.run` {tail} ``")
    );
}

#[test]
fn c6_before_and_after_are_commands() {
    assert_eq!(
        err("dev:\n  before: 5"),
        "`fespalier.tasks.dev.before` must be a command or a list of commands, got `5`"
    );
    assert_eq!(
        err("dev:\n  after: {a: b}"),
        "`fespalier.tasks.dev.after` must be a command or a list of commands, got `{\"a\":\"b\"}`"
    );
    assert_eq!(
        err("dev:\n  before: ''"),
        "`fespalier.tasks.dev.before` must be a command or a list of commands, got ``"
    );
}

#[test]
fn c7_each_step_of_a_list_is_a_command() {
    let tail =
        "must be a command: a string the shell runs, or a list of words run without a shell, got";
    assert_eq!(
        err("dev:\n  before: [echo one, 5]"),
        format!("`fespalier.tasks.dev.before[2]` {tail} `5`")
    );
    assert_eq!(
        err("dev:\n  after: [[]]"),
        format!("`fespalier.tasks.dev.after[1]` {tail} `[]`")
    );
    assert_eq!(
        err("dev:\n  after: [echo one, [echo, 3]]"),
        format!("`fespalier.tasks.dev.after[2]` {tail} `[\"echo\",3]`")
    );
}

#[test]
fn c8_with_is_a_map() {
    assert_eq!(
        err("dev:\n  with: dart run x"),
        "`fespalier.tasks.dev.with` must be a map of names to commands, e.g. `build_runner: dart run build_runner watch -d`, got `dart run x`"
    );
}

#[test]
fn c9_a_with_name() {
    for name in ["has space", "waytoolongaprocessnamehere", "a.b"] {
        assert_eq!(
            err(&format!("dev:\n  with:\n    '{name}': echo hi")),
            format!(
                "`fespalier.tasks.dev.with`: `{name}` is not a name; use letters, digits, `_` and `-`, at most 20"
            )
        );
    }
}

#[test]
fn c10_flutter_and_fsp_are_panes_of_their_own() {
    for name in ["flutter", "fsp"] {
        assert_eq!(
            err(&format!("dev:\n  with:\n    {name}: echo hi")),
            format!(
                "`fespalier.tasks.dev.with`: `{name}` is the name of a pane of fsp dev's own; pick another"
            )
        );
    }
}

#[test]
fn c11_a_with_command() {
    assert_eq!(
        err("dev:\n  with:\n    watcher: 5"),
        "`fespalier.tasks.dev.with.watcher` must be a command: a string the shell runs, or a list of words run without a shell, got `5`"
    );
}

#[test]
fn c12_to_c14_env() {
    assert_eq!(
        err("dev:\n  env: [A, B]"),
        "`fespalier.tasks.dev.env` must be a map of variable names to values, got `[\"A\",\"B\"]`"
    );
    assert_eq!(
        err("dev:\n  env:\n    1BAD: x"),
        "`fespalier.tasks.dev.env`: `1BAD` is not a variable name (letters, digits and `_`, not starting with a digit)"
    );
    assert_eq!(
        err("dev:\n  env:\n    A-B: x"),
        "`fespalier.tasks.dev.env`: `A-B` is not a variable name (letters, digits and `_`, not starting with a digit)"
    );
    assert_eq!(
        err("dev:\n  env:\n    API: [x]"),
        "`fespalier.tasks.dev.env.API` must be a string, a number or a boolean, got `[\"x\"]`"
    );
}

#[test]
fn c15_and_c16_hot_reload() {
    assert_eq!(
        err("dev:\n  hot_reload: maybe"),
        "`fespalier.tasks.dev.hot_reload` must be `true` or `false`, got `maybe`"
    );
    assert_eq!(
        err("build:\n  hot_reload: false"),
        "`fespalier.tasks.build.hot_reload` is only read by `fsp dev`; move it under `tasks: dev:`"
    );
    assert_eq!(
        err("codegen:\n  run: echo x\n  hot_reload: true"),
        "`fespalier.tasks.codegen.hot_reload` is only read by `fsp dev`; move it under `tasks: dev:`"
    );
}

#[test]
fn c17_only_dev_and_build_have_a_default_command() {
    assert_eq!(
        err("codegen:\n  before: echo x"),
        "`fespalier.tasks.codegen` has no `run`; only `dev` and `build` have a default command"
    );
    assert!(parse("dev:\n  before: echo x").is_ok());
    assert!(parse("build:\n  after: echo x").is_ok());
}

// --- a malformed section never fails gen -----------------------------------------------------------

#[test]
fn a_malformed_tasks_section_does_not_stop_gen_check_or_watch() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  tasks:\n    dev: 5\n    Bad Name: [1]\n",
    )
    .unwrap();
    fs::create_dir_all(dir.path().join("lib/app")).unwrap();
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "class HomePage extends StatelessWidget { const HomePage({super.key}); }",
    )
    .unwrap();
    let cfg = Config::load(dir.path()).unwrap();
    assert!(cfg.tasks.is_some());
    let o = crate::gen_with(dir.path(), &cfg, true).unwrap();
    assert_eq!(o.routes, 1);
    // ... and only the commands that read it say so.
    assert!(Tasks::from_config(&cfg).is_err());
    // `tasks` is a known key: it is not reported as an unknown field.
    assert!(Pubspec::parse("name: x\nfespalier:\n  tasks: {}\n").is_ok());
}

// --- quoting and building -----------------------------------------------------------------------

#[test]
fn sh_quoting() {
    assert_eq!(quote_sh("web"), "web");
    assert_eq!(quote_sh("--release"), "--release");
    assert_eq!(quote_sh("a b"), "'a b'");
    assert_eq!(quote_sh(""), "''");
    assert_eq!(quote_sh("it's"), "'it'\\''s'");
    assert_eq!(quote_sh("$HOME"), "'$HOME'");
    assert_eq!(quote_sh("/tmp/my dir/fsp"), "'/tmp/my dir/fsp'");
}

#[test]
fn cmd_quoting() {
    assert_eq!(quote_cmd("web").unwrap(), "web");
    assert_eq!(
        quote_cmd("C:\\tools\\fsp.exe").unwrap(),
        "C:\\tools\\fsp.exe"
    );
    assert_eq!(quote_cmd("a b").unwrap(), "\"a b\"");
    assert_eq!(quote_cmd("say \"hi\"").unwrap(), "\"say \"\"hi\"\"\"");
    assert_eq!(quote_cmd("100%").unwrap(), "\"100%\"");
    let e = quote_cmd("\"%PATH%\"").unwrap_err();
    assert!(e.contains("cmd cannot quote safely"), "{e}");
}

#[test]
fn resolve_windows_finds_flutter_bat() {
    let dir = tempfile::tempdir().unwrap();
    let a = dir.path().join("a");
    let b = dir.path().join("b");
    fs::create_dir_all(&a).unwrap();
    fs::create_dir_all(&b).unwrap();
    // Windows finds these whatever their case; the test spells them as PATHEXT does, so that it
    // holds on a case-sensitive file system too.
    fs::write(b.join("flutter.BAT"), "").unwrap();
    fs::write(b.join("dart.EXE"), "").unwrap();
    fs::write(a.join("dart.CMD"), "").unwrap();
    let path = format!("{};{}", a.display(), b.display());
    let ext = ".COM;.EXE;.BAT;.CMD";
    assert_eq!(
        resolve_windows("flutter", &path, ext),
        Some(b.join("flutter.BAT"))
    );
    // The extension may already be there.
    assert_eq!(
        resolve_windows("flutter.BAT", &path, ext),
        Some(b.join("flutter.BAT"))
    );
    // The first folder with a match wins, whatever the extension.
    assert_eq!(
        resolve_windows("dart", &path, ext),
        Some(a.join("dart.CMD"))
    );
    assert_eq!(resolve_windows("nothing", &path, ext), None);
    assert_eq!(resolve_windows("flutter", "", ext), None);
}

fn built(cmd: &Cmd, extra: &[&str]) -> (String, Vec<String>) {
    let project = Path::new("/p");
    let exe = Path::new("/opt/fsp bin/fsp");
    let env = Env {
        cwd: project,
        vars: vec![("A".into(), "1".into())],
        fsp: exe,
    };
    let extra: Vec<String> = extra.iter().map(|s| (*s).to_string()).collect();
    let p = prepare(cmd, &extra, &env).unwrap().process;
    (
        p.get_program().to_string_lossy().into_owned(),
        p.get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect(),
    )
}

#[cfg(unix)]
#[test]
fn a_string_runs_in_sh_with_the_extra_words_quoted() {
    assert_eq!(
        built(&sh("dart run x"), &["a b", "--c"]),
        (
            "sh".to_string(),
            vec!["-c".to_string(), "dart run x 'a b' --c".to_string()]
        )
    );
}

#[cfg(unix)]
#[test]
fn a_list_is_argv_with_the_extra_words_after() {
    assert_eq!(
        built(&argv(&["flutter", "test"]), &["--name", "a b"]),
        (
            "flutter".to_string(),
            vec!["test".to_string(), "--name".to_string(), "a b".to_string()]
        )
    );
}

#[cfg(unix)]
#[test]
fn a_leading_fsp_is_this_fsp() {
    // A string: the word becomes the quoted path.
    assert_eq!(
        built(&sh("fsp check --json"), &[]).1[1],
        "'/opt/fsp bin/fsp' check --json"
    );
    assert_eq!(built(&sh("fsp"), &[]).1[1], "'/opt/fsp bin/fsp'");
    // Only the whole first word.
    assert_eq!(built(&sh("fspx check"), &[]).1[1], "fspx check");
    assert_eq!(built(&sh("echo fsp"), &[]).1[1], "echo fsp");
    // A list: the program.
    assert_eq!(
        built(&argv(&["fsp", "test", "--check"]), &[]),
        (
            "/opt/fsp bin/fsp".to_string(),
            vec!["test".to_string(), "--check".to_string()]
        )
    );
}

#[test]
fn the_environment_is_the_tasks_plus_fsp() {
    let env = Env {
        cwd: Path::new("/p"),
        vars: vec![("A".into(), "1".into())],
        fsp: Path::new("/x/fsp"),
    };
    let p = prepare(&argv(&["true"]), &[], &env).unwrap().process;
    let vars: Vec<(String, String)> = p
        .get_envs()
        .filter_map(|(k, v)| {
            Some((
                k.to_string_lossy().into_owned(),
                v?.to_string_lossy().into_owned(),
            ))
        })
        .collect();
    assert!(
        vars.contains(&("A".to_string(), "1".to_string())),
        "{vars:?}"
    );
    assert!(
        vars.contains(&("FSP".to_string(), "/x/fsp".to_string())),
        "{vars:?}"
    );
    assert_eq!(p.get_current_dir(), Some(Path::new("/p")));
}

// --- the shown command, the dry run, and the listing --------------------------------------------

#[test]
fn a_command_is_shown_as_written() {
    assert_eq!(sh("dart run x -d").shown(), "dart run x -d");
    assert_eq!(argv(&["flutter", "run"]).shown(), "flutter run");
    assert_eq!(
        argv(&["echo", "a b", "it's"]).shown(),
        "echo 'a b' 'it'\\''s'"
    );
}

fn cfg() -> Config {
    Config::default()
}

#[test]
fn dev_dry_run_text() {
    let t = parse(
        "
dev:
  before: dart run build_runner build -d
  with:
    build_runner: dart run build_runner watch -d
  env:
    API_URL: http://localhost:8080
",
    )
    .unwrap();
    let args = ["-d".to_string(), "chrome".to_string()];
    assert_eq!(
        dev::dry_run(Path::new("/abs/project"), &cfg(), &t.dev(), &args),
        "\
fsp dev in /abs/project
  gen     lib/app.g.dart, kept current while it runs
  before  dart run build_runner build -d
  with    build_runner: dart run build_runner watch -d
  run     flutter run --machine -d chrome
  after   (nothing)
  env     API_URL=http://localhost:8080
  hot reload after a save; hot restart when lib/app.g.dart changes
"
    );
}

#[test]
fn dev_dry_run_with_nothing_set_and_hot_reload_off() {
    let t = parse("dev:\n  hot_reload: false\n").unwrap();
    assert_eq!(
        dev::dry_run(Path::new("/p"), &cfg(), &t.dev(), &[]),
        "\
fsp dev in /p
  gen     lib/app.g.dart, kept current while it runs
  before  (nothing)
  with    (nothing)
  run     flutter run --machine
  after   (nothing)
  env     (nothing)
  hot reload off (r and R still work)
"
    );
}

#[test]
fn run_args_add_machine_once_and_the_device() {
    let none: Vec<String> = vec![];
    assert_eq!(dev::run_args(&none, None), ["--machine"]);
    let given = [
        "--machine".to_string(),
        "--flavor".to_string(),
        "dev".to_string(),
    ];
    assert_eq!(
        dev::run_args(&given, None),
        ["--machine", "--flavor", "dev"]
    );
    let device = crate::dev_state::Device {
        id: "chrome".into(),
        name: "Chrome".into(),
        platform: "web-javascript".into(),
    };
    assert_eq!(
        dev::run_args(&["--flavor".to_string(), "dev".to_string()], Some(&device)),
        ["--machine", "-d", "chrome", "--flavor", "dev"]
    );
}

#[test]
fn the_listing_pads_names_and_shows_the_defaults() {
    let t = parse("codegen: dart run build_runner build -d\n").unwrap();
    assert_eq!(
        t.listing(),
        "\
dev      flutter run   (fsp dev)
build    flutter build (fsp build <target>)
codegen  dart run build_runner build -d
"
    );
    // With nothing configured: the built-ins only.
    assert_eq!(
        Tasks::default().listing(),
        "\
dev    flutter run   (fsp dev)
build  flutter build (fsp build <target>)
"
    );
    // A configured `dev` shows its own `run`, and keeps its place.
    let t = parse("lint: [flutter, analyze]\ndev:\n  run: fvm flutter run\n").unwrap();
    assert_eq!(
        t.listing(),
        "\
dev    fvm flutter run (fsp dev)
build  flutter build   (fsp build <target>)
lint   flutter analyze
"
    );
}
