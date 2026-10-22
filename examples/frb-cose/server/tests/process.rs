//! The binary itself: `--exit-when-stdin-closes` ends the server when the program that started it goes away.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[test]
fn the_server_exits_when_its_stdin_closes_if_asked_to() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_frb-cose-demo-server"))
        .args(["--listen", "127.0.0.1:0", "--exit-when-stdin-closes"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("the server starts");
    let stdin = child.stdin.take().expect("a piped stdin");
    let mut hello = String::new();
    BufReader::new(child.stdout.take().expect("a piped stdout"))
        .read_line(&mut hello)
        .expect("the hello line");
    assert!(hello.contains("\"addr\""), "{hello}");
    assert!(
        child.try_wait().expect("status").is_none(),
        "it serves while its stdin is open"
    );

    // What the parent's death does to the pipe.
    drop(stdin);

    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = child.try_wait().expect("status") {
            break status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            panic!("the server did not exit within 10 s of its stdin closing");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success(), "{status}");
}
