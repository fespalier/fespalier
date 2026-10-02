//! `fsp routes --graph json`, the tree the DevTools extension reads: goldens of the examples, what
//! the tree has to agree with (`fsp routes --json`, the generated file), and the shapes it can take.
//!
//! The goldens are in `tests/golden/`; `FSP_UPDATE_GOLDEN=1 cargo test devtools_tests::` rewrites
//! them. The extension's own tests parse them (`packages/fespalier_devtools/test/tree_test.dart`).

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::config::Config;
use crate::graph::{self, Format};
use crate::{devtools, routes};

fn examples(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../examples")
        .join(name)
}

/// The app of `project`, resolved, with the code generated for it.
fn analyzed(project: &Path) -> (Config, crate::resolve::App, String) {
    let cfg = Config::load(project).unwrap();
    let (code, diags, app) = crate::analyze(&project.join(&cfg.app_dir), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    (cfg, app, code)
}

fn files_project(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn golden(name: &str) {
    let (cfg, app, _) = analyzed(&examples(name));
    let got = graph::render(&app, &cfg, Format::Json);
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{name}.devtools.json"));
    if std::env::var_os("FSP_UPDATE_GOLDEN").is_some() {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, &got).unwrap();
    }
    let want = fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        got,
        want,
        "{} is stale; run `FSP_UPDATE_GOLDEN=1 cargo test devtools_tests::` in cli/",
        path.display()
    );
}

#[test]
fn goldens_of_the_examples() {
    for name in ["minimal", "shop", "features", "tabs"] {
        golden(name);
    }
}

#[test]
fn rendering_twice_gives_the_same_bytes() {
    let (cfg, app, _) = analyzed(&examples("features"));
    let a = graph::render(&app, &cfg, Format::Json);
    assert_eq!(a, graph::render(&app, &cfg, Format::Json));
    assert!(a.ends_with("}\n") && !a.ends_with("\n\n"));
    let (cfg, app, _) = analyzed(&examples("features"));
    assert_eq!(a, graph::render(&app, &cfg, Format::Json));
}

#[test]
fn the_tree_says_its_protocol_package_and_app_folder() {
    let (cfg, app, _) = analyzed(&examples("shop"));
    let tree = devtools::tree(&app, &cfg);
    assert_eq!(tree["protocol"], 1);
    assert_eq!(tree["package"], "shop");
    assert_eq!(tree["appDir"], "lib/app");
    // A project with no pubspec name has no package to open files by.
    let dir = files_project(&[("page.dart", &page("Home"))]);
    fs::write(dir.path().join("pubspec.yaml"), "dependencies: {}\n").unwrap();
    let (cfg, app, _) = analyzed(dir.path());
    assert_eq!(devtools::tree(&app, &cfg)["package"], Value::Null);
}

/// The route nodes of the tree, in order, wherever they sit.
fn route_nodes<'a>(items: &'a [Value], out: &mut Vec<&'a Value>) {
    for item in items {
        match item["type"].as_str().unwrap() {
            "route" => {
                out.push(item);
                route_nodes(item["children"].as_array().unwrap(), out);
            }
            "shell" => route_nodes(item["items"].as_array().unwrap(), out),
            "tabs" => {
                for b in item["branches"].as_array().unwrap() {
                    route_nodes(b["items"].as_array().unwrap(), out);
                }
            }
            other => panic!("unknown item type {other}"),
        }
    }
}

#[test]
fn every_route_node_is_a_row_of_routes_json_and_every_row_is_a_node() {
    for name in ["minimal", "shop", "features", "tabs"] {
        let (cfg, app, _) = analyzed(&examples(name));
        let tree = devtools::tree(&app, &cfg);
        let mut nodes = vec![];
        route_nodes(tree["items"].as_array().unwrap(), &mut nodes);
        let rows: Vec<Value> = routes::json_lines(&app, &cfg.app_dir)
            .iter()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        for node in &nodes {
            let row = rows
                .iter()
                .find(|r| {
                    r["route"] == node["route"]
                        && r["file"]
                            == format!("{}/{}", cfg.app_dir, node["file"].as_str().unwrap())
                })
                .unwrap_or_else(|| panic!("{name}: no row for {}", node["route"]));
            assert_eq!(row["params"], node["params"], "{name}: {}", node["route"]);
            assert_eq!(row["folder"], node["folder"], "{name}: {}", node["route"]);
            assert_eq!(
                row["paths"],
                node.get("spellings").cloned().unwrap_or(Value::Null)
            );
            // The node's pattern is the row's, or the row's without its optional catch-all.
            let (pattern, row_pattern) = (
                node["pattern"].as_str().unwrap(),
                row["pattern"].as_str().unwrap(),
            );
            assert!(
                row_pattern == pattern
                    || row_pattern.starts_with(&format!("{pattern}/*"))
                    || pattern == "/",
                "{name}: {pattern} vs {row_pattern}"
            );
            let tags: BTreeSet<&str> = row["tags"]
                .as_array()
                .unwrap()
                .iter()
                .map(|t| t.as_str().unwrap())
                .collect();
            for m in node["markers"].as_array().unwrap() {
                // A marker is a tag of the route, which `routes` lists, except where it is the
                // graph's own (`root`, `sibling` are tags too; a guard on a folder above is not).
                let m = m.as_str().unwrap();
                assert!(
                    tags.contains(m) || ["guard", "root"].contains(&m),
                    "{name}: marker {m} of {}",
                    node["route"]
                );
            }
        }
        for row in &rows {
            assert!(
                nodes.iter().any(|n| n["route"] == row["route"]),
                "{name}: no node for {}",
                row["route"]
            );
        }
    }
}

#[test]
fn the_markers_are_the_graphs() {
    let (cfg, app, _) = analyzed(&examples("features"));
    let tree = devtools::tree(&app, &cfg);
    let mermaid = graph::render(&app, &cfg, Format::Mermaid);
    let mut nodes = vec![];
    route_nodes(tree["items"].as_array().unwrap(), &mut nodes);
    let marked = nodes
        .iter()
        .filter(|n| !n["markers"].as_array().unwrap().is_empty())
        .count();
    // Each marked route's label has its marker line: `(data, guard)`.
    assert_eq!(
        marked,
        mermaid
            .lines()
            .filter(|l| l.contains("<br/>(") && l.trim_start().starts_with('n'))
            .count()
    );
    for n in nodes {
        let marks: Vec<&str> = n["markers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m.as_str().unwrap())
            .collect();
        if !marks.is_empty() {
            assert!(
                mermaid.contains(&format!("({})", marks.join(", "))),
                "{marks:?}"
            );
        }
    }
}

/// The sites of the tree, by kind.
fn sites(tree: &Value) -> Vec<(&String, &Value)> {
    tree["sites"].as_object().unwrap().iter().collect()
}

#[test]
fn the_sites_are_the_ones_the_generated_code_names() {
    for name in ["minimal", "shop", "features", "tabs"] {
        let (cfg, app, code) = analyzed(&examples(name));
        let tree = devtools::tree(&app, &cfg);
        let ids: BTreeSet<&str> = sites(&tree).iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(ids.len(), tree["sites"].as_object().unwrap().len());
        // `refGuard(context, 'g5@6', …)`: the guards the runtime keeps a subscription under.
        for guard in code.split("refGuard(context, '").skip(1) {
            let site = guard.split('\'').next().unwrap();
            assert!(ids.contains(site), "{name}: guard site {site}");
            assert_eq!(tree["sites"][site]["kind"], "guard");
        }
        // `final _data37 = …`: a provider fespalier wraps.
        for def in code.split("\nfinal _data").skip(1) {
            let n: String = def.chars().take_while(char::is_ascii_digit).collect();
            let site = format!("d{n}");
            assert!(ids.contains(site.as_str()), "{name}: {site}");
            assert!(
                def.starts_with(&format!("{n} = ")) || def.starts_with(&format!("{n} =\n")),
                "{name}: {def:.40}"
            );
        }
        // `final _action37_0 = …`.
        for def in code.split("\nfinal _action").skip(1) {
            let n: String = def
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '_')
                .collect();
            assert!(ids.contains(format!("a{n}").as_str()), "{name}: a{n}");
        }
        // And the other way: a site of a data.dart that fespalier wraps is traced.
        for (id, site) in sites(&tree) {
            if site["kind"] == "data" && site["traced"] == true {
                assert!(
                    code.contains(&format!("final _data{} = ", &id[1..])),
                    "{name}: {id}"
                );
            }
            if site["kind"] == "action" {
                assert!(
                    code.contains(&format!("final _action{} = ", &id[1..])),
                    "{name}: {id}"
                );
            }
        }
    }
}

#[test]
fn guards_redirects_data_and_actions_are_sites_with_their_files() {
    let dir = files_project(&[
        ("page.dart", &page("Home")),
        (
            "layout.dart",
            "class AppLayout extends StatelessWidget { const AppLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("account/page.dart", &page("Account")),
        ("account/guard.dart", "GuardResult guard(Ref ref) => null;"),
        ("old/redirect.dart", "String redirect() => '/account';"),
        (
            "orders/$id/page.dart",
            "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id, required this.data}); final int id; final String data; }",
        ),
        (
            "orders/$id/data.dart",
            "Future<String> data(Ref ref, {required int id}) async => '';",
        ),
        (
            "orders/$id/action.dart",
            "Future<void> action(Ref ref, {required int id, required String input}) async {}",
        ),
    ]);
    let (cfg, app, code) = analyzed(dir.path());
    let tree = devtools::tree(&app, &cfg);
    let by_kind = |kind: &str| -> Vec<(&String, &Value)> {
        sites(&tree)
            .into_iter()
            .filter(|(_, s)| s["kind"] == kind)
            .collect()
    };
    let guards = by_kind("guard");
    assert_eq!(guards.len(), 1);
    assert_eq!(guards[0].1["file"], "account/guard.dart");
    assert_eq!(guards[0].1["route"], "AccountRoute");
    assert_eq!(guards[0].1["pattern"], "/account");
    assert!(code.contains(&format!("'{}'", guards[0].0)), "{code}");
    let redirects = by_kind("redirect");
    assert_eq!(redirects.len(), 1);
    assert_eq!(redirects[0].1["file"], "old/redirect.dart");
    assert_eq!(redirects[0].1["pattern"], "/old");
    let data = by_kind("data");
    assert_eq!(data.len(), 1);
    assert_eq!(data[0].1["file"], "orders/$id/data.dart");
    assert_eq!(data[0].1["route"], "OrderRoute");
    assert_eq!(data[0].1["section"], Value::Null);
    assert_eq!(data[0].1["traced"], true);
    let actions = by_kind("action");
    assert_eq!(actions.len(), 1);
    assert_eq!(actions[0].1["file"], "orders/$id/action.dart");
    assert_eq!(actions[0].1["name"], "action");
    assert_eq!(actions[0].1["route"], "OrderRoute");
}

#[test]
fn a_data_dart_that_selects_or_returns_a_provider_is_not_traced() {
    let dir = files_project(&[
        ("page.dart", &page("Home")),
        (
            "mine/page.dart",
            "class MinePage extends StatelessWidget { const MinePage({super.key, required this.data}); final String data; }",
        ),
        (
            "mine/data.dart",
            "final data = FutureProvider<String>((ref) async => '');",
        ),
    ]);
    let (cfg, app, _) = analyzed(dir.path());
    let tree = devtools::tree(&app, &cfg);
    let data: Vec<_> = sites(&tree)
        .into_iter()
        .filter(|(_, s)| s["kind"] == "data")
        .collect();
    assert_eq!(data.len(), 1);
    assert_eq!(data[0].1["traced"], false);
}

#[test]
fn a_guard_on_a_folder_with_no_page_is_a_site_of_each_route_below_it() {
    let dir = files_project(&[
        ("page.dart", &page("Home")),
        (
            "(account)/guard.dart",
            "GuardResult guard(Ref ref) => null;",
        ),
        ("(account)/orders/page.dart", &page("Orders")),
        ("(account)/profile/page.dart", &page("Profile")),
    ]);
    let (cfg, app, code) = analyzed(dir.path());
    let tree = devtools::tree(&app, &cfg);
    let guards: Vec<_> = sites(&tree)
        .into_iter()
        .filter(|(_, s)| s["kind"] == "guard")
        .collect();
    let routes: BTreeSet<&str> = guards
        .iter()
        .map(|(_, s)| s["route"].as_str().unwrap())
        .collect();
    assert_eq!(routes, BTreeSet::from(["OrdersRoute", "ProfileRoute"]));
    assert!(
        guards
            .iter()
            .all(|(_, s)| s["file"] == "(account)/guard.dart")
    );
    for (id, _) in guards {
        assert!(code.contains(&format!("'{id}'")), "{id}: {code}");
    }
    // The route nodes carry the marker, the shell of a layout would too.
    let mut nodes = vec![];
    route_nodes(tree["items"].as_array().unwrap(), &mut nodes);
    let orders = nodes.iter().find(|n| n["route"] == "OrdersRoute").unwrap();
    assert_eq!(orders["markers"], serde_json::json!(["guard"]));
}

#[test]
fn layouts_tabs_and_redirects_are_items_of_their_own() {
    let (cfg, app, _) = analyzed(&examples("tabs"));
    let tree = devtools::tree(&app, &cfg);
    let items = tree["items"].as_array().unwrap();
    let tabs = items
        .iter()
        .find(|i| i["type"] == "tabs")
        .unwrap_or_else(|| panic!("no tabs: {tree}"));
    assert_eq!(tabs["file"], "(tabs)/layout.dart");
    assert_eq!(tabs["folder"], "(tabs)");
    let branches = tabs["branches"].as_array().unwrap();
    assert_eq!(branches[0]["index"], 0);
    assert_eq!(branches[0]["name"], "(home)");
    assert_eq!(branches[1]["name"], "search");
    let (cfg, app, _) = analyzed(&examples("features"));
    let tree = devtools::tree(&app, &cfg);
    let mut nodes = vec![];
    route_nodes(tree["items"].as_array().unwrap(), &mut nodes);
    let redirect = nodes
        .iter()
        .find(|n| n["redirect"] == true)
        .expect("a redirect route");
    assert!(
        redirect["file"]
            .as_str()
            .unwrap()
            .ends_with("redirect.dart")
    );
    assert!(
        nodes.iter().any(|n| n["spellings"].is_object()),
        "a localized route"
    );
}

/// What a Dart single-quoted literal written by `emit::dart_str` says.
fn dart_literal(code: &str, after: &str) -> String {
    let start = code.find(after).unwrap() + after.len();
    let rest = code[start..].trim_start();
    let body = rest.strip_prefix('\'').unwrap();
    let mut out = String::new();
    let mut chars = body.chars();
    loop {
        match chars.next().unwrap() {
            '\\' => out.push(chars.next().unwrap()),
            '\'' => return out,
            c => out.push(c),
        }
    }
}

#[test]
fn the_generated_file_embeds_the_same_tree_as_one_line() {
    for name in ["minimal", "shop", "features", "tabs"] {
        let (cfg, app, code) = analyzed(&examples(name));
        let embedded = dart_literal(&code, "String _devToolsTree() =>");
        assert!(!embedded.contains('\n'));
        assert_eq!(embedded, devtools::compact(&app, &cfg), "{name}");
        let parsed: Value = serde_json::from_str(&embedded).unwrap();
        assert_eq!(parsed, devtools::tree(&app, &cfg));
    }
}

#[test]
fn dollars_and_non_ascii_survive_the_dart_string() {
    // `$id` is a folder name and `übersicht` a spelling: the Dart literal escapes the `$`, and the
    // rest is UTF-8 in the file.
    let dir = files_project(&[
        ("page.dart", &page("Home")),
        (
            "products/$id/page.dart",
            "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id}); final int id; }",
        ),
        (
            "products/route.dart",
            "const paths = {'de': 'übersicht', 'fr': 'l.été'};",
        ),
    ]);
    let (cfg, app, code) = analyzed(dir.path());
    let tree = devtools::tree(&app, &cfg);
    let embedded = dart_literal(&code, "String _devToolsTree() =>");
    assert_eq!(serde_json::from_str::<Value>(&embedded).unwrap(), tree);
    let mut nodes = vec![];
    route_nodes(tree["items"].as_array().unwrap(), &mut nodes);
    let product = nodes.iter().find(|n| n["route"] == "ProductRoute").unwrap();
    assert_eq!(product["file"], "products/$id/page.dart");
    assert_eq!(product["spellings"]["de"], "/übersicht/:id");
    assert_eq!(product["spellings"]["fr"], "/l.été/:id");
    // In the file itself the `$` is escaped, so Dart does not interpolate.
    assert!(code.contains("products/\\$id/page.dart"), "{code}");
    assert!(code.contains("/übersicht/:id"), "{code}");
}

#[test]
fn an_app_with_no_route_has_an_empty_tree() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    fs::create_dir_all(dir.path().join("lib/app")).unwrap();
    let (cfg, app, _) = analyzed(dir.path());
    let tree = devtools::tree(&app, &cfg);
    assert_eq!(tree["items"], serde_json::json!([]));
    assert_eq!(tree["sites"], serde_json::json!({}));
}

#[test]
fn the_generated_file_registers_and_attaches_only_under_the_const() {
    for name in ["minimal", "shop", "features", "tabs"] {
        let (_, _, code) = analyzed(&examples(name));
        // `mount()` registers, `router()` attaches the router it builds and returns it.
        assert!(
            code.contains("    if (kFespalierDevTools) devToolsRegister(tree: _devToolsTree, matchUrl: matchUrl);\n"),
            "{name}"
        );
        assert!(
            code.contains("    final router = GoRouter(\n")
                && code.contains(
                    "    if (kFespalierDevTools) devToolsAttach(router);\n    return router;\n"
                ),
            "{name}"
        );
        // Nothing else of DevTools is reachable but through that constant: the tree function is
        // only a tear-off passed to `devToolsRegister`.
        assert_eq!(code.matches("_devToolsTree").count(), 2, "{name}");
        assert_eq!(code.matches("devToolsRegister(").count(), 1, "{name}");
        assert_eq!(code.matches("devToolsAttach(").count(), 1, "{name}");
        assert!(code.ends_with(";\n"), "{name}");
        let tail = code.lines().last().unwrap();
        assert!(
            tail.starts_with("String _devToolsTree() => '{\"protocol\":1,"),
            "{name}: {tail:.60}"
        );
    }
}
