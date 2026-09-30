# trellis

File-tree routing for Flutter. You write tiny typed files under `lib/app/`, and a
generator checks the contracts between them and federates everything into one
mountable `lib/app.g.dart`. It's built on go_router, Riverpod and flutter_hooks,
with no build_runner.

```
lib/app/
  layout.dart            AppLayout extends Layout              → ShellRoute
  page.dart              HomePage extends Screen<Params>       → /
  loading.dart           RootLoading extends Loading<Params>     (inherited)
  error.dart             RootError extends ErrorView<Params>     (inherited)
  not_found.dart         NotFound extends NotFoundView
  products/
    data.dart            Future<List<Product>> data(Ref, Params)
    page.dart            ProductsPage extends Screen<List<Product>>  → /products
    loading.dart         ProductsLoading extends Loading<Params>
    $id/
      params.dart        ProductParams extends Params { final int id; }
      data.dart          Future<Product> data(Ref, ProductParams)
      page.dart          ProductPage extends Screen<Product>    → /products/:id
      error.dart         ProductError extends ErrorView<ProductParams>
  checkout/
    guard.dart           GuardResult guard(ProviderContainer, Params)
    page.dart
  greet/$name/page.dart  (no params.dart → generated GreetParams { String name })
  _components/           private: never routes
```

```dart
// the whole app entry point
MaterialApp.router(routerConfig: AppRoutes.router());

// or inside an existing GoRouter (brownfield)
GoRouter(routes: [...legacyRoutes, ...AppRoutes.mount(at: '/shop')]);

// typed navigation + data refresh, generated from the tree
ProductRoute(id: 42).go(context);
await const ProductsRoute().refresh(ref);
```

## File kinds

Each file exports exactly one symbol with a known base type. The generator wires
them together and nothing else.

| File | Exports | Contract |
|---|---|---|
| `page.dart` | `class X extends Screen<T>` | `T` = what `data.dart` yields, or the route's params if there's no `data.dart` |
| `data.dart` | `data(Ref ref, P params)` | returns `Future<T>`, `Stream<T>` or `T`; `P` ⊇ route params |
| `loading.dart` | `class X extends Loading<P>` | inherited by subfolders; `P` must fit every route it covers |
| `error.dart` | `class X extends ErrorView<P>` | inherited; gets `failure.error` and `failure.retry` |
| `layout.dart` | `class X extends Layout` | wraps this folder and below (ShellRoute) |
| `params.dart` | `class X extends <parent params>` | one `final` field per `$segment` up the path: `String`/`int`/`double`/`bool` |
| `guard.dart` | `GuardResult guard(ProviderContainer c, P params)` | `null` = allow, a location = redirect |
| `not_found.dart` | `class X extends NotFoundView` | root only; unknown paths and unparsable params (`/products/abc`) |

`Screen`, `Loading`, `ErrorView`, `Layout` and `NotFoundView` are all
`HookConsumerWidget`s, so `useState` and `ref.watch` work everywhere. Pages
are called `Screen` because Flutter already exports `Page<T>`.

**Params form a class hierarchy.** For example, `ItemParams extends OrderParams extends Params`.
Because of that, a `loading.dart` typed on `OrderParams` is valid for every route below it.
One typed on a narrower class is a generator error, not a runtime surprise.

## The generator

`cli/` is a standalone Rust binary. It's fast enough to run on every save:
a full scan, check and emit of the example takes under 1 ms.

```sh
cd cli && cargo build --release        # → cli/target/release/trellis

trellis gen                 # check lib/app/, write lib/app.g.dart
trellis watch               # same, on every change (keep it next to `flutter run`)
trellis check               # CI: non-zero exit on errors, writes nothing
trellis new 'products/[id]' --name Product --data --loading --error
                            # [id] or :id both mean $id, so no shell quoting of $
```

Errors are reported per file. When there are errors, `app.g.dart` is left untouched:

```
✗ products/loading.dart  loading view takes ProductParams, but it also covers products/ whose params are Params
✗ products/$id/params.dart:7  field `productId` has no `$productId` segment in this path
✗ products/$id/params.dart:4  missing field for segment `$id`
✗ products/$id/page.dart:6  Screen<List<Product>> but data.dart yields Product
```

`lib/app.g.dart` is plain go_router + Riverpod code that's meant to be read and committed.
It opens with a route table, see `examples/shop/lib/app.g.dart`. How it's put together:

- **Data** becomes a `FutureProvider.autoDispose.family` (or `StreamProvider`) keyed by the
  resolved path. Your params classes therefore never need `==`/`hashCode`.
- **Types** are inferred from your functions, never re-spelled. That's why the generator
  doesn't need to copy your imports.
- **Page-less folders** fold into their children's paths (`greet/$name` → `'greet/:name'`).
- **`AppRoutes.mount(at:)`** only changes the root path. Typed routes read `AppRoutes.base`,
  so `.location` stays correct when mounted under `/shop`.

## Run the example

```sh
cd examples/shop
flutter create . --platforms=android,ios,web   # adds platform folders only
flutter pub get
flutter run
```

Try `/products/13`: it fails once, so you see `error.dart` and **Retry**. Try `/products/abc`
(the int parse fails → `not_found.dart`), `/checkout` with an empty cart (the guard redirects
to `/cart`), and `/greet/you`.

## Status

This is a proof of concept.

- **Verified:** the generator has 15 tests covering lexing, every contract error, stream data,
  scaffolding, and that the committed `app.g.dart` is up to date. All Dart (runtime, example,
  generated and scaffolded files) parses cleanly with a Dart grammar.
- **Not yet verified:** a real `flutter analyze` / `flutter run`. The Dart parts were written
  against go_router 17, Riverpod 3 and flutter_hooks 0.21 docs but haven't been compiled.
  Expect to fix a few small API details on first run.
- **The generator reads Dart lexically, not with the analyzer.** It knows the shapes above.
  Anything unusual (e.g. a `typedef`'d return type) passes through, and the Dart compiler
  still catches mismatches in the generated code.

Next steps: query params in `params.dart`, `(group)` folders for layouts without URL
segments, per-route transitions, a `StatefulShellRoute` layout for tab bars, and
`dart format` on output.
