# FAQ

## Design notes

### Why `watch` and `read` are static

`ProductRoute(id: 42).watch(ref)` would be nicer than `ProductRoute.watch(ref, id: 42)`, and it can't be
had for what it costs. An instance member has to say what it returns, `AsyncValue<Product>`, so the
generated file would have to _name_ `Product`. It doesn't import what your `data.dart` imports (it can't
tell which of its imports a name comes from, and it may be a private, aliased or record type).

The other ways out don't work:

- a `late final watch = (ref) => ...` field, whose type Dart would infer from the provider, is refused in
  a class with a `const` constructor, and typed routes are `const` (`const SearchRoute(q: 'ap')`);
- an `extension type` or a getter still has to be typed;
- returning `AsyncValue<Object?>` would lose the very type that is the point.

A static function value takes its type from the provider by inference, which is why the helpers that
return your data are static, and the ones that don't (`prefetch`, `refresh`, `go`, `location`) are
instance methods. If Dart macros, or naming a type through the import machinery that `extra` already
uses, become an option, this can be reopened; today the trade is a `const` route and a type that is never
`dynamic`.

### Why forms are companions of `action.dart`, not a `form.dart`

A form is the UI of one write, and `action.dart` already owns what that needs: the keys, the input type,
the pending and error state, the invalidation set and the DevTools site. A `form.dart` would bind all of
that again and need a rule for which action it submits.

- Validation has to guard every path to the write (the form, `submit`, another page, a test), and only
  code the action's own provider calls can promise that.
- An `optimistic()` is about the write's effect on data, which is what `invalidates` is about, so the two
  are checked against each other.
- A new file kind would cost a scan rule, a scaffold, editor support and orphan diagnostics; companions
  are a convention like `invalidates`.
- The thing a `form.dart` would invite, a form with no write (search filters), is what URL state
  (`copyWith`) is for.

### Why `copyWith` is a getter of a function type

`route.copyWith(page: null)` has to mean "clear the page" and `route.copyWith()` "keep it", so `null`
can't be the default of an `int? page` parameter. The usual answers each cost something visible:

- A method with `Object? page = _keep` accepts anything (`copyWith(page: 'x')` compiles and fails at run
  time), and its signature in the IDE says `Object?`.
- A wrapper for the argument (`copyWith(page: Some(null))`) makes every call site noisier than the
  hand-written copy it replaces.
- Dart has no overload and no way to give an `int?` parameter a default that isn't an `int?`.

What does work is to split what the caller sees from what runs. The public `copyWith` is a getter whose
type is `SearchRoute Function({String? q, int? page, Sort? sort})`, the fields' own types, and what it
returns is a private method that takes `Object?` with a private `const` sentinel (`_keep`) as each
default. A caller passes a `String?` or nothing; calling the function through its type, an argument that
is left out takes the private default and one that is `null` is `null`. Callers see the clean signature;
the sentinel lives only in `app.g.dart`, and no caller can pass it.

Nothing is `dynamic`, a segment is not nullable (`copyWith(id: null)` doesn't compile), the route
constructors stay `const`, and the sentinel is one `const` object.

Costs: `copyWith` shows in the IDE as a getter whose value is a function (the analyzer still checks every
named parameter and its type), and each call allocates the function (a tear-off of the private method).
If Dart gets a way to tell an omitted optional parameter from a passed one, this reduces to an ordinary
method.

### Why an action's `submit` is static, and its input is typed

`RefundRoute(id: 1).submit(ref, input: form)` has the problem `ProductRoute(id: 42).watch(ref)` has: an
instance member has to say what it returns, so the generated file would have to name `Refund`. A static
function value takes its result type from the provider by inference, so it is never `dynamic`.

The `input` is the one type that has to be written out (a function value's parameters can't be
inferred), and that one `fespalier` can name: it reads it from `action.dart` the way it reads the type of
an `extra`, which is how the file's own imports reach `app.g.dart`.

A write is also kept apart from the read it changes on purpose: it has its own provider, with its own
state, instead of being a mode of `data.dart`'s, so a failed write can never put `error.dart` where the
form was.

### Why a localized path is one route with an alternation

`products/` answering `/produits` could be done three ways in go_router, and only one keeps the URL and
the route one thing.

1. _A redirect from each spelling to the canonical path._ It changes the URL the user came for
   (`/produits/2` turns into `/products/2` in the address bar and in shared links), which is the
   opposite of a localized path, and every nested route would need its own redirect.
2. _A sibling `GoRoute` per spelling sharing the builder._ The URL stays, but the subtree is copied
   per spelling (nested routes, layouts, guards), the copies have different page keys (navigating
   from one spelling to another rebuilds the page), restoration ids and a tab's branch would see
   several routes, and the order and duplicate checks multiply.
3. _One `GoRoute`, the segment a path parameter with its own pattern_, `:_l0(products|produits)`.
   go_router matches a route with a regular expression made from its `path`, where `:name(pattern)`
   is a parameter with a pattern of its own (`path_utils.dart`, `patternToRegExp`, the same in go_router
   17.5 and 18.0; the catch-all's `:rest(.+)` is one). A deep link, `go`, a redirect and the tab
   stack all see one route, and its subtree is written once. The costs are small and all handled:
   the parameter shows up in `pathParameters` and `fullPath` (fespalier's readers skip it and
   `routeTemplate` turns it back into the canonical path), a spelling is escaped for the regular
   expression, and go_router's rule that a tab opens on a route without parameters needs an
   `initialLocation`, which `fsp gen` writes.

The typed side takes the locale as an argument (`locationFor(locale)`, `go(context, locale:)`) rather
than from a global (an `AppRoutes.locale` the typed routes read). A global would make
`ProductRoute(id: 2).go(context)` and `context.go(ProductRoute(id: 2).location)` differ, make
`.location` depend on when it is read, and make every test depend on what the last one left in a
static. A `locale:` argument keeps a route a value, and the app, which owns its locale, decides where to
pass it: see [Localized paths](routing.md#localized-paths).

### Why string paths are checked by fsp, not an analyzer plugin

`fsp` already has the route tree, parses Dart, and reports diagnostics that both editor plugins show, so
`fsp check` in CI and `fsp watch` get the lint with nothing for an app to add. An analyzer plugin would
need `analysis_options.yaml`, which takes a package from pub.dev or a `path:` and not a git dependency
(fespalier is one), would pin an `analyzer` major that moves several times a year, and would need its own
copy of the matcher. The cost of a syntax tree is that `fsp` can't know that `context` is a
`BuildContext`: it only reads string literals in the call shapes listed in
[Checking string paths](cli.md#checking-string-paths).

### Why fsp watch doesn't cache per route

A full resolve is 30 ms at 5,000 routes, a tenth of a save that changes output. Resolving one route reads
the folders above it and shares state with the others (names claimed, query types settled), so a per-route
cache would have to replay those effects for a saving smaller than its bookkeeping. The folder walk is
80 ms at 5,000 routes, and reading the files a small part of it: a cache keyed on modification times would
save less than it risks (an edit in the same timestamp tick, a file replaced by one with the same size and
time). See [Performance](cli.md#performance).

## Short answers

### Is there a build_runner step?

No. `fsp` is a separate binary that writes `lib/app.g.dart`; commit it, or generate it in CI. See
[Keeping app.g.dart](getting-started.md#keeping-appgdart).

### Is it on pub.dev?

No. The packages are git dependencies pinned at a release tag. See
[Companion packages](getting-started.md#companion-packages).

### What does it cost in a release build?

Nothing for what you do not use: DevTools support and telemetry are compiled out. See
[DevTools extension](devtools.md#what-devtools-costs) and [What it costs](observability.md#what-it-costs).
