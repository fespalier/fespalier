# Troubleshooting

## Things to know

- Pages render below their `layout.dart`, so a layout's `Scaffold` is not their nearest
  `Material` during page transitions. Wrap `ListTile`-heavy pages in
  `Material(type: MaterialType.transparency, …)`, as `products/page.dart` does.
- In a route file, any optional nullable parameter of a primitive type (or of an enum) becomes a
  query parameter, including one you meant as widget configuration (`String? title`). Keep such
  parameters on inner widgets instead of the file's exported one.
- go_router builds the whole matched stack, so `/products/abc` also loads `/products`
  underneath the not-found view.

## Known limitations

**Types are compared by spelling, not resolved.** The generator reads a syntax tree,
not the Dart analyzer, so `Product` and a `typedef` of it count as different types. The
Dart compiler still catches real mismatches in the generated code. (An enum is the one type
it does look up: it reads the declaration, and compares enums by it.)

## Symptoms

| Symptom                                                               | Cause                                                                 | Where                                                                                |
| --------------------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `fsp check` passes, but `lib/app.g.dart` is stale                     | `fsp check` writes and compares nothing                               | [Failing CI on a stale file](getting-started.md#failing-ci-on-a-stale-file)          |
| `test/widget_test.dart` refers to `MyApp` and `flutter analyze` fails | `flutter create` wrote it for the `MyApp` that `fsp init` replaced    | [fsp init](getting-started.md#fsp-init)                                              |
| Routes do not animate on go_router 18                                 | go_router 18 checks for `MaterialApp` from `package:material_ui`      | [go_router 18 and Material](getting-started.md#go_router-18-and-material)            |
| "URIs can't use string interpolation"                                 | an unescaped `$id` in an import                                       | [Importing from a $segment folder](testing.md#importing-from-a-segment-folder)       |
| "A Timer is still pending" at the end of a test                       | fakes that use `Future.delayed` under go_router's whole matched stack | [pumpRouter and currentLocation](testing.md#pumprouter-and-currentlocation)          |
| a `FlutterError` that says a deferred page's code is not loaded       | a widget test's `pump` never runs `loadLibrary()`                     | [Deferred routes in tests](testing.md#deferred-routes-in-tests)                      |
| An error message from `fsp`                                           |                                                                       | the `fespalier-troubleshooting` agent skill, [skills/README.md](../skills/README.md) |
