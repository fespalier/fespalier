//! `fsp routes --graph`: the route tree as a Mermaid flowchart or a Graphviz digraph, to paste
//! into a README, a pull request or an issue.
//!
//! It draws what `app.g.dart` hands to `go_router` ([`emit::frames`]), not the folders:
//!
//! - **Nodes** are routes (a `GoRoute`): the URL pattern, the typed route class, the other
//!   spellings of a [localized](crate::locale) path, and markers ([`markers`]).
//! - **Edges** are `go_router`'s parent and child: a route that `nest = false` takes out of the
//!   page above hangs from that page's parent, as it is emitted.
//! - **Boxes** are navigators: the root navigator around everything, a layout's shell, a tab
//!   layout and each of its branches. A route inside a shell that renders on the root navigator
//!   anyway (`navigator.dart`, `present.dart`) is marked `root`.
//!
//! Labels are escaped for each format: Mermaid gets entity codes (`#quot;`, `#36;` for `$`,
//! `#252;` for `ü`), Graphviz backslash escapes and HTML entities, so a label never ends a string
//! or starts markup.

use crate::emit::{self, Frame};
use crate::locale;
use crate::resolve::{self, App, Route};

/// The output formats of `--graph`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum Format {
    /// A Mermaid `flowchart TD`, which GitHub renders in Markdown
    Mermaid,
    /// A Graphviz `digraph` (`dot -Tsvg`)
    Dot,
}

/// A route node: its id in the output, and the lines of its label.
struct Node {
    num: usize,
    id: String,
    lines: Vec<String>,
    redirect: bool,
}

/// What a box holds, in order.
enum Item {
    Node(Node),
    Box(Boxed),
}

/// A navigator: a box with a title around the routes it shows.
struct Boxed {
    id: String,
    title: String,
    items: Vec<Item>,
}

#[derive(Default)]
struct Builder {
    nodes: usize,
    boxes: usize,
    edges: Vec<(usize, usize)>,
}

/// The markers of a route, in the order `fsp routes` lists its tags. A new marker goes here
/// and in the README's list; both renderers take them as they are.
pub fn markers(r: &Route, root: bool, guarded: bool) -> Vec<&'static str> {
    let mut out = vec![];
    if r.redirect.is_some() {
        out.push("redirect");
    }
    if r.data.is_some() {
        out.push("data");
    }
    if !r.actions.is_empty() {
        out.push("action");
    }
    if guarded {
        out.push("guard");
    }
    if r.present.is_some() {
        out.push("present");
    }
    if root {
        out.push("root");
    }
    if r.sibling {
        out.push("sibling");
    }
    if r.defers_page() {
        out.push("deferred");
    }
    out
}

/// A file of folder `dir`, relative to the app folder.
fn file(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{dir}/{name}")
    }
}

impl Builder {
    fn node_num(&mut self) -> usize {
        self.nodes += 1;
        self.nodes - 1
    }

    fn box_id(&mut self) -> String {
        self.boxes += 1;
        format!("b{}", self.boxes - 1)
    }

    /// The items of `frames`, with each route's edges to the routes nested in it.
    fn items(&mut self, app: &App, frames: &[Frame]) -> Vec<Item> {
        frames.iter().map(|f| self.item(app, f)).collect()
    }

    fn item(&mut self, app: &App, f: &Frame) -> Item {
        match f {
            Frame::Route {
                id,
                url,
                root,
                guarded,
                children,
            } => {
                let r = &app.routes[*id];
                let num = self.node_num();
                let node_id = format!("n{num}");
                let mut lines = vec![
                    resolve::pattern(url),
                    format!("{}Route", r.name.as_deref().unwrap_or("?")),
                ];
                let spelled: Vec<String> = locale::locales(&r.localized)
                    .iter()
                    .map(|l| format!("{l} {}", locale::pattern_in(url, &r.localized, l)))
                    .collect();
                if !spelled.is_empty() {
                    lines.push(spelled.join(", "));
                }
                let marks = markers(r, *root, *guarded);
                if !marks.is_empty() {
                    lines.push(format!("({})", marks.join(", ")));
                }
                let node = Node {
                    num,
                    id: node_id.clone(),
                    lines,
                    redirect: r.page.is_none(),
                };
                let nested = self.items(app, children);
                let mut entries = vec![];
                for i in &nested {
                    entries_of(i, &mut entries);
                }
                for e in entries {
                    self.edges.push((num, e));
                }
                if nested.is_empty() {
                    Item::Node(node)
                } else {
                    // The route's children are beside it in its navigator: one list, no box.
                    Item::Box(Boxed {
                        id: String::new(),
                        title: String::new(),
                        items: std::iter::once(Item::Node(node)).chain(nested).collect(),
                    })
                }
            }
            Frame::Shell { id, root, children } => {
                let r = &app.routes[*id];
                let marks = layout_marks(r, *root);
                let title = with_marks(format!("layout {}", file(&r.dir, "layout.dart")), &marks);
                let id = self.box_id();
                Item::Box(Boxed {
                    id,
                    title,
                    items: self.items(app, children),
                })
            }
            Frame::Tabs { id, root, branches } => {
                let r = &app.routes[*id];
                let marks = layout_marks(r, *root);
                let title = with_marks(format!("tabs {}", file(&r.dir, "layout.dart")), &marks);
                let id = self.box_id();
                let items = branches
                    .iter()
                    .enumerate()
                    .map(|(i, (name, routes))| {
                        let id = self.box_id();
                        let title = if name == "." {
                            format!("tab {i}: its own page")
                        } else {
                            format!("tab {i}: {name}")
                        };
                        Item::Box(Boxed {
                            id,
                            title,
                            items: self.items(app, routes),
                        })
                    })
                    .collect();
                Item::Box(Boxed { id, title, items })
            }
        }
    }
}

/// The markers of a layout's box: a section's `data.dart`, a guard in its folder, and whether
/// its shell is on the root navigator.
fn layout_marks(r: &Route, root: bool) -> Vec<&'static str> {
    [
        (r.is_section(), "data"),
        (r.guard.is_some(), "guard"),
        (root, "root"),
    ]
    .into_iter()
    .filter_map(|(on, m)| on.then_some(m))
    .collect()
}

fn with_marks(title: String, marks: &[&str]) -> String {
    if marks.is_empty() {
        title
    } else {
        format!("{title} ({})", marks.join(", "))
    }
}

/// The routes an edge from the route above lands on: the item's own route, or the first routes
/// inside a shell or tab layout (`go_router`'s parent of those is the route above the shell).
fn entries_of(item: &Item, out: &mut Vec<usize>) {
    match item {
        Item::Node(n) => out.push(n.num),
        // A route with its children: an unnamed list whose first node is the route.
        Item::Box(b) if b.id.is_empty() => {
            if let Some(Item::Node(n)) = b.items.first() {
                out.push(n.num);
            }
        }
        Item::Box(b) => {
            for i in &b.items {
                entries_of(i, out);
            }
        }
    }
}

/// The graph of the app's routes in `format`, one line per element, ending in a newline.
pub fn render(app: &App, format: Format) -> String {
    let mut b = Builder::default();
    let items = b.items(app, &emit::frames(app));
    // Parents were numbered before their children: the edges read top-down, a route's children
    // together, whatever order the recursion finished them in.
    b.edges.sort_unstable();
    let root = Boxed {
        id: "rootnav".into(),
        title: "root navigator".into(),
        items,
    };
    let mut out = vec![];
    match format {
        Format::Mermaid => {
            out.push("flowchart TD".to_string());
            if !root.items.is_empty() {
                mermaid_box(&root, 1, &mut out);
            }
            for (from, to) in &b.edges {
                out.push(format!("  n{from} --> n{to}"));
            }
            let redirects = redirect_ids(&root.items);
            if !redirects.is_empty() {
                out.push("  classDef redirect stroke-dasharray: 5 5".into());
                out.push(format!("  class {} redirect", redirects.join(",")));
            }
        }
        Format::Dot => {
            out.push("digraph routes {".to_string());
            out.push("  rankdir=TB;".into());
            out.push("  node [shape=box];".into());
            if !root.items.is_empty() {
                dot_box(&root, 1, &mut out);
            }
            for (from, to) in &b.edges {
                out.push(format!("  n{from} -> n{to};"));
            }
            out.push("}".into());
        }
    }
    let mut text = out.join("\n");
    text.push('\n');
    text
}

fn redirect_ids(items: &[Item]) -> Vec<String> {
    let mut out = vec![];
    for i in items {
        match i {
            Item::Node(n) if n.redirect => out.push(n.id.clone()),
            Item::Node(_) => {}
            Item::Box(b) => out.extend(redirect_ids(&b.items)),
        }
    }
    out
}

fn mermaid_box(b: &Boxed, depth: usize, out: &mut Vec<String>) {
    let pad = "  ".repeat(depth);
    out.push(format!(
        "{pad}subgraph {}[\"{}\"]",
        b.id,
        mermaid_text(&b.title)
    ));
    mermaid_items(&b.items, depth + 1, out);
    out.push(format!("{pad}end"));
}

fn mermaid_items(items: &[Item], depth: usize, out: &mut Vec<String>) {
    let pad = "  ".repeat(depth);
    for i in items {
        match i {
            Item::Node(n) => {
                let label: Vec<String> = n.lines.iter().map(|l| mermaid_text(l)).collect();
                out.push(format!("{pad}{}[\"{}\"]", n.id, label.join("<br/>")));
            }
            Item::Box(b) if b.id.is_empty() => mermaid_items(&b.items, depth, out),
            Item::Box(b) => mermaid_box(b, depth, out),
        }
    }
}

fn dot_box(b: &Boxed, depth: usize, out: &mut Vec<String>) {
    let pad = "  ".repeat(depth);
    out.push(format!("{pad}subgraph cluster_{} {{", b.id));
    out.push(format!("{pad}  label=\"{}\";", dot_text(&b.title)));
    out.push(format!(
        "{pad}  style={};",
        if b.id == "rootnav" {
            "dashed"
        } else {
            "rounded"
        }
    ));
    dot_items(&b.items, depth + 1, out);
    out.push(format!("{pad}}}"));
}

fn dot_items(items: &[Item], depth: usize, out: &mut Vec<String>) {
    let pad = "  ".repeat(depth);
    for i in items {
        match i {
            Item::Node(n) => {
                let label: Vec<String> = n.lines.iter().map(|l| dot_text(l)).collect();
                let style = if n.redirect { ", style=dashed" } else { "" };
                out.push(format!(
                    "{pad}{} [label=\"{}\"{style}];",
                    n.id,
                    label.join("\\n")
                ));
            }
            Item::Box(b) if b.id.is_empty() => dot_items(&b.items, depth, out),
            Item::Box(b) => dot_box(b, depth, out),
        }
    }
}

/// Text inside a quoted Mermaid label: entity codes for what would end the string, open markup
/// or a math block (`$$`), and for every character beyond ASCII.
pub fn mermaid_text(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '"' => out.push_str("#quot;"),
            '#' => out.push_str("#35;"),
            '<' => out.push_str("#lt;"),
            '>' => out.push_str("#gt;"),
            '&' => out.push_str("#amp;"),
            '$' => out.push_str("#36;"),
            c if !c.is_ascii() || c.is_ascii_control() => out.push_str(&format!("#{};", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Text inside a quoted Graphviz string: `"` and `\` escaped, and HTML entities for `&` and
/// every character beyond ASCII, so the file is ASCII whatever the spellings.
pub fn dot_text(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '&' => out.push_str("&amp;"),
            c if !c.is_ascii() || c.is_ascii_control() => {
                out.push_str(&format!("&#{};", c as u32));
            }
            c => out.push(c),
        }
    }
    out
}
