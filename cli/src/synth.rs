//! Synthetic app folders for the benchmark and the incremental-regeneration tests: a
//! `BTreeMap` of `rel path → source` (the files under `lib/app`) that can be written to
//! disk and edited one file at a time, plus a small seeded random generator so a failing
//! sequence of edits can be replayed.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

/// xorshift64*: enough randomness for choosing edits, no dependency.
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// `0..n`.
    pub fn below(&mut self, n: usize) -> usize {
        (self.next() >> 11) as usize % n.max(1)
    }

    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

/// The files of an app folder, keyed by path relative to `lib/app`.
#[derive(Clone, Default)]
pub struct Files(pub BTreeMap<String, String>);

pub fn page(class: &str, params: &str) -> String {
    let (ctor, fields) = params_code(params);
    format!(
        "class {class} extends StatelessWidget {{ const {class}({{super.key{ctor}}}); {fields} }}"
    )
}

/// `"required int id, String? q"` → constructor parameters and the fields they fill.
fn params_code(params: &str) -> (String, String) {
    let mut ctor = String::new();
    let mut fields = String::new();
    for p in params.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let (req, decl) = match p.strip_prefix("required ") {
            Some(d) => ("required ", d),
            None => ("", p),
        };
        let (ty, name) = decl.rsplit_once(' ').unwrap();
        ctor.push_str(&format!(", {req}this.{name}"));
        fields.push_str(&format!("final {ty} {name}; "));
    }
    (ctor, fields)
}

pub fn layout(class: &str, extra: &str) -> String {
    format!(
        "class {class} extends StatelessWidget {{ const {class}({{super.key, required this.child{extra}}}); final Widget child; }}"
    )
}

impl Files {
    pub fn set(&mut self, rel: &str, src: impl Into<String>) {
        self.0.insert(rel.to_string(), src.into());
    }

    pub fn write_to(&self, project: &Path) {
        let app = project.join("lib/app");
        let _ = fs::remove_dir_all(&app);
        fs::write(project.join("pubspec.yaml"), "name: demo\n").unwrap();
        fs::create_dir_all(&app).unwrap();
        for (rel, src) in &self.0 {
            self.write_one(project, rel, src);
        }
    }

    pub fn write_one(&self, project: &Path, rel: &str, src: &str) {
        let p = project.join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, src).unwrap();
    }

    /// About `routes` routes in sections of about 25: a group or a static folder each,
    /// with a `layout.dart`, a `guard.dart` on every third section, and a `transition.dart` on every
    /// seventh; every eighth route has a `meta.dart`. A route is a static folder, or a dynamic
    /// one (`r7/$id`) on every fourth; every third page takes query parameters, every fifth
    /// route has a `data.dart` (keyed by the segment where there is one), every tenth a
    /// `loading.dart`. The root has a layout, a page and a `not_found.dart`.
    pub fn synth(routes: usize) -> Files {
        let mut f = Files::default();
        f.set("page.dart", page("HomePage", ""));
        f.set("layout.dart", layout("RootLayout", ""));
        f.set("not_found.dart", "class Missing extends StatelessWidget { const Missing({super.key, required this.uri}); final Uri uri; }");
        let per = 25;
        let sections = routes.div_ceil(per);
        for s in 0..sections {
            let dir = if s % 2 == 0 {
                format!("(g{s})")
            } else {
                format!("s{s}")
            };
            f.set(
                &format!("{dir}/layout.dart"),
                layout(&format!("S{s}Layout"), ""),
            );
            if s % 3 == 0 {
                f.set(
                    &format!("{dir}/guard.dart"),
                    "GuardResult guard(Ref ref) => null;",
                );
            }
            if s % 7 == 0 {
                f.set(
                    &format!("{dir}/transition.dart"),
                    "Page<void> transition(LocalKey key, Widget child) => x;",
                );
            }
            for i in (s * per)..((s + 1) * per).min(routes) {
                f.add_route(&format!("{dir}/r{i}"), i);
            }
        }
        f
    }

    /// The files of one route folder; `i` picks which of the optional files it gets.
    pub fn add_route(&mut self, dir: &str, i: usize) {
        let dynamic = i.is_multiple_of(4);
        let dir = if dynamic {
            format!("{dir}/$id")
        } else {
            dir.to_string()
        };
        let mut params = String::new();
        let mut data_params = vec![];
        if dynamic {
            params.push_str("required int id, ");
            data_params.push("required int id");
        }
        if i.is_multiple_of(3) {
            params.push_str("String? q, int? page, ");
            data_params.extend(["String? q", "int? page"]);
        }
        let has_data = i.is_multiple_of(5);
        if has_data {
            params.push_str("required Item item, ");
        }
        self.set(
            &format!("{dir}/page.dart"),
            page(&format!("R{i}Page"), &params),
        );
        if has_data {
            let named = if data_params.is_empty() {
                String::new()
            } else {
                format!(", {{{}}}", data_params.join(", "))
            };
            self.set(
                &format!("{dir}/data.dart"),
                format!("Future<Item> data(Ref ref{named}) async => Item();"),
            );
        }
        if i.is_multiple_of(8) {
            self.set(
                &format!("{dir}/meta.dart"),
                format!("const meta = 'route {i}';"),
            );
        }
        if i.is_multiple_of(10) {
            self.set(&format!("{dir}/loading.dart"), format!("class R{i}Loading extends StatelessWidget {{ const R{i}Loading({{super.key}}); }}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::build;
    use crate::config::Config;

    #[test]
    fn the_synthetic_app_checks_cleanly() {
        let dir = tempfile::tempdir().unwrap();
        let files = Files::synth(200);
        files.write_to(dir.path());
        let (_, diags, routes) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
        assert!(
            diags.0.is_empty(),
            "{:?}",
            diags
                .0
                .iter()
                .take(5)
                .map(std::string::ToString::to_string)
                .collect::<Vec<_>>()
        );
        assert_eq!(routes, 200 + 1);
    }
}
