/// The facts about a page only a person can write. fespalier passes a route's
/// `meta.dart` through untouched (`AppRoutes.byType[HomeRoute]!.meta`) and never
/// reads this type: what `code` or `title` mean is up to the app.
class PageMeta {
  const PageMeta({required this.code, required this.title});

  /// A stable review code, cited in docs and design files.
  final String code;

  /// The browser tab title (web) and the app-switcher label.
  final String title;
}
