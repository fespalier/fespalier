# Troubleshooting

An error message from `fsp` is explained, with its fix, in the `fespalier-troubleshooting` agent skill
([skills/README.md](../skills/README.md)). The table below covers the problems that are not a message of
`fsp` itself.

## Symptoms

| Symptom                                                               | Cause                                                                                            | Fix                                                                                                              |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `fsp check` passes, but `lib/app.g.dart` is stale                     | `fsp check` checks the routes but never compares the committed file with what the tree generates | Regenerate and fail on a difference: [Failing CI on a stale file](getting-started.md#failing-ci-on-a-stale-file) |
| `test/widget_test.dart` refers to `MyApp` and `flutter analyze` fails | `flutter create` wrote it for the `MyApp` that `fsp init` replaced                               | Delete it or rewrite it: [fsp init](getting-started.md#fsp-init)                                                 |
| Routes do not animate on go_router 18                                 | go_router 18 checks for `MaterialApp` from `package:material_ui`                                 | Add a root `transition.dart`: [go_router 18 and Material](getting-started.md#go_router-18-and-material)          |
| "URIs can't use string interpolation"                                 | an unescaped `$id` in an import                                                                  | Escape it: [Importing from a $segment folder](testing.md#importing-from-a-segment-folder)                        |
| "A Timer is still pending" at the end of a test                       | fakes that use `Future.delayed` under go_router's whole matched stack                            | [pumpRouter and currentLocation](testing.md#pumprouter-and-currentlocation)                                      |
| a `FlutterError` that says a deferred page's code is not loaded       | a widget test's `pump` never runs `loadLibrary()`                                                | [Deferred routes in tests](testing.md#deferred-routes-in-tests)                                                  |
| the app is blank on the web with `otel_zone`                          | `OtelZone.runGuarded` never runs its body on the web                                             | Run the body as it is on the web: [OpenTelemetry with otel_zone](observability.md#opentelemetry-with-otel_zone)  |
| a test fails with `MissingPluginException` on `connectivity_status`   | the test reaches the plugin without `FakeConnectivity`                                           | [Reconnects](data.md#reconnects-fespalier_connectivity)                                                          |
| every screen has two Sentry transactions                              | Sentry's own navigator observer runs next to fespalier's                                         | [One transaction per screen](observability.md#one-transaction-per-screen)                                        |

## Things to know

- **Page transitions and `Material`.** Pages render below their `layout.dart`, so a layout's `Scaffold`
  is not their nearest `Material` during page transitions. Wrap `ListTile`-heavy pages in
  `Material(type: MaterialType.transparency, …)`, as `products/page.dart` does.
- **Optional nullable parameters are query parameters.** In a route file, any optional nullable parameter
  of a primitive type (or of an enum) becomes a query parameter, including one you meant as widget
  configuration (`String? title`). Keep such parameters on inner widgets instead of the file's exported
  one ([How parameters are filled](file-kinds.md#how-parameters-are-filled)).
- **go_router builds the whole matched stack**, so `/products/abc` also loads `/products` underneath the
  not-found view.

## Known limitations

**Types are compared by spelling, not resolved.** The generator reads a syntax tree, not the Dart
analyzer, so `Product` and a `typedef` of it count as different types. The Dart compiler still catches
real mismatches in the generated code. (An enum is the one type it does look up: it reads the
declaration, and compares enums by it.)
