//! `watch.rs`: which folders outside `lib/` are watched, and what is said when one cannot be
//! (since 0.22.0).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use notify::{PathsMut, RecursiveMode};

use crate::watch::Beside;

/// A watcher that records what it is asked, and refuses the folders it is told to.
#[derive(Default)]
struct Fake {
    log: Vec<String>,
    refuse: BTreeSet<PathBuf>,
}

impl PathsMut for Fake {
    fn add(&mut self, path: &Path, mode: RecursiveMode) -> notify::Result<()> {
        assert_eq!(mode, RecursiveMode::NonRecursive);
        self.log.push(format!("add {}", path.display()));
        if self.refuse.contains(path) {
            return Err(notify::Error::generic("limit reached"));
        }
        Ok(())
    }

    fn remove(&mut self, path: &Path) -> notify::Result<()> {
        self.log.push(format!("remove {}", path.display()));
        Ok(())
    }

    fn commit(self: Box<Self>) -> notify::Result<()> {
        Ok(())
    }
}

fn there(dirs: &[&str]) -> BTreeSet<PathBuf> {
    dirs.iter().map(PathBuf::from).collect()
}

/// One pass over `beside` for the folders that are `there`, the way `Pass::watch_beside` does it.
fn pass(beside: &mut Beside, fake: &mut Fake, dirs: &[&str], again: bool) -> Vec<String> {
    let dirs = there(dirs);
    beside.forget(&dirs);
    let plan = beside.plan(&dirs, again);
    fake.log.clear();
    beside.apply(&plan, fake)
}

#[test]
fn a_folder_is_watched_once_it_is_there_and_not_again_unless_asked() {
    let (mut beside, mut fake) = (Beside::default(), Fake::default());
    assert!(pass(&mut beside, &mut fake, &["a", "b"], false).is_empty());
    assert_eq!(fake.log, ["add a", "add b"]);
    // Nothing changed: nothing is asked.
    pass(&mut beside, &mut fake, &["a", "b"], false);
    assert!(fake.log.is_empty(), "{:?}", fake.log);
    // A new folder is the only one asked for.
    pass(&mut beside, &mut fake, &["a", "b", "c"], false);
    assert_eq!(fake.log, ["add c"]);
}

#[test]
fn a_folder_that_is_gone_is_dropped_and_watched_again_when_it_is_back() {
    let (mut beside, mut fake) = (Beside::default(), Fake::default());
    pass(&mut beside, &mut fake, &["a", "b"], false);
    // `b` was deleted: its watch is let go, and `a` is left alone.
    pass(&mut beside, &mut fake, &["a"], false);
    assert_eq!(fake.log, ["remove b"]);
    // Made again, it is watched again (a dropped watch is not in `beside` any more).
    pass(&mut beside, &mut fake, &["a", "b"], false);
    assert_eq!(fake.log, ["add b"]);
}

#[test]
fn asking_again_adds_to_the_watch_of_a_folder_deleted_and_made_between_two_passes() {
    let (mut beside, mut fake) = (Beside::default(), Fake::default());
    pass(&mut beside, &mut fake, &["a"], true);
    // The folder is there at both passes, though it was another one in between: inotify dropped the
    // watch of the first, so every pass asks for every folder that is there.
    pass(&mut beside, &mut fake, &["a"], true);
    assert_eq!(fake.log, ["add a"]);
    // And a folder that is not wanted any more is let go.
    pass(&mut beside, &mut fake, &[], true);
    assert_eq!(fake.log, ["remove a"]);
}

#[test]
fn a_folder_the_watcher_refuses_is_said_once_and_tried_again() {
    let (mut beside, mut fake) = (Beside::default(), Fake::default());
    fake.refuse = there(&["a"]);
    let told = pass(&mut beside, &mut fake, &["a", "b"], false);
    assert_eq!(told.len(), 1, "{told:?}");
    assert!(
        told[0].starts_with("watch error: cannot watch a: ") && told[0].contains("limit reached"),
        "{told:?}"
    );
    // Asked again after the next pass, and not said again; `b` is not asked for twice.
    assert!(pass(&mut beside, &mut fake, &["a", "b"], false).is_empty());
    assert_eq!(fake.log, ["add a"]);
    // Once it is gone the refusal is forgotten: a later one is said again.
    pass(&mut beside, &mut fake, &["b"], false);
    assert_eq!(pass(&mut beside, &mut fake, &["a", "b"], false).len(), 1);
    // And once the watcher takes it, a new refusal is said too.
    fake.refuse.clear();
    assert!(pass(&mut beside, &mut fake, &["a", "b"], false).is_empty());
    fake.refuse = there(&["a"]);
    assert_eq!(pass(&mut beside, &mut fake, &["a", "b"], true).len(), 1);
}
