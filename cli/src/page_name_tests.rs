//! Page names (since 0.9.0): each `pageBuilder:` the generated file writes is wrapped in
//! `namedPage('<pattern>', () => ...)`, so the pages `Transitions.*`, `layoutPage` and
//! `remountPage` build are named by their route's pattern. A bare `builder:` is unchanged.

use std::fs;

use crate::build;
use crate::config::Config;

fn project(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

fn code(files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn item() -> String {
    "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }".into()
}

const FADE: &str =
    "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);";
const SHEET: &str =
    "Page<void> present(LocalKey key, Widget child) => SheetPage(key: key, child: child);";
const LAYOUT: &str = "class BoxLayout extends StatelessWidget { const BoxLayout({super.key, required this.child}); final Widget child; }";
const TABS: &str = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }";

/// Every line that opens a `pageBuilder:`.
fn builders(code: &str) -> Vec<&str> {
    code.lines()
        .filter(|l| l.contains("pageBuilder:"))
        .map(str::trim)
        .collect()
}

#[test]
fn a_page_with_a_transition_or_a_sheet_is_named_by_its_pattern() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("shop/transition.dart", FADE),
        ("shop/page.dart", &page("Shop")),
        ("shop/$id/page.dart", &item()),
        (
            "shop/$id/buy/page.dart",
            "class BuyPage extends StatelessWidget { const BuyPage({super.key, required this.id}); final int id; }",
        ),
        ("shop/$id/buy/present.dart", SHEET),
    ]);
    let b = builders(&c);
    assert_eq!(b.len(), 3, "{b:?}");
    for (pattern, call) in [
        ("/shop", "transition"),
        ("/shop/:id", "transition"),
        ("/shop/:id/buy", "present"),
    ] {
        assert!(
            b.iter().any(|l| l.contains(&format!(
                "pageBuilder: (context, state) => namedPage('{pattern}', () => _i"
            )) && l.contains(&format!(".{call}("))),
            "{pattern}: {b:?}"
        );
    }
    // Two lines per page builder: the opening gains the call and the closing one `)`.
    assert_eq!(c.matches("namedPage(").count(), 3, "{c}");
    assert!(c.contains("        )),\n"), "{c}");
    // A bare `builder:` is go_router's own page: unchanged.
    assert!(
        c.contains("builder: (context, state) => const _i0.HomePage(),"),
        "{c}"
    );
}

#[test]
fn a_remount_page_is_named_by_its_pattern_not_by_go_routers_path() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("items/route.dart", "const remount = Remount.onSegments;\n"),
        ("items/$id/page.dart", &item()),
    ]);
    assert!(
        c.contains("pageBuilder: (context, state) => namedPage('/items/:id', () => remountPage("),
        "{c}"
    );
    assert!(
        c.contains("remountKey(state, Remount.onSegments, const ['id']),\n"),
        "{c}"
    );
    assert!(c.contains("              ),\n            )),\n"), "{c}");
}

#[test]
fn a_shell_is_named_by_its_sections_pattern() {
    let c = code(&[
        ("layout.dart", LAYOUT),
        ("page.dart", &page("Home")),
        ("shop/layout.dart", LAYOUT),
        ("shop/page.dart", &page("Shop")),
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/one/page.dart", &page("One")),
        ("(tabs)/two/page.dart", &page("Two")),
    ]);
    // The root layout and a group's tab layout are both `/`; a folder's is its pattern.
    assert!(
        c.contains("pageBuilder: (context, state, child) => namedPage('/', () => layoutPage("),
        "{c}"
    );
    assert!(
        c.contains("pageBuilder: (context, state, child) => namedPage('/shop', () => layoutPage("),
        "{c}"
    );
    assert!(
        c.contains(
            "pageBuilder: (context, state, navigationShell) => namedPage('/', () => layoutPage("
        ),
        "{c}"
    );
    assert_eq!(c.matches("namedPage(").count(), 3, "{c}");
}

#[test]
fn a_shell_with_a_transition_is_named_too() {
    let c = code(&[
        ("transition.dart", FADE),
        ("layout.dart", LAYOUT),
        ("page.dart", &page("Home")),
    ]);
    assert!(
        c.contains("pageBuilder: (context, state, child) => namedPage('/', () => _i1.transition("),
        "{c}"
    );
    assert!(
        c.contains("pageBuilder: (context, state) => namedPage('/', () => _i1.transition("),
        "{c}"
    );
}

#[test]
fn a_localized_route_is_named_by_its_canonical_pattern() {
    let c = code(&[
        ("transition.dart", FADE),
        ("page.dart", &page("Home")),
        ("products/route.dart", "const paths = {'fr': 'produits'};\n"),
        ("products/$id/page.dart", &item()),
    ]);
    // The go_router path has the spellings (`:_l0(products|produits)`); the name does not.
    assert!(c.contains("namedPage('/products/:id', () => _i"), "{c}");
    assert!(!c.contains("namedPage('/:_l"), "{c}");
}

#[test]
fn an_app_with_no_page_builders_has_no_names() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("about/page.dart", &page("About")),
    ]);
    assert!(!c.contains("namedPage"), "{c}");
    assert!(builders(&c).is_empty(), "{c}");
}

#[test]
fn every_page_builder_is_named() {
    let c = code(&[
        ("transition.dart", FADE),
        ("layout.dart", LAYOUT),
        ("page.dart", &page("Home")),
        ("items/route.dart", "const remount = Remount.onLocation;\n"),
        ("items/$id/page.dart", &item()),
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/one/page.dart", &page("One")),
    ]);
    let b = builders(&c);
    assert!(!b.is_empty());
    for line in b {
        assert!(line.contains("namedPage("), "{line}");
    }
}
