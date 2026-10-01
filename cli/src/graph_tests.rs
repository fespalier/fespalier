//! `fsp routes --graph`: golden graphs of the examples, validity of both formats, and the
//! shapes the tree can take (siblings, shells, tabs, redirects, escaped labels).
//!
//! The goldens are in `tests/golden/`; `FSP_UPDATE_GOLDEN=1 cargo test graph_tests::` rewrites them.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::config::Config;
use crate::graph::{self, Format};

fn examples(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../examples")
        .join(name)
}

fn render_project(project: &Path, format: Format) -> String {
    let cfg = Config::load(project).unwrap();
    let (_, diags, app) = crate::analyze(&project.join(&cfg.app_dir), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    graph::render(&app, format)
}

fn render_files(files: &[(&str, &str)], format: Format) -> String {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    render_project(dir.path(), format)
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn golden(name: &str, ext: &str, format: Format) {
    let got = render_project(&examples(name), format);
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("graph-{name}.{ext}"));
    if std::env::var_os("FSP_UPDATE_GOLDEN").is_some() {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, &got).unwrap();
    }
    let want = fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        got,
        want,
        "{} is stale; run `FSP_UPDATE_GOLDEN=1 cargo test graph_tests::` in cli/",
        path.display()
    );
}

#[test]
fn goldens_of_the_examples() {
    for name in ["minimal", "shop", "features", "tabs"] {
        golden(name, "mmd", Format::Mermaid);
        golden(name, "dot", Format::Dot);
    }
}

/// What Mermaid needs to parse the text: a `flowchart` header, balanced `subgraph`/`end`, ids
/// declared once, edges between declared ids, and quoted labels with no markup of their own.
fn check_mermaid(text: &str) {
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some("flowchart TD"));
    assert!(text.ends_with('\n') && !text.ends_with("\n\n"));
    let (mut depth, mut nodes, mut edges) = (0usize, BTreeSet::new(), vec![]);
    let mut boxes = BTreeSet::new();
    for line in lines {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("subgraph ") {
            depth += 1;
            let (id, title) = rest.split_once('[').unwrap();
            assert!(boxes.insert(id.to_string()), "box {id} twice");
            assert!(id != "end" && id.chars().all(|c| c.is_ascii_alphanumeric()));
            quoted(title.strip_suffix(']').unwrap());
        } else if t == "end" {
            depth = depth.checked_sub(1).unwrap();
        } else if let Some((from, to)) = t.split_once(" --> ") {
            edges.push((from.to_string(), to.to_string()));
        } else if t.starts_with("classDef ") || t.starts_with("class ") {
        } else {
            let (id, label) = t.split_once('[').unwrap();
            assert!(nodes.insert(id.to_string()), "node {id} twice");
            quoted(label.strip_suffix(']').unwrap());
        }
    }
    assert_eq!(depth, 0, "unbalanced subgraphs");
    for (a, b) in &edges {
        assert!(nodes.contains(a) && nodes.contains(b), "{a} --> {b}");
    }
    let mut seen = BTreeSet::new();
    assert!(
        edges.iter().all(|e| seen.insert(e.clone())),
        "duplicate edge"
    );
}

/// A label is `"..."` with only `#...;` entities, ASCII, and `<br/>` between lines.
fn quoted(s: &str) {
    let inner = s.strip_prefix('"').unwrap().strip_suffix('"').unwrap();
    assert!(!inner.contains('"'), "{s}");
    assert!(inner.is_ascii(), "{s}");
    assert!(!inner.contains('$') && !inner.contains('&'), "{s}");
    let no_br = inner.replace("<br/>", "");
    assert!(!no_br.contains(['<', '>']), "{s}");
}

/// What Graphviz needs: balanced braces and quotes, declared nodes in edges.
fn check_dot(text: &str) {
    assert!(text.starts_with("digraph routes {\n") && text.ends_with("}\n"));
    assert!(text.is_ascii());
    let (mut depth, mut nodes, mut edges) = (0i32, BTreeSet::new(), vec![]);
    for line in text.lines() {
        let t = line.trim();
        let quotes = t.replace("\\\"", "").matches('"').count();
        assert_eq!(quotes % 2, 0, "{t}");
        if t.ends_with('{') {
            depth += 1;
        } else if t == "}" {
            depth -= 1;
        } else if let Some((from, to)) = t.strip_suffix(';').and_then(|t| t.split_once(" -> ")) {
            edges.push((from.to_string(), to.to_string()));
        } else if t.starts_with('n') && t.contains(" [label=") {
            assert!(t.ends_with("];"), "{t}");
            nodes.insert(t.split_once(' ').unwrap().0.to_string());
        }
    }
    assert_eq!(depth, 0);
    for (a, b) in &edges {
        assert!(nodes.contains(a) && nodes.contains(b), "{a} -> {b}");
    }
}

#[test]
fn every_example_graph_is_valid_in_both_formats() {
    for name in ["minimal", "shop", "features", "tabs"] {
        check_mermaid(&render_project(&examples(name), Format::Mermaid));
        check_dot(&render_project(&examples(name), Format::Dot));
    }
}

#[test]
fn rendering_twice_gives_the_same_bytes() {
    for format in [Format::Mermaid, Format::Dot] {
        let a = render_project(&examples("features"), format);
        assert_eq!(a, render_project(&examples("features"), format));
    }
}

#[test]
fn a_page_is_the_parent_of_the_folders_below_and_nest_false_makes_a_sibling() {
    let files = [
        ("page.dart", page("Home").as_str()),
        ("orders/$id/page.dart", "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }"),
        ("orders/$id/refund/page.dart", "class RefundPage extends StatelessWidget { const RefundPage({super.key}); }"),
        ("orders/$id/refund/confirm/page.dart", "class ConfirmPage extends StatelessWidget { const ConfirmPage({super.key}); }"),
        ("orders/$id/refund/confirm/route.dart", "const nest = false;"),
    ]
    .map(|(a, b)| (a, b.to_string()));
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let text = render_files(&files, Format::Mermaid);
    check_mermaid(&text);
    // n0 `/`, n1 `/orders/:id`, n2 `/orders/:id/refund`, n3 `/orders/:id/refund/confirm`
    assert!(text.contains("n0 --> n1\n"), "{text}");
    assert!(text.contains("n1 --> n2\n"), "{text}");
    assert!(
        text.contains("n1 --> n3\n"),
        "a sibling hangs from the page above: {text}"
    );
    assert!(!text.contains("n2 --> n3"), "{text}");
    assert!(text.contains("(sibling)"), "{text}");
}

#[test]
fn layouts_guards_data_and_redirects_are_marked() {
    let files = [
        ("page.dart", page("Home")),
        ("layout.dart", "class AppLayout extends StatelessWidget { const AppLayout({super.key, required this.child}); final Widget child; }".into()),
        ("account/page.dart", page("Account")),
        ("account/guard.dart", "GuardResult guard(ProviderContainer c) => null;".into()),
        ("old/redirect.dart", "String redirect() => '/account';".into()),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let text = render_files(&files, Format::Mermaid);
    check_mermaid(&text);
    assert!(
        text.contains("subgraph b0[\"layout layout.dart\"]"),
        "{text}"
    );
    assert!(text.contains("AccountRoute<br/>(guard)"), "{text}");
    assert!(text.contains("(redirect)"), "{text}");
    assert!(
        text.contains("classDef redirect stroke-dasharray: 5 5"),
        "{text}"
    );
    let dot = render_files(&files, Format::Dot);
    check_dot(&dot);
    assert!(dot.contains("style=dashed];"), "{dot}");
}

#[test]
fn tab_branches_are_boxes_in_the_tab_layout() {
    let text = render_project(&examples("tabs"), Format::Mermaid);
    assert!(text.contains("tabs (tabs)/layout.dart"), "{text}");
    assert!(text.contains("tab 0: (home)"), "{text}");
    assert!(text.contains("tab 1: search"), "{text}");
    // A tab layout inside a tab.
    assert!(text.contains("tabs (tabs)/library/layout.dart"), "{text}");
}

#[test]
fn labels_are_escaped_for_each_format() {
    assert_eq!(
        graph::mermaid_text("a\"b<c>&d#e$f:g/h über"),
        "a#quot;b#lt;c#gt;#amp;d#35;e#36;f:g/h #252;ber"
    );
    assert_eq!(graph::mermaid_text("製"), "#35069;");
    assert_eq!(
        graph::dot_text("a\"b\\c&d$e über"),
        "a\\\"b\\\\c&amp;d$e &#252;ber"
    );
}

#[test]
fn non_ascii_spellings_and_dollars_stay_valid() {
    let text = render_project(&examples("features"), Format::Mermaid);
    assert!(text.contains("de /f#252;hrer"), "{text}");
    assert!(text.contains("layout shops/#36;shop/layout.dart"), "{text}");
    let dot = render_project(&examples("features"), Format::Dot);
    assert!(dot.contains("de /f&#252;hrer"), "{dot}");
}

#[test]
fn an_app_with_no_route_is_an_empty_graph() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    fs::create_dir_all(dir.path().join("lib/app")).unwrap();
    let cfg = Config::load(dir.path()).unwrap();
    let (_, _, app) = crate::analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    assert_eq!(graph::render(&app, Format::Mermaid), "flowchart TD\n");
    assert_eq!(
        graph::render(&app, Format::Dot),
        "digraph routes {\n  rankdir=TB;\n  node [shape=box];\n}\n"
    );
}
