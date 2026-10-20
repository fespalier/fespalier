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
type Seen = HashMap<(String, Option<String>, String), (String, Option<String>)>;

#[derive(Default)]
struct Fake(Seen);

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
fn two_prefixes_of_a_name_nothing_declares_are_two_types() {
    // `api.User` and `db.User` come from two other packages, which fsp does not read: they are
    // compared as spelled, prefix and all (the bare name is what the hint reports).
    let f = models();
    let (api, db) = (canon(&f, PAGE, "api.User"), canon(&f, PAGE, "db.User"));
    assert_eq!(api.key, "api.User");
    assert_eq!(api.expanded, "User");
    assert_eq!(api.unknown, ["User"]);
    assert_ne!(api.key, db.key);
    assert_eq!(api.key, canon(&f, PAGE, "api.User").key);
    assert_eq!(canon(&f, PAGE, "List<api.User>?").key, "List<api.User>?");
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
             typedef Count = int;\n\
             typedef Tags = List<String>;\n\
             typedef Ids = List<int>;\n\
             typedef Cats = List<Category>;\n\
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
        "import '../../models/product.dart';\nFuture<Product> data(Ref ref) async => Product();";
    let typedef_page = product_page(
        "import '../../models/ids.dart';",
        ", required this.data",
        "final ProductView data;",
    );
    let prefix_page = product_page(
        "import '../../models/product.dart' as m;",
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
        "import '../../models/ids.dart';",
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
        "import '../../models/product.dart';\nFuture<Product> data(Ref ref) async => Product();";
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
fn a_catch_all_typed_with_a_typedef_of_a_list_is_that_list() {
    let page = |ty: &str| {
        product_page(
            "import '../../../models/ids.dart';",
            ", required this.ids",
            &format!("final {ty} ids;"),
        )
    };
    let data = "Future<int> data(Ref ref, {required List<int> ids}) async => ids.length;";
    let (by_typedef, by_list) = (page("Ids"), page("List<int>"));
    let with_typedef = with_models(&[
        ("c/$$ids/page.dart", &by_typedef),
        ("c/$$ids/data.dart", data),
    ]);
    assert_eq!(messages(&with_typedef), Vec::<String>::new());
    let c = code(&with_typedef);
    // The typedef is the list it names: the typed route's field and the parser are the list's.
    let spelled = code(&with_models(&[
        ("c/$$ids/page.dart", &by_list),
        ("c/$$ids/data.dart", data),
    ]));
    has(&c, &["final List<int> ids;", "Segment.asIntRest(s, 'ids')"]);
    lacks(&c, &["final Ids", "Ids ids"]);
    assert_eq!(
        c.lines()
            .filter(|l| !l.contains("_version"))
            .collect::<Vec<_>>(),
        spelled
            .lines()
            .filter(|l| !l.contains("_version"))
            .collect::<Vec<_>>()
    );
    // A typedef of a list of an enum is not a catch-all type fsp can parse: the old error.
    let cats = page("Cats");
    let e = messages(&with_models(&[("c/$$ids/page.dart", &cats)]));
    assert!(
        e.iter()
            .any(|m| m.starts_with("`Cats ids`: a catch-all segment is the rest of the path")),
        "{e:?}"
    );
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

/// A page and a data.dart under `shop/`, the page with the constructor and fields given and the
/// data yielding `yields`.
fn shop(ctor: &str, fields: &str, yields: &str) -> Vec<(&'static str, String)> {
    let imports = "import '../../models/ids.dart';\nimport '../../models/product.dart';\n";
    let page = format!("{imports}{}", widget("ShopPage", fields, ctor));
    let data = format!("{imports}Future<{yields}> data(Ref ref) async => throw 0;");
    vec![("shop/page.dart", page), ("shop/data.dart", data)]
}

fn borrowed<'a>(files: &'a [(&'static str, String)]) -> Vec<(&'static str, &'a str)> {
    files.iter().map(|(p, s)| (*p, s.as_str())).collect()
}

#[test]
fn a_page_that_spells_what_its_data_yields_gets_the_data_not_a_query_parameter() {
    // Rule 1, spelling first: a page and its data.dart that spell one type alike are bound by
    // that spelling, as before 0.21.0, even when the type is a typedef of a query type. (The
    // typedef is followed to a query parameter only when no spelling binds.)
    for (ctor, fields, yields, param) in [
        (", this.tags = const []", "final Tags tags;", "Tags", "tags"),
        (", this.count", "final Count? count;", "Count?", "count"),
        (", this.cat", "final Cat? cat;", "Cat?", "cat"),
    ] {
        let files = shop(ctor, fields, yields);
        let files = with_models(&borrowed(&files));
        assert_eq!(
            crate::action_tests::diags(&files),
            Vec::<String>::new(),
            "{yields}"
        );
        let c = code(&files);
        has(&c, &[&format!(".ShopPage({param}: d)")]);
        lacks(
            &c,
            &[&format!("RouteParam('{param}'"), &format!("v.{param}")],
        );
    }
}

#[test]
fn an_enum_spelled_as_it_is_declared_is_still_a_query_parameter_before_the_data() {
    // Unchanged from before 0.21.0: an enum found by its own name is a query parameter, even when
    // data.dart yields it.
    let files = shop(", this.category", "final Category? category;", "Category?");
    let c = code(&with_models(&borrowed(&files)));
    has(&c, &["RouteParam('category'"]);
}

#[test]
fn extra_through_a_typedef_fits() {
    let guard = "import '../../models/ids.dart';\nGuardResult guard(ProviderContainer c, {ProductView? extra}) => null;";
    let page = "import '../../models/product.dart';\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, this.extra}); final Product? extra; }";
    let files = with_models(&[("shop/guard.dart", guard), ("shop/page.dart", page)]);
    assert_eq!(messages(&files), Vec::<String>::new());
}

/// A page under `u/` that takes `ty` as `name`, over a data.dart that yields `yields`; both reach
/// other packages' `User` through a prefix.
fn user_page(prefix: &str, name: &str) -> String {
    format!(
        "import 'package:{prefix}/models.dart' as {prefix};\n{}",
        widget(
            "UPage",
            &format!("final {prefix}.User {name};"),
            &format!(", required this.{name}")
        )
    )
}

#[test]
fn one_class_name_from_two_packages_is_two_types() {
    // Two prefixes of two packages that fsp does not read, for the same bare name: not one type,
    // as before 0.21.0 (the prefix was dropped from the key, so they compared equal).
    let data =
        "import 'package:db/models.dart' as db;\nFuture<db.User> data(Ref ref) async => db.User();";
    let by_type = user_page("api", "user");
    let e = messages(&[("u/page.dart", &by_type), ("u/data.dart", data)]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("can't fill `user`"), "{e:?}");
    // A parameter called `data` is the data, and says what it is.
    let named = user_page("api", "data");
    let e = messages(&[("u/page.dart", &named), ("u/data.dart", data)]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].starts_with("`data` is api.User but data.dart yields db.User"),
        "{e:?}"
    );
    // The same package under the same prefix is the one type.
    let same = "import 'package:api/models.dart' as api;\nFuture<api.User> data(Ref ref) async => api.User();";
    assert_eq!(
        messages(&[("u/page.dart", &named), ("u/data.dart", same)]),
        Vec::<String>::new()
    );
}

#[test]
fn the_extra_of_two_packages_classes_of_one_name_clashes() {
    let guard = "import 'package:api/models.dart' as api;\nGuardResult guard(ProviderContainer c, {api.User? extra}) => null;";
    let page = "import 'package:db/models.dart' as db;\nclass UPage extends StatelessWidget { const UPage({super.key, this.extra}); final db.User? extra; }";
    let e = messages(&[("u/guard.dart", guard), ("u/page.dart", page)]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].starts_with("`extra` is `api.User?` here, but the routes it covers take other types"),
        "{e:?}"
    );
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
    let action = "import '../../models/ids.dart';\nimport '../../models/product.dart';\n\
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
fn an_optimistic_patch_goes_to_the_data_that_spells_its_type_before_one_that_means_it() {
    // Two data.dart files that the action invalidates give one type, `Product` (b/ as it is
    // spelled in action.dart) and `m.Product` (a/, the same class through a prefix). The patch
    // goes to the exact spelling, b/, as before 0.21.0, and not to the first of the two.
    let (a_page, b_page) = (
        "class APage extends StatelessWidget { const APage({super.key}); }",
        "class BPage extends StatelessWidget { const BPage({super.key}); }",
    );
    let a_data = "import '../../models/product.dart' as m;\nFuture<m.Product> data(Ref ref) async => m.Product();";
    let b_data =
        "import '../../models/product.dart';\nFuture<Product> data(Ref ref) async => Product();";
    let action = "import 'package:demo/app.g.dart';\nimport '../../models/product.dart';\n\
        const invalidates = [ARoute, BRoute];\n\
        Product optimistic(Product current, String input) => current;\n\
        Future<void> action(Ref ref, {required String input}) async {}\n";
    let c = code(&with_models(&[
        ("page.dart", HOME),
        ("a/page.dart", a_page),
        ("a/data.dart", a_data),
        ("a/action.dart", action),
        ("b/page.dart", b_page),
        ("b/data.dart", b_data),
    ]));
    has(&c, &["final _optimisticB = optimisticLayer(_dataB);"]);
    lacks(&c, &["_optimisticA"]);
    // With no exact spelling, the first that means it is the target.
    let only_prefixed = c_without_exact([a_page, b_page], a_data, action);
    has(
        &only_prefixed,
        &["final _optimisticA = optimisticLayer(_dataA);"],
    );
}

/// The same app with b/ yielding a typedef of `Product`, so no data.dart spells it as action.dart does.
fn c_without_exact(pages: [&str; 2], a_data: &str, action: &str) -> String {
    let b_data =
        "import '../../models/ids.dart';\nFuture<ProductView> data(Ref ref) async => throw 0;";
    code(&with_models(&[
        ("page.dart", HOME),
        ("a/page.dart", pages[0]),
        ("a/data.dart", a_data),
        ("a/action.dart", action),
        ("b/page.dart", pages[1]),
        ("b/data.dart", b_data),
    ]))
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

/// Resolves the app of `files` (under `lib/app/`, with `../models/...` for `lib/models/...`) and
/// returns the project paths it read from disk and the lookup work it did: libraries parsed and
/// libraries searched for a declaration.
fn lookups(files: &[(&str, &str)]) -> (Vec<String>, (usize, usize)) {
    let dir = project(files);
    let app_dir = dir.path().join("lib/app");
    let cfg = Config::default();
    let mut diags = crate::diag::Diags::default();
    let tree = crate::scan::scan(&app_dir, &mut diags).unwrap();
    let libs = crate::enums::Libs::for_app(&app_dir, &cfg);
    let before = crate::enums::work();
    let _ = crate::resolve::resolve(
        &tree,
        cfg.case_sensitive,
        cfg.remount,
        cfg.deferred,
        &libs,
        &mut diags,
    );
    let after = crate::enums::work();
    let reads = libs
        .reads()
        .paths()
        .iter()
        .map(ToString::to_string)
        .collect();
    (
        reads,
        (after.parses - before.parses, after.probes - before.probes),
    )
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
    let (reads, work) = lookups(&files);
    assert!(
        reads.iter().all(|p| !p.starts_with("lib/models/")),
        "{reads:?}"
    );
    assert_eq!(work, (0, 0));
}

/// `pages` pages that each import a barrel of `files` model files and have two parameters that
/// nothing binds (`EdgeInsets padding = ...`, `VoidCallback? onTap`), and the barrel.
fn barrel_app(pages: usize, files: usize) -> Vec<(String, String)> {
    let mut out = vec![("page.dart".to_string(), HOME.to_string())];
    let exports: String = (0..files)
        .map(|k| format!("export 'm{k}.dart';\n"))
        .collect();
    out.push(("../models/all.dart".into(), exports));
    for k in 0..files {
        let body = format!("class Model{k} {{}}\nclass Other{k} {{ final int id = {k}; }}\n");
        out.push((format!("../models/m{k}.dart"), body));
    }
    for i in 0..pages {
        let page = format!(
            "import 'package:demo/models/all.dart';\n{}",
            widget(
                &format!("P{i}Page"),
                "final EdgeInsets padding; final VoidCallback? onTap;",
                ", this.padding = EdgeInsets.zero, this.onTap"
            )
        );
        out.push((format!("p{i}/page.dart"), page));
    }
    out
}

fn barrel_lookups(pages: usize, files: usize) -> (Vec<String>, (usize, usize)) {
    let app = barrel_app(pages, files);
    let app: Vec<(&str, &str)> = app.iter().map(|(p, s)| (p.as_str(), s.as_str())).collect();
    lookups(&app)
}

#[test]
fn a_barrel_is_read_and_searched_once_however_many_pages_import_it() {
    // Parameters nothing binds are looked up (is `EdgeInsets` a typedef of a query type?), and
    // every page imports the barrel. The barrel is walked once per name, not once per page: the
    // work a page adds does not depend on how many files the barrel exports (it used to grow with
    // pages times files), only the barrel is parsed, and each file is read once.
    let (reads, (parses, probes)) = barrel_lookups(3, 10);
    let mut want: Vec<String> = (0..10).map(|k| format!("lib/models/m{k}.dart")).collect();
    want.push("lib/models/all.dart".into());
    want.sort();
    assert_eq!(reads, want);
    assert_eq!(parses, 1, "only the barrel is parsed");
    let per_page = |files: usize| {
        let (_, (p3, a)) = barrel_lookups(3, files);
        let (_, (p12, b)) = barrel_lookups(12, files);
        assert_eq!((p3, p12), (1, 1));
        (b - a) / 9
    };
    let (few, many) = (per_page(10), per_page(40));
    assert_eq!(few, many, "a page's lookups do not walk the barrel again");
    let (_, (_, probes_12_40)) = barrel_lookups(12, 40);
    assert!(
        probes_12_40 < 12 * 40,
        "{probes_12_40} probes; {probes} for 3x10"
    );
}

#[test]
fn show_and_hide_decide_which_typedef() {
    // `ProductView` is the models' typedef of `Product` unless the page hides it, in which case
    // the other library's `ProductView` (of `Item`) is the one it names.
    let other = "import '../models/product.dart';\ntypedef ProductView = Item;\n";
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

// --- fsp's verdict against the Dart analyzer (since 0.21.0) -------------------------------------

/// The probe's models: the typedefs that the cases below spell, in files the probe's `lib/` holds.
const PROBE_FILES: [(&str, &str); 5] = [
    (
        "lib/models/product.dart",
        "class Product {}\nclass Item {}\nenum Category { shoes, hats }\n",
    ),
    (
        "lib/models/ids.dart",
        "import 'product.dart';\nimport 'product.dart' as p;\n\
         typedef ProductView = Product;\ntypedef Chain = ProductView;\n\
         typedef Prefixed = p.Item;\ntypedef ProductId = int;\ntypedef MaybeInt = int?;\n\
         typedef Json = Map<String, Object?>;\ntypedef PayFields = ({int amount, String note});\n\
         typedef Retry = void Function();\ntypedef Cat = Category;\n\
         typedef Generic<T> = Map<String, T>;\n",
    ),
    (
        "lib/models/all.dart",
        "export 'product.dart' show Product, Category;\nexport 'ids.dart' hide Json;\n",
    ),
    (
        "lib/other/ids.dart",
        "import '../models/product.dart';\ntypedef ProductView = Item;\n",
    ),
    ("lib/other/product.dart", "class Product {}\n"),
];

/// One case of the table: the imports of `lib/app/c<n>/page.dart`, the two types, the line the
/// page adds after `f`, what fsp says (`same`) and what the analyzer says (`same`).
struct Case {
    n: usize,
    imports: &'static str,
    a: &'static str,
    b: &'static str,
    extra: &'static str,
    fsp_same: bool,
    analyzer_same: bool,
}

const PROBE_IDS: &str = "import '../../models/ids.dart';\n";
const PROBE_BOTH: &str = "import '../../models/ids.dart';\nimport '../../models/product.dart';\n";

fn probe_cases() -> Vec<Case> {
    let case = |n, imports, a, b, fsp_same, analyzer_same| Case {
        n,
        imports,
        a,
        b,
        extra: "",
        fsp_same,
        analyzer_same,
    };
    vec![
        case(
            1,
            "import '../../models/product.dart';\ntypedef Local = Product;\n",
            "Local",
            "Product",
            true,
            true,
        ),
        case(2, PROBE_BOTH, "ProductView", "Product", true, true),
        case(
            3,
            "import 'package:probe/models/all.dart';\n",
            "ProductView",
            "Product",
            true,
            true,
        ),
        case(
            4,
            "import '../../models/ids.dart' as ids;\nimport '../../models/product.dart' as m;\n",
            "ids.ProductView",
            "m.Product",
            true,
            true,
        ),
        case(5, PROBE_BOTH, "Chain", "Product", true, true),
        case(6, PROBE_IDS, "List<ProductId>", "List<int>", true, true),
        case(
            7,
            PROBE_IDS,
            "Map<String, Json>",
            "Map<String, Map<String, Object?>>",
            true,
            true,
        ),
        case(8, PROBE_IDS, "MaybeInt", "int?", true, true),
        case(9, PROBE_IDS, "MaybeInt?", "int?", true, true),
        case(
            10,
            PROBE_IDS,
            "PayFields",
            "({int amount, String note})",
            true,
            true,
        ),
        case(11, PROBE_IDS, "Retry", "void Function()", true, true),
        case(
            12,
            "import '../../models/ids.dart' hide ProductView;\nimport '../../other/ids.dart';\nimport '../../models/product.dart';\n",
            "ProductView",
            "Item",
            true,
            true,
        ),
        case(
            13,
            "import '../../models/ids.dart' show ProductId;\nimport '../../models/product.dart';\n",
            "ProductView",
            "Product",
            false,
            false,
        ),
        case(14, PROBE_BOTH, "ProductView", "Item", false, false),
        case(15, PROBE_IDS, "ProductId", "String", false, false),
        case(16, PROBE_IDS, "List<ProductId>", "List<num>", false, false),
        case(
            17,
            "import '../../models/product.dart' as m;\nimport '../../other/product.dart' as o;\n",
            "m.Product",
            "o.Product",
            false,
            false,
        ),
        Case {
            extra: "Object use() => [Cat.values.byName('shoes'), Cat.shoes, Cat.values];\n",
            ..case(18, PROBE_BOTH, "Cat", "Category", true, true)
        },
        // Analyzer: the same (a generic typedef is not followed by fsp: the one allowed disagreement).
        case(
            19,
            PROBE_IDS,
            "Generic<int>",
            "Map<String, int>",
            false,
            true,
        ),
        case(20, PROBE_BOTH, "Prefixed", "Item", true, true),
        case(
            21,
            "import 'package:probe/models/all.dart';\nimport '../../models/ids.dart' as i;\n",
            "Json",
            "Map<String, Object?>",
            false,
            false,
        ),
        case(
            22,
            "import '../../models/product.dart';\nimport '../../models/product.dart' as m;\n",
            "m.Product",
            "Product",
            true,
            true,
        ),
    ]
}

/// `lib/app/c<n>/page.dart`: the imports, then `f`, which assigns each type to the other.
fn probe_page(c: &Case) -> String {
    if c.a.is_empty() {
        return format!("{}{}", c.imports, c.extra);
    }
    format!(
        "{}\nvoid f({} a, {} b) {{\n  {} x = a;\n  {} y = b;\n  print([x, y]);\n}}\n{}",
        c.imports, c.a, c.b, c.b, c.a, c.extra
    )
}

/// The files of the analyzer probe: `lib/` as `PROBE_FILES`, the cases and no `pub get`.
fn probe_project(cases: &[Case]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: probe\nenvironment:\n  sdk: ^3.9.0\n",
    )
    .unwrap();
    fs::create_dir_all(dir.path().join(".dart_tool")).unwrap();
    fs::write(
        dir.path().join(".dart_tool/package_config.json"),
        r#"{"configVersion":2,"packages":[{"name":"probe","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}]}"#,
    )
    .unwrap();
    for (rel, body) in PROBE_FILES {
        let p = dir.path().join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    for c in cases {
        let p = dir.path().join(format!("lib/app/c{}/page.dart", c.n));
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, probe_page(c)).unwrap();
    }
    dir
}

/// Whether the Dart analyzer reports no error in each case's page, or `None` when it can't run.
fn analyzer_verdicts(dir: &std::path::Path, cases: &[Case]) -> Option<Vec<bool>> {
    let dart = std::env::var("FSP_DART").unwrap_or_else(|_| "dart".into());
    let out = std::process::Command::new(dart)
        .args(["analyze", "--format=machine", "lib"])
        .current_dir(dir)
        .output()
        .ok()?;
    let report = String::from_utf8_lossy(&out.stdout).to_string();
    let errors: Vec<&str> = report.lines().filter(|l| l.starts_with("ERROR|")).collect();
    Some(
        cases
            .iter()
            .map(|c| {
                let page = format!("/c{}/page.dart|", c.n);
                !errors.iter().any(|l| {
                    l.split('|')
                        .nth(3)
                        .is_some_and(|f| f.ends_with(page.trim_end_matches('|')))
                })
            })
            .collect(),
    )
}

#[test]
fn follows_typedefs_as_the_analyzer_does() {
    let mut cases = probe_cases();
    // Case 23: an enum alias is a static access through the typedef, and an import prefix of
    // its own; the analyzer must compile it (no fsp verdict: it is what `app.g.dart` writes).
    cases.push(Case {
        n: 23,
        imports: "// ignore_for_file: unused_shown_name\nimport '../../models/ids.dart' show Cat;\nimport '../../models/ids.dart' as _e1;\n",
        a: "",
        b: "",
        extra: "Object use() => [Cat.values.byName('shoes'), Cat.shoes, Cat.values, _e1.Cat.values];\nfinal Cat first = Cat.values.first;\n",
        fsp_same: false,
        analyzer_same: true,
    });
    let dir = probe_project(&cases);
    // fsp's column, through the same canonical form the resolver uses: it needs no dart, so it is
    // asserted on every machine.
    let app = dir.path().join("lib/app");
    let libs = crate::enums::Libs::for_app(&app, &Config::default());
    let mut fsp_says = vec![];
    for c in &cases {
        if c.n == 23 {
            fsp_says.push(false);
            continue;
        }
        let file = format!("c{}/page.dart", c.n);
        let src = probe_page(c);
        let fsp_same = libs.canonical(&file, &src, c.a).key == libs.canonical(&file, &src, c.b).key;
        assert_eq!(fsp_same, c.fsp_same, "case {}: fsp's verdict", c.n);
        // fsp never says "same" where the analyzer says "different" (as the table has it).
        assert!(!fsp_same || c.analyzer_same, "case {}", c.n);
        fsp_says.push(fsp_same);
    }
    // The analyzer's column, for the cases it decides, and fsp against what it really says.
    let Some(compiles) = analyzer_verdicts(dir.path(), &cases) else {
        let required = std::env::var("FSP_REQUIRE_DART").is_ok_and(|v| v == "1");
        assert!(
            !required,
            "dart is required (FSP_REQUIRE_DART=1) and is not on PATH"
        );
        return;
    };
    for ((c, same), fsp_same) in cases.iter().zip(&compiles).zip(&fsp_says) {
        if c.n == 23 {
            assert!(same, "case 23 must compile");
            continue;
        }
        assert_eq!(
            *same, c.analyzer_same,
            "case {}: the analyzer's verdict",
            c.n
        );
        assert!(
            !fsp_same || *same,
            "case {}: fsp says same, the analyzer says different",
            c.n
        );
    }
}
