# fespalier

File-tree routing for Flutter, in the spirit of Next.js. An espalier is a tree
trained flat against a frame; here the frame is `lib/app/`.

You write plain widgets and functions in small files under `lib/app/`. There are no
base classes or interfaces to implement: the file name says what a file is, and its
constructor says what it needs. The `fsp` generator reads every file, works out what
each parameter should receive, checks that the files fit together, and writes one
mountable `lib/app.g.dart`. It's built on go_router, Riverpod and flutter_hooks,
with no build_runner.

```
lib/app/
  layout.dart            AppLayout({required Widget child})           → ShellRoute
  page.dart              HomePage()                                   → /
  loading.dart           RootLoading()                                  (inherited)
  error.dart             RootError({required Object error, required VoidCallback retry})
  not_found.dart         NotFound({required Uri uri})
  products/
    data.dart            final data = FutureProvider<List<Product>>(…)
    page.dart            ProductsPage({required List<Product> products})  → /products
    loading.dart         ProductsLoading()
    $id/
      data.dart          Future<Product> data(Ref ref, {required int id})
      page.dart          ProductPage({required Product product})       → /products/:id
      error.dart         ProductError({required int id, required Object error, …})
  checkout/
    guard.dart           GuardResult guard(ProviderContainer c)
    page.dart
  greet/$name/page.dart  GreetPage({required String name})
  _components/           private: never routes
```

```dart
// the whole app entry point
MaterialApp.router(routerConfig: AppRoutes.router());

// or inside an existing GoRouter (brownfield)
GoRouter(routes: [...legacyRoutes, ...AppRoutes.mount(at: '/shop')]);

// typed navigation, generated from the tree
ProductRoute(id: 42).go(context);

// each route's data.dart, as a Riverpod provider
ref.watch(ProductRoute.data(42));
await const ProductsRoute().refresh(ref);
```

## File kinds

Each view file exports one public widget class, of any kind: `StatelessWidget`,
`ConsumerWidget`, `HookConsumerWidget` and so on. Function files export one
top-level function.

| File | Exports | Its constructor / signature can ask for |
|---|---|---|
| `page.dart` | a widget | segments; what `data.dart` yields |
| `data.dart` | `data(Ref ref, {segments})` returning `Future<T>`, `Stream<T>` or `T` — **or** `final data = <Provider>(…)` | segments (named) |
| `loading.dart` | a widget, inherited by subfolders | segments |
| `error.dart` | a widget, inherited by subfolders | segments; `error`, `stackTrace`, `retry` |
| `layout.dart` | a widget; wraps this folder and below (ShellRoute) | `child`; segments at or above it |
| `guard.dart` | `GuardResult guard(ProviderContainer c, {segments})` | segments (named) |
| `not_found.dart` | a widget, root only; unknown paths and unparsable segments | `uri` |

### How parameters are filled

The generator reads each constructor (named or positional, `this.x` or typed) and fills
every parameter:

1. **By name.** A parameter named like a `$segment` in the path gets that segment.
   `data`, `child`, `error`, `stackTrace`, `retry` and `uri` get what their name says, in
   the files where they make sense.
2. **By type.** Otherwise, a page's parameter whose type is what `data.dart` yields gets
   the data, so `final Product product;` works. An error view's `Object` gets the error,
   `StackTrace` the stack trace and `VoidCallback` the retry. A layout's `Widget` gets the
   child, and not-found's `Uri` gets the URI.
3. **Otherwise**, a required parameter is a generator error pointing at it. An optional
   one is left to its default.

These names are reserved, so segments can't use them.

### Segment types

A segment's type comes from the parameters that ask for it: `{required int id}` in
`products/$id/data.dart` makes `$id` an `int` everywhere. That covers the typed
`ProductRoute(id: 42)`, the page, and parsing: `/products/abc` goes to `not_found.dart`.
Every file that asks for `$id` must agree on its type. When nobody gives one, a segment
is a `String`. Segments are `String`, `int`, `double` or `bool`.

### `data.dart`: a function or a provider

Write a function and fespalier wraps it in an autoDispose `FutureProvider` (or
`StreamProvider` for a `Stream`). Or export a provider named `data` yourself:
`FutureProvider`, `StreamProvider`, `AsyncNotifierProvider` or `StreamNotifierProvider`,
with its type arguments spelled out. It's used as-is.

Either way, the route exposes it as `XRoute.data`, keyed by the segments `data.dart`
uses:

| Segments used | Provider | Watch it with |
|---|---|---|
| none | plain | `ref.watch(ProductsRoute.data)` |
| one | `.family<T, int>` | `ref.watch(ProductRoute.data(42))` |
| several | `.family<T, ({String shop, int id})>` | `ref.watch(ItemRoute.data((shop: 'a', id: 1)))` |

A family provider you write yourself follows the same rule. With several segments, its
argument is a record naming the ones it uses.

## The generator

`cli/` is a Rust binary, `fsp`. A full scan, check and emit of an example runs in a few
milliseconds, fast enough to run on every save.

```sh
cd cli && cargo build --release        # → cli/target/release/fsp

fsp gen                 # check lib/app/, write lib/app.g.dart
fsp watch               # same, on every change (keep it next to `flutter run`)
fsp check               # CI: non-zero exit on errors, writes nothing
fsp new 'products/[id]' --name Product --data --loading --error --layout --guard
                        # [id] or :id both mean $id, so no shell quoting of $
```

Errors point at the parameter or declaration at fault, and `app.g.dart` is left
untouched while there are any:

```
error: can't fill `label`: it isn't a segment of this path ($shop, $id) or data.dart's String
  ┌─ lib/app/shops/$shop/items/$id/page.dart:6:18
  │
6 │   const ItemPage(this.label, {super.key});
  │                  ^^^^^^^^^^

error: `$id` is int in products/$id/data.dart:6 but String here
```

It's built on existing libraries rather than hand-rolled parts:

- [tree-sitter](https://tree-sitter.github.io/) with
  [tree-sitter-dart](https://github.com/nielsenko/tree-sitter-dart) parses Dart.
- [minijinja](https://github.com/mitsuhiko/minijinja) renders the output. The shape of
  `app.g.dart` and of every scaffolded file lives in `cli/templates/`.
- [codespan-reporting](https://github.com/brendanzab/codespan) renders diagnostics.
- [clap](https://github.com/clap-rs/clap) handles the command line, and
  [notify-debouncer-mini](https://github.com/notify-rs/notify) drives `watch`.

`lib/app.g.dart` is plain go_router + Riverpod code that's meant to be read and committed.
It opens with a route table (see `examples/shop/lib/app.g.dart`). Some details:

- **Types are never re-spelled.** The generator doesn't copy your imports. Values flow
  through inference, and each route's provider is a `static final` whose type is inferred.
- **Segments are parsed into a record** (`({int id})`). Records compare by value, so
  providers are keyed by the segments directly.
- **Page-less folders** fold into their children's paths (`greet/$name` → `'greet/:name'`).
- **`AppRoutes.mount(at:)`** only changes the root path. Typed routes read `AppRoutes.base`,
  so `.location` stays correct when mounted under `/shop`.

## Run the examples

```sh
cd examples/shop
flutter create . --platforms=android,ios,web   # adds platform folders only
flutter pub get
flutter run
```

Try `/products/13`: it fails once, so you see `error.dart` and **Retry**. Try `/products/abc`
(the int parse fails → `not_found.dart`), `/checkout` with an empty cart (the guard redirects
to `/cart`), and `/greet/you`.

`examples/features` covers the rest: data keyed by two segments, a page and error view
bound by type, a layout and guard that take segments, a user-written
`AsyncNotifierProvider`, and `Stream` data.

## Development

```
cli/                 the generator (Rust): scan → resolve/check → emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
packages/fespalier/  the runtime app.g.dart imports (DataView, segment parsing, TypedLocation)
examples/shop/       end-to-end example; its lib/app.g.dart is committed
examples/features/   every binding rule, with widget tests
```

```sh
(cd cli && cargo test && cargo clippy --all-targets)
(cd cli && cargo run -- check --project ../examples/shop)
(cd packages/fespalier && flutter pub get && flutter analyze && flutter test)
(cd examples/shop && flutter pub get && flutter analyze && flutter test)
(cd examples/features && flutter pub get && flutter analyze && flutter test)
```

CI (`.github/workflows/ci.yml`) runs all of the above. It also scaffolds every file kind
with `fsp new` and runs `flutter analyze` on the result. After changing the emitter or a
template, regenerate with `cargo run -- gen --project ../examples/<name>`. A test fails if
a committed `app.g.dart` is stale.

## Status

This is an early version.

- **Generator:** 20 tests cover parsing, every binding rule and contract error, both
  data forms, scaffolding, and that the committed outputs are up to date. Clippy is clean.
- **Runtime + examples:** `flutter analyze` is clean on Flutter 3.47 (go_router 17,
  hooks_riverpod 3, flutter_hooks 0.21). The widget tests in both examples drive the
  generated router through every file kind.
- **Types are compared by spelling, not resolved.** The generator reads a syntax tree,
  not the Dart analyzer, so `Product` and a `typedef` of it count as different types. The
  Dart compiler still catches real mismatches in the generated code.

Things to know:

- Pages render below their `layout.dart`, so a layout's `Scaffold` is not their nearest
  `Material` during page transitions. Wrap `ListTile`-heavy pages in
  `Material(type: MaterialType.transparency, …)`, as `products/page.dart` does.
- go_router builds the whole matched stack, so `/products/abc` also loads `/products`
  underneath the not-found view.

Next steps: query parameters, `(group)` folders for layouts without URL segments,
per-route transitions, a `StatefulShellRoute` layout for tab bars, and go_router 18.
