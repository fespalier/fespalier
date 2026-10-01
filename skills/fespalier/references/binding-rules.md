# How parameters are filled

As of v0.4.0 (`cli/src/resolve.rs`, `cli/src/scan.rs`). `fsp` reads every
constructor (or view function), named or positional, `this.x` or typed, and
fills each parameter in this order. The first rule that applies wins.

1. **By name.** The name decides, in the files where it makes sense.
2. **As a query parameter.** The parameter is **optional** and its type is
   nullable or a `List`.
3. **By type.** The type is what a `data.dart` yields (or a known framework type).
4. **Otherwise**, a **required** parameter is a generator error that points at
   it, and an **optional** one is left to its default. (After an optional
   positional parameter is left to its default, every later positional one is
   too.)

## By name

| Name                                       | Where it is filled                                        | Gets                                                                      |
| ------------------------------------------ | --------------------------------------------------------- | ------------------------------------------------------------------------- |
| a `$segment` of the path, e.g. `id`        | any view, guard, redirect, `data.dart`                    | that segment, parsed into the type you declare                            |
| `data`                                     | `page.dart`, `layout.dart`                                | the route's own `data.dart`, else the nearest section's                   |
| `child`                                    | `layout.dart`                                             | the page, a `Widget`                                                      |
| `navigationShell`, `shell`                 | `layout.dart`                                             | the `StatefulNavigationShell` (makes it a tab layout)                     |
| `error`, `stackTrace`, `retry`             | `error.dart`                                              | the error, the `StackTrace`, a `VoidCallback`                             |
| `uri`                                      | `not_found.dart`, `guard.dart`, `redirect.dart`           | the requested `Uri`                                                       |
| `extra`                                    | `page.dart`, `layout.dart`, `guard.dart`, `redirect.dart` | `state.extra`, which must be nullable                                     |
| `key`, `child`, `state`, `shell`/`isShell` | `transition.dart`, `present.dart`                         | see `fespalier-layouts` (`shell` is meaningful in `transition.dart` only) |

In a `not_found.dart` the segments of its **own path** arrive as **raw
`String`s**, as the URL spells them (`/teams/Acme%20Co/...` gives `Acme Co`):
a segment that failed to parse is often why the view is showing, so declaring
`int teamId` there is an error.

## Query parameters

An **optional** parameter whose type is `T?` or `List<T>` (`T` being `String`,
`int`, `double`, `bool`, or an app enum) is a query parameter:
`int? page` gets `?page=2`, and `List<String> tags = const []` gets every
`?tags=`. A missing or unparsable value is `null` (or left out of a list): **a
bad query parameter never leads to not-found**. Every file of one route that
names `?page` must agree on its type.

> **The trap.** _Any_ optional nullable parameter of a primitive type (or an
> enum) in a route file becomes a query parameter, including one you meant as
> widget configuration (`String? title`). Keep such parameters on inner widgets,
> not on the file's exported one. (An optional nullable parameter of a type
> `fsp` finds no enum for, such as `Color? color`, is left to its default.)

## By type

- A page's (or layout's) parameter whose type is what `data.dart` yields gets
  the data, so `required this.product` with `final Product product;` works. A
  page or layout below a **section** can take the section's data the same way.
  If two `data.dart` files yield the same type, it is an error: name the
  parameter `data` to get the nearest, or give one another type.
- In `error.dart`, `Object` (or `dynamic`) gets the error, `StackTrace` the
  trace and `VoidCallback` the retry. In a layout, `Widget` gets the child and
  `StatefulNavigationShell` the shell. In `not_found.dart`, `Uri` gets the URI.

## Types are checked

A parameter bound by name must be declared with a type that value fits, or it
is an error at the parameter (`Object` and `dynamic` always fit):

| Parameter                   | Must be                                                                                        |
| --------------------------- | ---------------------------------------------------------------------------------------------- |
| `uri`                       | `Uri`                                                                                          |
| `child`                     | `Widget`                                                                                       |
| `navigationShell` / `shell` | `StatefulNavigationShell` (`StatefulWidget` and `Widget` are accepted)                         |
| `error`                     | `Object` or `dynamic` (a narrower type such as `Exception error` is an error at the parameter) |
| `stackTrace`                | `StackTrace`                                                                                   |
| `retry`                     | `VoidCallback` or `void Function()`                                                            |
| transition `key`            | `LocalKey`, `Key`, `ValueKey`, `ValueKey<String>`, ...                                         |
| transition `state`          | `GoRouterState`                                                                                |
| `shell` / `isShell`         | `bool`                                                                                         |
| `extra`                     | nullable (`Note?`, `Object?`, `dynamic`)                                                       |

## Segment and query types

- A segment is a `String`, `int`, `double`, `bool` or an app **enum**; a
  catch-all is a `List` of those (or of `num` or `DateTime`).
- The type comes from the parameters that ask for it, and **every file that
  asks for `$id` must agree**: `` `$id` is int in products/$id/data.dart:6 but String here ``.
  When nobody gives one, a segment is a `String`.
- `fsp new` scaffolds every segment as a `String`; change it in each file.
- An unparsable segment (`/products/abc` where `id` is an `int`) shows the
  nearest `not_found.dart`; the page is never built and **no guard runs**.

## Reserved names

A dynamic or catch-all folder cannot be called any of these (25 names; `of`, `maybeOf`
and `copyWith` since 0.5.0):

`data`, `child`, `navigationShell`, `shell`, `error`, `stackTrace`, `retry`,
`uri`, `key`, `location`, `go`, `push`, `replace`, `refresh`, `watch`, `read`,
`prefetch`, `ref`, `keepFor`, `hashCode`, `runtimeType`, `extra`, `of`, `maybeOf`,
`copyWith`.

The error is `` `$data` is reserved (fespalier fills parameters called `data` itself); pick another name ``.
A **query** parameter cannot be called any of the route class's members (14
names): `location`, `go`, `push`, `replace`, `refresh`, `watch`, `read`,
`prefetch`, `ref`, `keepFor`, `hashCode`, `of`, `maybeOf`, `copyWith` (`` `go` can't be a query parameter: the typed route class has a member called `go`; rename it ``).
`data`, `uri` and `child` are fine as query names: those never reach the query.
A section's typed handle has a member list of its own; see `fespalier-data`.

A segment name must be a lowerCamel Dart identifier: `$productId` is valid,
`$ProductId` and `$1st` are not.

## Constructor shapes that fail

- A required `super.something` other than `super.key`: ``can't fill `super.x`; only `super.key` is allowed``.
- A view **function** that asks for `ref` or `context`: ``can't fill `ref`: ...; a view function is a plain function with no BuildContext or ref: put hooks and `ref` in the widget it returns``.
- A page that does not take what its `data.dart` yields only **warns**: ``ProductPage doesn't take what data.dart yields; add `final Product data;` to its constructor``.
