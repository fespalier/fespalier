---
layout: home
title: fespalier
titleTemplate: File-tree routing for Flutter

hero:
  name: fespalier
  text: File-tree routing for Flutter
  tagline: In the spirit of Next.js. An espalier is a tree trained flat against a frame; here the frame is lib/app/.
  image:
    src: /logo.svg
    alt: fespalier
  actions:
    - theme: brand
      text: Get started
      link: /getting-started
    - theme: alt
      text: File kinds
      link: /file-kinds
    - theme: alt
      text: View on GitHub
      link: https://github.com/fespalier/fespalier

features:
  - title: Files are routes
    details: Plain widgets and functions in small files under lib/app/. No base classes or interfaces to implement — the file name says what a file is, and its constructor says what it needs.
    link: /file-kinds
    linkText: File kinds
  - title: One typed entry point
    details: The fsp generator reads every file and writes one typed, mountable lib/app.g.dart. An error points at the parameter at fault, and app.g.dart is left untouched while there is one.
    link: /navigation
    linkText: Typed navigation
  - title: go_router, Riverpod, flutter_hooks
    details: The generated file is typed go_router routes and Riverpod providers, with no build_runner. Use it with MaterialApp.router, or mount it inside a GoRouter you already have with AppRoutes.mount(at:).
    link: /migration
    linkText: Adopting fespalier
  - title: Companion packages
    details: Packages for authentication, forms, HTTP clients, responsive images, translations, maps, downloads, push, analytics and telemetry. Many plug into the generated main() as adapters, with one line in pubspec.yaml.
    link: /adapters
    linkText: Adapters
---

You write plain widgets and functions in small files under `lib/app/`, and `fsp gen`, `fsp watch` or
`fsp dev` turns them into `lib/app.g.dart`:

```text
lib/main.dart            Future<void> main() => AppMain.run();
lib/app/
  layout.dart            AppLayout({required Widget child})            the shell around everything below
  page.dart              HomePage()                                     → /
  products/
    page.dart            ProductsPage({required List<Product> products})   → /products
    $id/
      data.dart          Future<Product> data(Ref ref, {required int id})
      page.dart          ProductPage({required Product product})           → /products/:id
      action.dart        Future<void> action(Ref ref, {required int id, required Refund input})
  checkout/guard.dart    GuardResult guard(Ref ref)                     guards this folder and below
  (account)/             a group: a shared layout, nothing added to the URLs
  _components/           private: never routes
```

```dart
Future<void> main() => AppMain.run();                       // the whole main()

ProductRoute(id: 42).go(context);                           // typed navigation
ProductRoute.watch(ref, id: 42);                            // the route's data: AsyncValue<Product>
await ProductRoute.submit(ref, id: 42, input: refund);      // its write, with pending and error state
```

Start with [Installation and setup](getting-started.md), then [File kinds](file-kinds.md) and
[Routing](routing.md). [All pages](README.md) lists every topic, one page each. fespalier is an early version
(pre-1.0): what changed per release is in the
[changelog](https://github.com/fespalier/fespalier/blob/main/CHANGELOG.md), and what it does not do yet is in the
[roadmap](https://github.com/fespalier/fespalier/blob/main/ROADMAP.md).
