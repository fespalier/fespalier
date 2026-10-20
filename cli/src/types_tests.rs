//! `types.rs`: the canonical form of a type, with a fake [`Scope`] in place of `enums::Libs`.

use std::collections::HashMap;
use std::fs;

use crate::action_tests::{HOME, code, errors, has, lacks, project, widget};
use crate::config::Config;
use crate::types::{self, Canonical, Declared, Scope};

const PAGE: &str = "lib/app/page.dart";
const IDS: &str = "lib/models/ids.dart";
const PRODUCT: &str = "lib/models/product.dart";

/// What a file sees: `(file, prefix, name)` → the declaring file and the typedef's alias, if any.
#[derive(Default)]
struct Fake(HashMap<(String, Option<String>, String), (String, Option<String>)>);

impl Fake {
    fn sees(
        mut self,
        file: &str,
        prefix: Option<&str>,
        name: &str,
        decl: &str,
        alias: Option<&str>,
    ) -> Self {
        self.0.insert(
            (file.into(), prefix.map(str::to_string), name.into()),
            (decl.into(), alias.map(str::to_string)),
        );
        self
    }
}

impl Scope for Fake {
    fn declared(&self, path: &str, prefix: Option<&str>, name: &str) -> Option<Declared> {
        let key = (
            path.to_string(),
            prefix.map(str::to_string),
            name.to_string(),
        );
        let (decl, alias) = self.0.get(&key)?;
        Some(Declared {
            decl: decl.clone(),
            name: name.to_string(),
            alias: alias.clone(),
        })
    }
}

fn canon(scope: &Fake, file: &str, text: &str) -> Canonical {
    types::canonical(scope, file, text)
}

/// The names the page and `ids.dart` see: the product, and the typedefs of the models.
fn models() -> Fake {
    let mut f = Fake::default();
    for file in [PAGE, IDS] {
        f = f
            .sees(file, None, "Product", PRODUCT, None)
            .sees(file, None, "Category", PRODUCT, None)
            .sees(file, None, "ProductView", IDS, Some("Product"))
            .sees(file, None, "Chain", IDS, Some("ProductView"))
            .sees(file, None, "ProductId", IDS, Some("int"))
            .sees(file, None, "MaybeInt", IDS, Some("int?"))
            .sees(file, None, "Json", IDS, Some("Map<String, Object?>"))
            .sees(
                file,
                None,
                "PayFields",
                IDS,
                Some("({int amount, String note})"),
            )
            .sees(file, None, "Retry", IDS, Some("void Function()"))
            .sees(file, None, "Cat", IDS, Some("Category"))
            .sees(file, None, "Generic", IDS, None);
    }
    f
}

#[test]
fn a_typedef_is_the_declaration_it_names() {
    let f = models().sees(PAGE, None, "PV", PAGE, Some("Product"));
    let c = canon(&f, PAGE, "PV");
    assert_eq!(c.key, "lib/models/product.dart#Product");
    assert_eq!(c.expanded, "Product");
    assert!(c.followed && c.declared);
    assert!(c.unknown.is_empty());
}

#[test]
fn a_chain_of_typedefs_is_followed_to_the_end() {
    let f = models();
    let c = canon(&f, PAGE, "Chain");
    assert_eq!(c.key, canon(&f, PAGE, "Product").key);
    assert_eq!(c.expanded, "Product");
}

#[test]
fn an_import_prefix_is_dropped_and_resolved() {
    let f = models().sees(PAGE, Some("ids"), "ProductView", IDS, Some("Product"));
    let prefixed = canon(&f, PAGE, "ids.ProductView");
    assert_eq!(prefixed.key, "lib/models/product.dart#Product");
    assert_eq!(prefixed.expanded, "Product");
    assert_eq!(prefixed.key, canon(&f, PAGE, "ProductView").key);
    // Another prefix of the same library is the same type.
    let m = models().sees(PAGE, Some("m"), "Product", PRODUCT, None);
    assert_eq!(
        canon(&m, PAGE, "m.Product").key,
        canon(&m, PAGE, "Product").key
    );
}

#[test]
fn a_typedef_of_a_dart_core_type_comes_to_it() {
    let f = models();
    let c = canon(&f, PAGE, "List<ProductId>");
    assert_eq!(c.key, "List<int>");
    assert_eq!(c.expanded, "List<int>");
    assert!(c.followed && !c.declared && c.unknown.is_empty());
    assert_eq!(canon(&f, PAGE, "MaybeInt?").key, "int?");
    assert_eq!(canon(&f, PAGE, "MaybeInt").key, "int?");
}

#[test]
fn a_record_typedef_is_its_record() {
    let f = models();
    let c = canon(&f, PAGE, "PayFields");
    assert_eq!(c.key, "({int amount, String note})");
    assert_eq!(c.key, canon(&f, PAGE, "({int amount, String note})").key);
}

#[test]
fn a_function_type_and_a_map_typedef_are_spelled_the_same() {
    let f = models();
    assert_eq!(canon(&f, PAGE, "Retry").key, "void Function()");
    assert_eq!(
        canon(&f, PAGE, "Json").key,
        canon(&f, PAGE, "Map<String, Object?>").key
    );
}

#[test]
fn a_name_nothing_declares_is_unknown_and_listed_once() {
    let f = models();
    let c = canon(&f, PAGE, "Map<JsonMap, JsonMap>");
    assert_eq!(c.unknown, ["JsonMap"]);
    assert!(!c.followed && !c.declared);
    assert_eq!(c.key, "Map<JsonMap, JsonMap>");
}

#[test]
fn a_cycle_stops_at_the_depth_limit() {
    let f = Fake::default()
        .sees("a.dart", None, "A", "a.dart", Some("B"))
        .sees("a.dart", None, "B", "a.dart", Some("A"));
    let c = canon(&f, "a.dart", "A");
    assert!(c.followed);
    assert_eq!(c.key, "a.dart#A");
}

#[test]
fn a_nullable_alias_is_not_doubled() {
    let f = models();
    assert_eq!(canon(&f, PAGE, "MaybeInt?").expanded, "int?");
}

#[test]
fn a_generic_typedef_is_a_declared_type_not_followed() {
    let f = models();
    let generic = canon(&f, PAGE, "Generic<int>");
    assert!(!generic.followed && generic.declared);
    assert_ne!(generic.key, canon(&f, PAGE, "Map<String, int>").key);
}

#[test]
fn the_hint_names_only_the_names_one_side_could_not_follow() {
    let f = models();
    let a = canon(&f, PAGE, "JsonMap");
    let b = canon(&f, PAGE, "Map<String, Object?>");
    assert_eq!(
        types::hint(&a, &b),
        "; fsp follows typedefs in this package's files only, and found no declaration of `JsonMap` there, so it compares it as spelled"
    );
    // A name both sides leave unfollowed is not the cause.
    let c = canon(&f, PAGE, "Map<JsonMap, int>");
    assert_eq!(
        types::hint(&c, &canon(&f, PAGE, "Map<JsonMap, String>")),
        ""
    );
}

#[test]
fn the_hint_lists_two_and_three_names() {
    let f = models();
    let a = canon(&f, PAGE, "A");
    let b = canon(&f, PAGE, "B");
    assert!(
        types::hint(&a, &b)
            .ends_with("found no declaration of `A` or `B` there, so it compares them as spelled")
    );
    let three = canon(&f, PAGE, "Map<A, B>");
    let c = canon(&f, PAGE, "C");
    assert!(types::hint(&three, &c).ends_with(
        "found no declaration of `A`, `B` or `C` there, so it compares them as spelled"
    ));
    assert_eq!(types::hint_of(&[]), "");
}

// --- what the generator does with typedefs of the app's files (since 0.21.0) ---------------------

/// The files of the app's own models: a product, a category enum, and typedefs of them, read from
/// `lib/models/` (the page and data files reach them as `../../../models/`).
fn model_files() -> Vec<(&'static str, &'static str)> {
    vec![
        (
            "../models/product.dart",
            "class Product {}\nclass Item {}\nenum Category { shoes, hats }\n",
        ),
        (
            "../models/ids.dart",
            "import 'product.dart';\n\
             typedef ProductView = Product;\n\
             typedef ProductId = int;\n\
             typedef PageNo = int;\n\
             typedef Json = Map<String, Object?>;\n\
             typedef Cat = Category;\n\
             typedef PayFields = ({int amount, String note});\n\
             typedef Retry = void Function();\n\
             typedef Kid = Widget;\n",
        ),
    ]
}

/// The files of `model_files` with the given app files beside them.
fn with_models<'a>(app: &[(&'a str, &'a str)]) -> Vec<(&'a str, &'a str)> {
    let models: Vec<(&'a str, &'a str)> = model_files();
    models.into_iter().chain(app.iter().copied()).collect()
}

const NICKNAME_PAGE: &str =
    "class NicknamePage extends StatelessWidget { const NicknamePage({super.key}); }";

/// A page under `products/$id/`, with the constructor and fields given.
fn product_page(imports: &str, ctor: &str, fields: &str) -> String {
    format!("{imports}\n{}", widget("ProductPage", fields, ctor))
}

/// The errors of the files, as the messages (without their `✗ file:line` heads).
fn messages(files: &[(&str, &str)]) -> Vec<String> {
    errors(files)
        .lines()
        .map(|l| l.split_once("  ").map_or(l, |(_, m)| m).to_string())
        .collect()
}

#[test]
fn a_page_takes_data_through_a_typedef() {
    let page = product_page(
        "import '../../../models/ids.dart';",
        ", required this.id, required this.product",
        "final int id; final ProductView product;",
    );
    let data = "import '../../../models/product.dart';\nFuture<Product> data(Ref ref, {required int id}) async => Product();";
    let files = with_models(&[
        ("products/$id/page.dart", &page),
        ("products/$id/data.dart", data),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
    let c = code(&files);
    has(&c, &["product: "]);
    lacks(&c, &["can't fill"]);
}

#[test]
fn a_data_parameter_spelled_with_a_typedef_or_a_prefix_is_data() {
    let data =
        "import '../../../models/product.dart';\nFuture<Product> data(Ref ref) async => Product();";
    let typedef_page = product_page(
        "import '../../../models/ids.dart';",
        ", required this.data",
        "final ProductView data;",
    );
    let prefix_page = product_page(
        "import '../../../models/product.dart' as m;",
        ", required this.data",
        "final m.Product data;",
    );
    let prefix_page = prefix_page.replace("ProductPage", "OtherPage");
    let files = with_models(&[
        ("products/page.dart", &typedef_page),
        ("products/data.dart", data),
        ("other/page.dart", &prefix_page),
        ("other/data.dart", data),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
    // The mismatch stays where the types differ: a typedef of another class is still an error.
    let other = product_page(
        "import '../../../models/ids.dart';",
        ", required this.data",
        "final PageNo data;",
    );
    let e = messages(&with_models(&[
        ("products/page.dart", &other),
        ("products/data.dart", data),
    ]));
    assert!(
        e.iter()
            .any(|m| m.starts_with("`data` is PageNo but data.dart yields Product")),
        "{e:?}"
    );
}

#[test]
fn section_data_through_a_typedef() {
    let layout = "class ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child}); final Widget child; }";
    let section_data =
        "import '../../../models/product.dart';\nFuture<Product> data(Ref ref) async => Product();";
    let page = product_page(
        "import '../../../models/ids.dart';",
        ", required this.team",
        "final ProductView team;",
    );
    let files = with_models(&[
        ("shop/layout.dart", layout),
        ("shop/data.dart", section_data),
        ("shop/items/page.dart", &page),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
}

#[test]
fn a_segment_typed_with_a_typedef_of_int_is_an_int() {
    let page = product_page(
        "import '../../../models/ids.dart';",
        ", required this.id",
        "final ProductId id;",
    );
    let data = "import '../../../models/product.dart';\nFuture<Product> data(Ref ref, {required int id}) async => Product();";
    let files = with_models(&[
        ("products/$id/page.dart", &page),
        ("products/$id/data.dart", data),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
    let c = code(&files);
    has(&c, &["final int id;", "Segment.asInt"]);
    lacks(&c, &["ProductId"]);
}

#[test]
fn a_segment_typed_with_a_typedef_of_an_enum_is_the_enum() {
    // (a) Only the page spells the typedef: the enum is found through it, and the generated code
    // names the alias as the page's import shows it.
    let page = product_page(
        "import '../../../models/ids.dart';",
        ", required this.category",
        "final Cat category;",
    );
    let files = with_models(&[("shop/$category/page.dart", &page)]);
    assert_eq!(messages(&files), Vec::<String>::new());
    let c = code(&files);
    has(
        &c,
        &[
            "Segment.asEnum(s, 'category', Cat.values)",
            "final Cat category;",
            "show Cat;",
        ],
    );
    // (b) The page spells the alias and its data.dart the enum: the same type, no mismatch.
    let data = "import '../../../models/product.dart';\nFuture<void> data(Ref ref, {required Category category}) async {}";
    let files = with_models(&[
        ("shop/$category/page.dart", &page),
        ("shop/$category/data.dart", data),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
}

#[test]
fn a_query_parameter_typed_with_a_typedef() {
    let page = "import '../../models/ids.dart';\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, this.page}); final PageNo? page; }";
    let data = "Future<int> data(Ref ref, {int? page}) async => 1;";
    let files = with_models(&[("shop/page.dart", page), ("shop/data.dart", data)]);
    assert_eq!(messages(&files), Vec::<String>::new());
    let c = code(&files);
    has(&c, &["Query.asInt(s, 'page')"]);
}

#[test]
fn an_optional_page_parameter_typed_with_a_typedef_of_int_is_a_query_parameter() {
    // The migration item: left to its default before 0.21.0, a query parameter now.
    let page = "import '../../models/ids.dart';\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, this.page}); final PageNo? page; }";
    let files = with_models(&[("shop/page.dart", page)]);
    let c = code(&files);
    has(&c, &["int? page"]);
}

#[test]
fn extra_through_a_typedef_fits() {
    let guard = "import '../../models/ids.dart';\nGuardResult guard(ProviderContainer c, {ProductView? extra}) => null;";
    let page = "import '../../models/product.dart';\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, this.extra}); final Product? extra; }";
    let files = with_models(&[("shop/guard.dart", guard), ("shop/page.dart", page)]);
    assert_eq!(messages(&files), Vec::<String>::new());
}

#[test]
fn a_form_reads_a_record_typedef_from_an_imported_file() {
    let action = "import '../../models/ids.dart';\nPayFields form() => (amount: 1, note: '');\nFuture<void> action(Ref ref, {required PayFields input}) async {}\n";
    let files = with_models(&[
        ("nickname/page.dart", NICKNAME_PAGE),
        ("nickname/action.dart", action),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
    let c = code(&files);
    has(
        &c,
        &[
            "amount: f.text('amount', (v) => v.amount, FieldCodec.integer)",
            "note: f.text('note', (v) => v.note, FieldCodec.text)",
        ],
    );
}

#[test]
fn companions_compare_through_typedefs() {
    let action = "import '../../models/ids.dart';\n\
        PayFields form() => (amount: 1, note: '');\n\
        FieldErrors? validate(PayFields input) => null;\n\
        Product optimistic(ProductView current, PayFields input) => current;\n\
        Future<void> action(Ref ref, {required ({int amount, String note}) input}) async {}\n";
    let data =
        "import '../../models/product.dart';\nFuture<Product> data(Ref ref) async => Product();";
    let files = with_models(&[
        ("nickname/page.dart", NICKNAME_PAGE),
        ("nickname/data.dart", data),
        ("nickname/action.dart", action),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
}

#[test]
fn a_retry_typed_with_a_typedef_fits() {
    let error = "import '../../models/ids.dart';\nclass ShopError extends StatelessWidget { const ShopError({super.key, required this.error, required this.retry}); final Object error; final Retry retry; }";
    let layout = "import '../../models/ids.dart';\nclass ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.content}); final Kid content; }";
    let files = with_models(&[
        ("shop/error.dart", error),
        ("shop/page.dart", HOME),
        ("shop/layout.dart", layout),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
}

#[test]
fn a_typedef_of_another_package_is_compared_as_spelled_and_says_so() {
    let page = "import 'package:common/json.dart';\nclass ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id, required this.data}); final int id; final JsonMap data; }";
    let data = "Future<Map<String, Object?>> data(Ref ref, {required int id}) async => {};";
    let e = messages(&[
        ("products/$id/page.dart", page),
        ("products/$id/data.dart", data),
    ]);
    assert_eq!(
        e,
        [
            "`data` is JsonMap but data.dart yields Map<String, Object?>; fsp follows typedefs in this package's files only, and found no declaration of `JsonMap` there, so it compares it as spelled"
        ]
    );
}

#[test]
fn what_pub_get_writes_changes_nothing() {
    let page = "import 'package:common/json.dart';\nclass ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id, required this.data}); final int id; final JsonMap data; }";
    let data = "Future<Map<String, Object?>> data(Ref ref, {required int id}) async => {};";
    let dir = project(&[
        ("products/$id/page.dart", page),
        ("products/$id/data.dart", data),
    ]);
    let run = || {
        let (_, diags, _) = crate::build(&dir.path().join("lib/app"), &Config::default()).unwrap();
        diags
            .0
            .iter()
            .map(ToString::to_string)
            .filter(|d| d.starts_with('✗'))
            .collect::<Vec<_>>()
    };
    let before = run();
    assert_eq!(before.len(), 1, "{before:?}");
    // What `pub get` writes: a package config that maps `common` to a folder with the typedef.
    fs::create_dir_all(dir.path().join("common/lib")).unwrap();
    fs::write(
        dir.path().join("common/lib/json.dart"),
        "typedef JsonMap = Map<String, Object?>;\n",
    )
    .unwrap();
    fs::create_dir_all(dir.path().join(".dart_tool")).unwrap();
    fs::write(
        dir.path().join(".dart_tool/package_config.json"),
        r#"{"configVersion":2,"packages":[{"name":"common","rootUri":"../common","packageUri":"lib/","languageVersion":"3.9"}]}"#,
    )
    .unwrap();
    assert_eq!(run(), before);
}

#[test]
fn spellings_that_agree_read_no_file() {
    // Rule 1: a page and its data that spell the same type read no library at all.
    let page = product_page(
        "import '../../../models/product.dart';",
        ", required this.id, required this.product",
        "final int id; final Product product;",
    );
    let data = "import '../../../models/product.dart';\nFuture<Product> data(Ref ref, {required int id}) async => Product();";
    let files = with_models(&[
        ("products/$id/page.dart", &page),
        ("products/$id/data.dart", data),
    ]);
    let dir = project(&files);
    let app_dir = dir.path().join("lib/app");
    let cfg = Config::default();
    let mut diags = crate::diag::Diags::default();
    let tree = crate::scan::scan(&app_dir, &mut diags).unwrap();
    let libs = crate::enums::Libs::for_app(&app_dir, &cfg);
    let _ = crate::resolve::resolve(
        &tree,
        cfg.case_sensitive,
        cfg.remount,
        cfg.deferred,
        &libs,
        &mut diags,
    );
    let reads = libs.reads();
    assert!(
        reads.paths().iter().all(|p| !p.starts_with("lib/models/")),
        "{:?}",
        reads.paths()
    );
}

#[test]
fn show_and_hide_decide_which_typedef() {
    // `ProductView` is the models' typedef of `Product` unless the page hides it, in which case
    // the other library's `ProductView` (of `Item`) is the one it names.
    let other = "import '../../models/product.dart';\ntypedef ProductView = Item;\n";
    let page = "import '../../../models/ids.dart' hide ProductView;\nimport '../../../other/ids.dart';\nclass ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id, required this.data}); final int id; final ProductView data; }";
    let item = "import '../../../models/product.dart';\nFuture<Item> data(Ref ref, {required int id}) async => Item();";
    let product = "import '../../../models/product.dart';\nFuture<Product> data(Ref ref, {required int id}) async => Product();";
    let files = with_models(&[
        ("../other/ids.dart", other),
        ("products/$id/page.dart", page),
        ("products/$id/data.dart", item),
    ]);
    assert_eq!(messages(&files), Vec::<String>::new());
    let files = with_models(&[
        ("../other/ids.dart", other),
        ("products/$id/page.dart", page),
        ("products/$id/data.dart", product),
    ]);
    let e = messages(&files);
    assert!(
        e.iter()
            .any(|m| m.starts_with("`data` is ProductView but data.dart yields Product")),
        "{e:?}"
    );
}
