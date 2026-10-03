# The examples, and working in the repository

As of v0.4.0 (`examples/` in the fespalier repository). Read them before inventing a
pattern: they compile, have widget tests, and every `lib/app.g.dart` in them is committed.
A test in the repository fails if a committed `app.g.dart` is stale.

| Example             | What it is, and what to read it for                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `examples/minimal`  | The smallest real app: `flutter create` plus `fsp init` plus three pages (a class page, a function page `Widget page()`, and a `$id` page with a query parameter, a `data.dart`, `loading.dart` and `error.dart`). Its README walks through each file and how it was made. **Start here.** Added in 0.4.0                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `examples/shop`     | An end-to-end shop: products with `data.dart`, a `checkout` guard that sends an empty cart to `/cart`, `/greet/$name`, an `error.dart` with Retry (`/products/13` fails once), `/products/abc` going to `not_found.dart`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `examples/features` | Almost every binding rule, with widget tests: an `(account)` group beside a catch-all `$slug`, per-route transitions, data keyed by two segments, query parameters in a page, `data.dart` and a layout, a user-written `AsyncNotifierProvider`, `Stream` data, a `teams/$teamId` **section** with a two-level `not_found.dart`, a query-keyed `reports` section, enum segments and catch-alls (`shop/$category`, `browse/$$categories`), typed catch-alls (`compare/$$ids`), `route.dart` case per folder (`files/`), **localized paths** (`help/`, `guide/` with non-ASCII spellings, `shop/`), guards in a page-less `(members)` group with a login that returns, two `redirect.dart` routes, dialogs, a sheet and a full-screen dialog under `/photos`, an app-owned sheet through `present.dart` (`/photos/share`), `meta.dart` read by the root layout for page titles, function views (`(plans)/free`, `(plans)/pro`), `extra` read by a layout and a guard, a `nest = false` sibling with a compound path (`orders/$id/refund/confirm`, beside `refund/receipt`, which nests), `action.dart` writes (a refund form on `orders/$id/refund`, an `addMember` on the `teams/$teamId` section), scroll restoration on the browser's back and forward (`feed/`, since 0.8.1), and `AppRoutes.dataAt`/`match`/prefetch tests |
| `examples/tabs`     | A tab layout: four tabs (one with nested pages, and a Library tab that is a tab layout of its own), a counter that survives switching tabs, `tabOptions`, a cross-fading `container`, a Search tab that also answers `/recherche`, a full-screen `/settings`, `/profile/edit` on the root navigator (`navigator.dart`), a Cupertino root `transition.dart` that also moves the shell aside, `extra_codec.dart`, an `output_manifest` library, and restoration tests                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

Since 0.8.1 `minimal`, `shop` and `features` run the generated `main()` (`lib/main.dart` is
`Future<void> main() => AppMain.run();`, with `lib/app/app.dart`; `features` also has `startup.dart`,
`splash.dart` and a `zone()`, and tests them in `test/startup_test.dart`), and `tabs` keeps a `main()`
of its own. See [`app-main.md`](app-main.md).

The examples nest `material_ui`'s `MaterialApp` around `MaterialApp.router` in their tests
so they pass on both go_router 17 and 18; with the root `transition.dart` that `fsp init`
writes you do not need that (`pumpRouter` uses Flutter's `MaterialApp`).

## Running one

```sh
cd examples/shop
flutter create . --platforms=android,ios,web   # adds platform folders only
flutter pub get
flutter run
```

## Working on fespalier itself

```text
cli/                 the generator (Rust): scan, resolve/check, emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
editors/vscode/      the VS Code extension (TypeScript)
editors/intellij/    the IntelliJ / Android Studio plugin (Kotlin)
scripts/             packaging and checksum pinning for releases
packages/fespalier/  the runtime app.g.dart imports, testing.dart, bin/fespalier.dart
examples/            minimal, shop, features, tabs
```

```sh
(cd cli && cargo test && cargo clippy --all-targets -- -D warnings)
(cd cli && cargo run -- check --project ../examples/minimal)
(cd packages/fespalier && flutter pub get && flutter analyze && flutter test)
(cd examples/minimal && flutter pub get && flutter analyze && dart format --set-exit-if-changed . && flutter test)
```

After changing the emitter or a template, regenerate the committed outputs with
`cargo run -- gen --project ../examples/<name>`. CI also checks that the version agrees
everywhere it is spelled out (`cli/tests/versions.rs`): `cli/Cargo.toml`, the package's
`pubspec.yaml`, the `ref:` that `fsp init` prints and the READMEs' `ref:`, `--tag` and
`FSP_VERSION`; **a release bumps those together**. The repository's `main` later moved to
release-please for that; follow whatever `README.md` "Releasing" says on the branch you are
on.

## Design notes worth knowing

- **`watch` and `read` are static** on a typed route, `prefetch` and `refresh` instance
  members: an instance member returning `AsyncValue<Product>` would make the generated file
  name `Product`, and it never copies your imports (`fespalier-data`).
- **A localized path is one `GoRoute` with an alternation**, not a redirect per spelling and
  not a route per spelling, so the URL, page keys, restoration ids and the tab stack see a
  single route (`fespalier-routing`).
- **The generated file never re-spells your types**, except a typed `extra` and enums, which
  it imports by name.
