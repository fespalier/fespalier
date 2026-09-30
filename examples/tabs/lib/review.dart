/// Review-only facts about a page: kept in `meta.dart`, listed by the route
/// manifest in `lib/app.routes.g.dart`, and never imported by production code.
class Review {
  const Review(this.code);

  /// A stable review code, cited in docs and design files.
  final String code;
}
