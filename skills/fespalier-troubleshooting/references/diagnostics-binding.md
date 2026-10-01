# Diagnostics: binding parameters and types

As of v0.4.0 (`cli/src/resolve.rs`, `enums.rs`, `extra.rs`). `fsp` fills each
constructor or function parameter by **name**, then as a **query** parameter, then
by **type** (`fespalier/references/binding-rules.md`). These are the messages when
that fails. The general rule: they point at the **parameter**, with a code frame.

## A parameter nothing fills

| Message                                                                                                                                             | Cause and fix                                                                                                                                                                                                                            |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ``can't fill `label`: it isn't a segment of this path ($shop, $id) or a query parameter (optional and nullable)``                                   | A **required** page parameter that is not a `$segment` of this path, not `data`/`extra`, and not optional+nullable. Rename it to the segment, make it optional and nullable (a query parameter), or take what `data.dart` yields by type |
| ``can't fill `label`: it isn't a segment of this path (it has none), data.dart's String, or a query parameter (optional and nullable)``             | The same, in a page that has a `data.dart`: the data's type is also accepted                                                                                                                                                             |
| ``can't fill `nope` for a/: it isn't one of its segments (it has none) or a query parameter (optional and nullable)``                               | A `loading.dart`/`error.dart` is bound **per route it covers** (`for a/`): it asked for something that route lacks. An inherited view can only ask for segments every route below has                                                    |
| `` can't fill `thing`: a layout gets `Widget child` (or, for tabs, a `StatefulNavigationShell`), the segments above it (it has none) and `extra` `` | A layout asks for something it cannot have                                                                                                                                                                                               |
| ``can't fill `x`: not_found.dart only gets `Uri uri`, and the segments of its own path as Strings ($teamId)``                                       | No data, no query, no typed segments in a not-found view                                                                                                                                                                                 |
| ``can't fill `ref`: ...; a view function is a plain function with no BuildContext or ref: put hooks and `ref` in the widget it returns``            | A `Widget page(WidgetRef ref)`: view functions have neither; move `ref` into the widget the function builds                                                                                                                              |
| ``can't fill `super.x`; only `super.key` is allowed``                                                                                               | A required `super.` parameter other than `key`                                                                                                                                                                                           |
| `` can't fill `other`: transition() gets `key`, `child` and `state` ``                                                                              | A `transition()`/`present()` parameter with no binding (`shell`/`isShell` also exist in `transition()`)                                                                                                                                  |
| warning ``ProductPage doesn't take what data.dart yields; add `final Product data;` to its constructor``                                            | The page ignores its `data.dart`. The data is loaded anyway; add a parameter or delete `data.dart`                                                                                                                                       |

### Binding by name is silent when it is wrong

A parameter that **is** a valid segment name binds without a word, and a wrong
**optional nullable** parameter becomes a **query parameter** without a word: a
page with `this.title` (`String?`) gets `?title=`; a `Color? color` is left to its
default, a `String? color` is not. If a value arrives as `null` and a page shows
defaults, run `fsp routes --json` and read `params` (`in: path` or `query`).

## Types that disagree

| Message                                                                                                                                                                 | Cause and fix                                                                                                                               |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `$id` is String in p/$id/data.dart:2 but int here ``                                                                                                                 | Every file that asks for `$id` must agree. Change the parameter in the named file (line given) or here                                      |
| `` `?page` is String? in s/data.dart:2 but int? here ``                                                                                                                 | The same for a query parameter of one route (a layout's, a section's and a guard's are separate scopes)                                     |
| `` `Uri id`: segments are String, int, double or bool, or an enum ``                                                                                                    | A segment of another type. Take a `String` and parse it in the page                                                                         |
| `` `List<Object> rest`: a catch-all segment is the rest of the path, a `List` of String, int, double, num, bool or DateTime, or of an enum ``                           | A catch-all must be a `List` of one of those                                                                                                |
| `` `n` is int, which this folder's data.dart and the section's a/data.dart all yield; name the parameter `data` to get the nearest, or give one of them another type `` | Two `data.dart` yield one type for a by-type parameter                                                                                      |
| `` `error` gets the error, an Object, but it's declared Exception ``                                                                                                    | A by-name parameter declared with a type its value does not fit (`uri`, `child`, `stackTrace`, `retry`, ...). `Object`/`dynamic` always fit |
| `` `id` gets the segment as the URL spells it, a String: a segment that doesn't parse as `int` is why not_found.dart is shown, so declare it `String id` ``             | A typed segment in a `not_found.dart`: declare `String`                                                                                     |
| `` `go` can't be a query parameter: the typed route class has a member called `go`; rename it ``                                                                        | A query parameter named like a route-class member                                                                                           |

The type text is compared **as spelled**: `Product` and a `typedef` of it differ to
`fsp`, and `List<int>` and `List<num>` are different catch-all types.

## Enums

| Message                                                                                                                                                                                                                                                                       | Cause and fix                                                                                                                                                                        |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `` `Category cat`: no enum called `Category` in this file or the files it imports or exports under this package's lib/; a segment can only be a String, int, double or bool, or an enum. If `Category` is declared elsewhere, take a `String cat` and parse it in the page `` | `fsp` found no **enum** of that name: it is a class, comes from another package or `dart:`, or is not imported by this file. Import the declaring file (or a barrel that exports it) |
| `` `_Cat cat`: `_Cat` is private to its file, so the generated file can't name it; make the enum public ``                                                                                                                                                                    | A private enum cannot be named in `app.g.dart`                                                                                                                                       |
| `` `$category` is Size in data.dart:1 but Category here `` (with `(two different enums: a and b)` when the names match)                                                                                                                                                       | The files name different enums                                                                                                                                                       |

A `data.dart`, `guard.dart` or `redirect.dart` parameter that **could** be an enum but
cannot be found is the error; in a **page**, an optional nullable parameter of a type
no enum is found for (`Color? color`) is left to its default. After adding an enum in
another file run `fsp gen` (or keep `fsp watch` running: it watches `lib/` since 0.3.0).

## `extra`

| Message                                                                                                                                                                                                                                                   | Cause and fix                                                             |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `` `extra` gets the object passed on navigation, but it isn't in the URL: a deep link or a reload leaves it null, so declare it nullable, e.g. `Note? extra` ``                                                                                           | Make it `Note?`, `Object?` or `dynamic`                                   |
| `` `extra` is `String?` here, but the routes it covers take other types: `/n/a` (n/a/page.dart takes `int?`); a layout sees the extra of every route it covers, so declare it as `Object?` to accept any of them, or as their type when they share one `` | A layout or guard above routes with different extra types: take `Object?` |
| `` guard() takes `extra` as a named parameter, e.g. `{Object? extra}` `` (and `redirect()`)                                                                                                                                                               | `extra` in a guard or redirect is a **named** parameter                   |
| ``expected a top-level `extraCodec`: ...`` (error), `extra_codec.dart is only read at the root of the app folder, so this one is ignored` (warning)                                                                                                       | See `diagnostics-config-and-meta.md`                                      |

The generated file imports the type of an `extra` by name from **the page file's own
imports**; if `flutter analyze` then says the type is undefined in `app.g.dart`, the
type is not reachable from that file's imports (see `fespalier-routing`).

## Section data binding

| Message                                                                                                                                | Cause and fix                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `n` is int but the section's data.dart (a/data.dart) yields Team ``                                                                 | A parameter named `data` with the wrong type                                                                                                                                                            |
| `` `read` can't be a key of a section's data.dart: the section's typed handle has a member called `read`; rename it ``                 | A section's key is one of the 12 route-class member names (`location`, `go`, `push`, `replace`, `refresh`, `watch`, `read`, `prefetch`, `preload`, `ref`, `keepFor`, `hashCode`; `preload` since 0.5.0) |
| ``the section's typed handle `TeamsTeamIdSection` is already taken by ...; (group) folders don't add to the name, so rename a folder`` | Two sections whose folder paths differ only by groups                                                                                                                                                   |
