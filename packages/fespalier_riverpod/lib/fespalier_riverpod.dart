/// Riverpod providers per page instance for fespalier (since 0.13.0): [PageInstance] is the
/// identity of one page on a navigator (`/c/1` pushed twice is two, a query change or a remount
/// is the same one), [pageProvider] and [pageNotifierProvider] are auto-dispose families keyed by
/// it, [holdForPage] keeps one for as long as the page is on a navigator, and [usePageInstance]
/// is the hook that gives a widget its instance.
library;

export 'src/page_instance.dart' show PageInstance, usePageInstance;
export 'src/page_provider.dart'
    show holdForPage, pageNotifierProvider, pageProvider;
