//! The processes fsp supervises: how they end, what they print, and that a stop reaches what
//! they started. The Unix tests use `sh`; nothing here sleeps to wait for a condition.

use crate::osc8;
use crate::procs::{Status, color_enabled, prefixed};

#[test]
fn a_status_describes_how_the_process_ended() {
    assert_eq!(
        Status {
            code: 3,
            signal: None
        }
        .describe(),
        "exit 3"
    );
    assert_eq!(
        Status {
            code: 137,
            signal: Some(9)
        }
        .describe(),
        "killed by signal 9"
    );
    assert!(
        Status {
            code: 0,
            signal: None
        }
        .success()
    );
    assert!(
        !Status {
            code: 143,
            signal: Some(15)
        }
        .success()
    );
}

#[test]
fn a_prefix_is_the_name_in_brackets_coloured_by_pane() {
    assert_eq!(prefixed("flutter", 0, "hi", false), "[flutter] hi");
    assert_eq!(prefixed("fsp", 1, "hi", true), "\x1b[35m[fsp]\x1b[0m hi");
    // The colours repeat after five panes.
    assert_eq!(prefixed("x", 5, "t", true), prefixed("x", 0, "t", true));
}

#[test]
fn no_color_turns_the_colours_off() {
    // Stderr is not a terminal under `cargo test`, which alone turns them off; this only pins
    // that asking never panics.
    let _ = color_enabled();
}

fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
    let owned: Vec<(String, String)> = pairs
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect();
    move |k| owned.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone())
}

#[test]
fn hyperlinks_follow_the_terminal() {
    assert!(!osc8::enabled(env(&[])));
    assert!(!osc8::enabled(env(&[("TERM", "xterm-256color")])));
    for program in [
        "iTerm.app",
        "WezTerm",
        "vscode",
        "ghostty",
        "Hyper",
        "Tabby",
    ] {
        assert!(
            osc8::enabled(env(&[("TERM_PROGRAM", program)])),
            "{program}"
        );
    }
    assert!(!osc8::enabled(env(&[("TERM_PROGRAM", "Apple_Terminal")])));
    assert!(osc8::enabled(env(&[("WT_SESSION", "abc")])));
    assert!(osc8::enabled(env(&[("KITTY_WINDOW_ID", "1")])));
    assert!(osc8::enabled(env(&[("VTE_VERSION", "6800")])));
    assert!(!osc8::enabled(env(&[("VTE_VERSION", "4000")])));
    for term in ["xterm-kitty", "foot", "alacritty"] {
        assert!(osc8::enabled(env(&[("TERM", term)])), "{term}");
    }
}

#[test]
fn force_hyperlink_wins_either_way() {
    assert!(osc8::enabled(env(&[("FORCE_HYPERLINK", "1")])));
    assert!(!osc8::enabled(env(&[
        ("FORCE_HYPERLINK", "0"),
        ("TERM_PROGRAM", "vscode")
    ])));
}

#[test]
fn a_link_is_an_osc_8_sequence_around_the_text() {
    assert_eq!(
        osc8::link("file:///p/x.dart", "x.dart:6:18"),
        "\x1b]8;;file:///p/x.dart\x1b\\x.dart:6:18\x1b]8;;\x1b\\"
    );
}

#[test]
fn a_file_url_is_percent_encoded() {
    assert_eq!(
        osc8::file_url(std::path::Path::new("/p/lib/app/products/$id/page.dart")),
        "file:///p/lib/app/products/%24id/page.dart"
    );
    assert_eq!(
        osc8::file_url(std::path::Path::new("/my proj/a.dart")),
        "file:///my%20proj/a.dart"
    );
    assert_eq!(
        osc8::file_url(std::path::Path::new("C:\\proj\\a.dart")),
        "file:///C:/proj/a.dart"
    );
}

#[test]
fn locations_in_lines_become_links() {
    let lines = vec![
        "  ┌─ lib/app/page.dart:6:18".to_string(),
        "no location here".to_string(),
    ];
    let places = [(
        "lib/app/page.dart:6:18".to_string(),
        "file:///p/lib/app/page.dart".to_string(),
    )];
    let got = osc8::link_locations(lines, &places);
    assert_eq!(
        got[0],
        "  ┌─ \x1b]8;;file:///p/lib/app/page.dart\x1b\\lib/app/page.dart:6:18\x1b]8;;\x1b\\"
    );
    assert_eq!(got[1], "no location here");
}

#[cfg(unix)]
mod unix {
    use std::process::Command;
    use std::sync::Arc;
    use std::sync::mpsc;
    use std::time::Duration;

    use crate::procs::{Out, Status, spawn};

    fn run(script: &str) -> (Vec<(String, bool)>, Status) {
        let (tx, rx) = mpsc::channel();
        let tx = std::sync::Mutex::new(tx);
        let mut c = Command::new("sh");
        c.arg("-c").arg(script);
        let sink: Arc<dyn Fn(Out) + Send + Sync> = Arc::new(move |o| {
            let _ = tx.lock().unwrap().send(o);
        });
        let s = spawn(c, false, sink).unwrap();
        let mut lines = vec![];
        loop {
            match rx.recv_timeout(Duration::from_secs(20)).unwrap() {
                Out::Line { text, err } => lines.push((text, err)),
                Out::Exited(status) => {
                    assert_eq!(s.exited(), Some(status));
                    return (lines, status);
                }
            }
        }
    }

    #[test]
    fn lines_of_both_pipes_arrive_before_the_exit() {
        let (lines, status) = run("echo out; echo err >&2; printf 'no newline'; exit 3");
        assert_eq!(status.code, 3);
        assert!(lines.contains(&("out".to_string(), false)), "{lines:?}");
        assert!(lines.contains(&("err".to_string(), true)), "{lines:?}");
        assert!(
            lines.contains(&("no newline".to_string(), false)),
            "{lines:?}"
        );
    }

    #[test]
    fn a_crlf_is_not_part_of_the_line() {
        let (lines, _) = run("printf 'a\\r\\nb\\n'");
        assert_eq!(lines, [("a".to_string(), false), ("b".to_string(), false)]);
    }

    #[test]
    fn a_signal_is_a_status_of_128_plus_it() {
        let (_, status) = run("kill -TERM $$");
        assert_eq!(status.signal, Some(15));
        assert_eq!(status.code, 143);
    }

    #[test]
    fn terminating_a_group_reaches_what_it_started() {
        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("child.pid");
        let (tx, rx) = mpsc::channel();
        let tx = std::sync::Mutex::new(tx);
        let mut c = Command::new("sh");
        // A grandchild that would outlive the shell if only the shell were stopped.
        c.arg("-c").arg(format!(
            "sleep 300 & echo $! > '{}'; echo ready; wait",
            pidfile.display()
        ));
        let sink: Arc<dyn Fn(Out) + Send + Sync> = Arc::new(move |o| {
            let _ = tx.lock().unwrap().send(o);
        });
        let s = spawn(c, false, sink).unwrap();
        // `ready` comes after the pid file is written.
        loop {
            if let Out::Line { text, .. } = rx.recv_timeout(Duration::from_secs(20)).unwrap()
                && text == "ready"
            {
                break;
            }
        }
        let grandchild: i32 = std::fs::read_to_string(&pidfile)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let status = s.terminate(Duration::from_secs(10)).unwrap();
        assert_eq!(status.signal, Some(15));
        // The grandchild is gone too (`kill -0` fails for a process that does not exist).
        let end = std::time::Instant::now() + Duration::from_secs(20);
        loop {
            let alive = Command::new("kill")
                .args(["-0", &grandchild.to_string()])
                .stderr(std::process::Stdio::null())
                .status()
                .unwrap()
                .success();
            if !alive {
                break;
            }
            assert!(
                std::time::Instant::now() < end,
                "the grandchild is still running"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn stdin_reaches_a_process_that_asked_for_it() {
        let (tx, rx) = mpsc::channel();
        let tx = std::sync::Mutex::new(tx);
        let mut c = Command::new("sh");
        c.arg("-c").arg("read line; echo got:$line");
        let sink: Arc<dyn Fn(Out) + Send + Sync> = Arc::new(move |o| {
            let _ = tx.lock().unwrap().send(o);
        });
        let s = spawn(c, true, sink).unwrap();
        s.write_line("hello").unwrap();
        match rx.recv_timeout(Duration::from_secs(20)).unwrap() {
            Out::Line { text, .. } => assert_eq!(text, "got:hello"),
            Out::Exited(_) => panic!("exited without a line"),
        }
    }
}
