//! The minijinja environment for everything fespalier writes: `app.g.dart`
//! and the files `fsp new` scaffolds. Templates live in `cli/templates/`.

use std::sync::OnceLock;

use minijinja::Environment;
use serde::Serialize;

const TEMPLATES: [(&str, &str); 7] = [
    ("app.g.dart", include_str!("../templates/app.g.dart.jinja")),
    ("new/page.dart", include_str!("../templates/new/page.dart.jinja")),
    ("new/data.dart", include_str!("../templates/new/data.dart.jinja")),
    ("new/loading.dart", include_str!("../templates/new/loading.dart.jinja")),
    ("new/error.dart", include_str!("../templates/new/error.dart.jinja")),
    ("new/layout.dart", include_str!("../templates/new/layout.dart.jinja")),
    ("new/guard.dart", include_str!("../templates/new/guard.dart.jinja")),
];

fn env() -> &'static Environment<'static> {
    static ENV: OnceLock<Environment<'static>> = OnceLock::new();
    ENV.get_or_init(|| {
        let mut env = Environment::new();
        env.set_trim_blocks(true);
        env.set_lstrip_blocks(true);
        env.set_keep_trailing_newline(true);
        env.set_undefined_behavior(minijinja::UndefinedBehavior::Strict);
        for (name, src) in TEMPLATES {
            env.add_template(name, src).unwrap_or_else(|e| panic!("template {name}: {e:#}"));
        }
        env
    })
}

pub fn render(name: &str, cx: impl Serialize) -> String {
    env()
        .get_template(name)
        .and_then(|t| t.render(cx))
        .unwrap_or_else(|e| panic!("rendering {name}: {e:#}"))
}
