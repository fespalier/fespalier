/// The app's own `lib/app.dart`: the common name that makes build_runner's
/// `.g.dart` builders claim `lib/app.g.dart`, fespalier's default output, and
/// delete it. `scripts/check-codegen-interop.sh` builds this app twice, with
/// that output and with `output: lib/routes.g.dart`.
const appTitle = 'Interop';
