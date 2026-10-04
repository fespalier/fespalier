/// Feature flags for fespalier (since 0.9.0): declare a flag once (`const checkoutV2 = BoolFlag('checkout_v2');`),
/// read it synchronously where you need it (`ref.watch(flag(checkoutV2))`), and gate a route with `flagGuard` in its
/// guard.dart; menus follow, because they run guards. Values come from the [flagSource] the app overrides in startup().
library;

export 'src/flag.dart'
    show BoolFlag, DoubleFlag, FeatureFlag, IntFlag, StringFlag;
export 'src/guard.dart' show flagGuard;
export 'src/providers.dart' show flag, flagSource;
export 'src/source.dart' show AsyncFlags, ConstFlags, FlagSource, FlagsChanged;
