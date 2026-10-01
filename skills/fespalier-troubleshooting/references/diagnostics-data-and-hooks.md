# Diagnostics: `data.dart`, guards, redirects and transitions

As of v0.4.0 (`cli/src/resolve.rs`). Messages are the text `fsp` prints; the cause
and the fix follow each.

## `data.dart`

| Message                                                                                                                                                                                                                      | Cause and fix                                                                                                                                                                |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ``data() must take `Ref ref` first``                                                                                                                                                                                         | The function form's first parameter is a positional `Ref ref`                                                                                                                |
| `data() needs an explicit return type (Future<T>, Stream<T> or T)`                                                                                                                                                           | `data(Ref ref) async => 1` has no type; write `Future<int> data(...)`                                                                                                        |
| `` data() takes segments as named parameters, e.g. `{required int id}` ``                                                                                                                                                    | A positional parameter after `ref`                                                                                                                                           |
| `` `id` isn't a segment of this path (it has none); for a query parameter make it optional and nullable, e.g. `String? id` ``                                                                                                | A named parameter that is neither a segment of this path nor an optional nullable query parameter                                                                            |
| `` `d` isn't a segment of this path ($id); if `d` is meant as a query parameter, its type `Duration?` isn't one: use a nullable String, int, double or bool, an enum, or a List of those ``                                  | An optional parameter whose type a query parameter can't have. Use a nullable `String`, `int`, `double` or `bool`, an enum, or a `List` of those                             |
| `` `data` must be a FutureProvider, StreamProvider, AsyncNotifierProvider or StreamNotifierProvider `` (`..., not Provider`)                                                                                                 | `final data = ...` of another kind (or not a call)                                                                                                                           |
| `` give the provider its type arguments, e.g. `FutureProvider<Product>` ``                                                                                                                                                   | `final data = FutureProvider((ref) ...)`: `fsp` reads types from the source, so spell them out                                                                               |
| `` this path has 2 segments, so the family argument must be a record naming the ones it uses, e.g. `({int id})` ``                                                                                                           | A family you wrote, under several segments                                                                                                                                   |
| `` `page` isn't a segment of this path ($id); a provider you write can be keyed by segments only. To use a query parameter, write `Future<int> data(Ref ref, {int? page})` instead, or select your provider from `data()` `` | A family you wrote, with a record field that is a query parameter: a hand-written family is keyed by segments only. Use the function form or a selector, as the message says |
| `` `rest` is a catch-all, a List that a provider can't be keyed by (lists compare by identity); write `Future<int> data(Ref ref, {required List<T> rest})` ... ``                                                            | A provider you wrote keyed by a catch-all                                                                                                                                    |
| ``a data() that selects a provider must return `ProviderListenable<AsyncValue<T>>`, so the page can be given a `T` ``                                                                                                        | `ProviderListenable<int>`, without the `AsyncValue`                                                                                                                          |
| ``a data() that returns a `ProviderListenable` takes no `Ref`: it selects the provider (`=> productProvider(id)`), it doesn't read one``                                                                                     | A selector with a `Ref` parameter                                                                                                                                            |
| `` expected `Future<T> data(Ref ref, {...segments})`, `ProviderListenable<AsyncValue<T>> data({...segments})` or `final data = FutureProvider<T>(...)` ``                                                                    | `data.dart` exports none of the three forms (a misspelled name, e.g. `fetch`)                                                                                                |
| `data.dart has no page.dart to feed; with a layout.dart beside it, it would be the data of the section below that layout`                                                                                                    | A `data.dart` with no page and no layout                                                                                                                                     |

Runtime, not `fsp`: a selector that returns `provider.select(...)` builds and watches fine, but
`refresh` and `retry` throw a `StateError` (`data.dart selected ..., which is not a
FutureProvider, StreamProvider or generated async provider, so it cannot be invalidated
or refreshed. Return the provider itself from data() ...`).

## `guard.dart` and `redirect.dart`

| Message                                                                                                                                                                                           | Cause and fix                                                                                          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `` expected `GuardResult guard(ProviderContainer c, {...segments})` ``                                                                                                                            | No function called `guard`                                                                             |
| `guard() must return GuardResult (a location to redirect to, or null)`                                                                                                                            | Allowed: `GuardResult`, `FutureOr<String?>`, `Future<String?>`, `String?`                              |
| ``guard() must take `ProviderContainer c` first``                                                                                                                                                 | The container is the first, positional parameter                                                       |
| `` `id` isn't a segment of this path (it has none) at or above its folder; guard() can also take `Uri uri` and `extra`; for a query parameter make it optional and nullable, e.g. `String? id` `` | A guard cannot ask for a segment **below** its folder; a query parameter must be optional and nullable |
| warning `guard.dart guards no routes: there is no page.dart or redirect.dart at or below this folder`                                                                                             | An empty guard folder                                                                                  |
| `` expected `String redirect({...segments})` ``                                                                                                                                                   | No function called `redirect`                                                                          |
| `redirect() must return the location to go to: a String (or Future<String>)`                                                                                                                      | Wrong return type                                                                                      |
| `a folder has a page.dart or a redirect.dart, not both`                                                                                                                                           |                                                                                                        |
| `a tab layout folder can't hold a redirect.dart; put the redirect in a subfolder`                                                                                                                 |                                                                                                        |

A login page that shows **"Nothing at /login"** is not an error message of `fsp`: the guard
covers the login page itself (`fespalier-guards`).

## `transition.dart` and `present.dart`

| Message                                                                                         | Cause and fix                                                                                           |
| ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `` expected `Page<void> transition(LocalKey key, Widget child)` `` (or `present`)               | No function of that name                                                                                |
| `` transition() must return a Page, e.g. `Page<void>` ``                                        | Return a `Page`                                                                                         |
| `` transition() must take the page as `Widget child` ``                                         | No `child` parameter                                                                                    |
| `` can't fill `other`: transition() gets `key`, `child` and `state` ``                          | Only `key`, `child`, `state` (and `shell`/`isShell`, a `bool`)                                          |
| `` `key` gets the page's key, a ValueKey<String>, but it's declared ... ``                      | `key` may be `LocalKey`, `Key`, `ValueKey`, `ValueKey<String>`, `ValueKey<Object>`, `ValueKey<dynamic>` |
| warning `present.dart builds this folder's page, but there is no page.dart here; it is ignored` | `present.dart` needs a `page.dart` beside it                                                            |

## Runtime errors that are not from `fsp`

- **A dialog or sheet opens over a blank screen on a deep link**: the route has no parent
  page above it; put its folder below a page (`fespalier-layouts`).
- **`No Material widget found` / `MaterialLocalizations` missing** for a dialog or sheet: a
  `MaterialApp` (or a `Localizations` with the Material delegate) must be above the router.
- **A `BadSegment` exception** is thrown inside generated code and turned into
  `not_found.dart`; you should never see it unless you call `Segment.asInt` yourself.
