import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';

/// How the list is ordered: `?sort=name` or `?sort=expensive`. An enum in the
/// page's own file can be a query parameter; a missing or unknown value is null.
enum Sort { name, expensive }

/// Products per page: `?page=2` is the next [pageSize].
const pageSize = 3;

/// The list's state lives in the URL: `sort` and `page` are query parameters,
/// so `/products?sort=expensive&page=2` is a link someone can send, and back
/// and forward move between the views.
class ProductsPage extends ConsumerWidget {
  const ProductsPage({super.key, required this.products, this.sort, this.page});

  /// What data.dart yields, matched by type.
  final List<Product> products;

  /// Optional and nullable: query parameters.
  final Sort? sort;
  final int? page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sorted = switch (sort) {
      Sort.name => [...products]..sort((a, b) => a.name.compareTo(b.name)),
      Sort.expensive => [...products]
        ..sort((a, b) => b.price.compareTo(a.price)),
      null => products,
    };
    final pages = (sorted.length / pageSize).ceil();
    final current = (page ?? 1).clamp(1, pages < 1 ? 1 : pages);
    final shown = sorted.skip((current - 1) * pageSize).take(pageSize);
    return Material(
      // Pages sit below the layout's Scaffold, so give ListTile ink a
      // surface of its own (page transitions paint in between).
      type: MaterialType.transparency,
      child: Column(
        children: [
          // Below the page, and not handed `sort` or `page`: it reads the
          // route with `ProductsRoute.of(context)`.
          _ProductsControls(pages: pages),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => const ProductsRoute().refresh(ref),
              child: ListView(
                children: [
                  for (final p in shown)
                    // A real <a href="/products/2"> on the web (middle click,
                    // status bar); a plain click goes through the router.
                    // Hovering, focusing or touching a row starts loading the
                    // product, so its page is there when the row is followed.
                    RouteLink(
                      to: ProductRoute(id: p.id),
                      preload: Preload.intent,
                      builder: (context, follow) => ListTile(
                        // The same line is on the product's page: the avatar
                        // flies from the row to there (since 0.8.1). It
                        // needs the page's data in its first frame, which the
                        // preload above provides.
                        leading: ProductRoute(id: p.id).hero(
                          'avatar',
                          child: CircleAvatar(child: Text(p.name[0])),
                        ),
                        title: Text(p.name),
                        trailing: Text('€${p.price.toStringAsFixed(2)}'),
                        onTap: follow,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sort and page buttons that change one query parameter of the current URL.
class _ProductsControls extends StatelessWidget {
  const _ProductsControls({required this.pages});

  final int pages;

  @override
  Widget build(BuildContext context) {
    // The typed route at the current location, parsed from the URL.
    final route = ProductsRoute.of(context);
    final page = route.page ?? 1;
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final s in Sort.values)
          ChoiceChip(
            label: Text('Sort by ${s.name}'),
            selected: route.sort == s,
            // Back to the first page: `page: null` leaves ?page= out of the URL.
            // `go`, so back returns to the previous sort.
            onSelected: (_) => route
                .copyWith(sort: route.sort == s ? null : s, page: null)
                .go(context),
          ),
        TextButton(
          onPressed: page > 1
              // Page 1 is the URL without ?page=.
              ? () =>
                  route.copyWith(page: page > 2 ? page - 1 : null).go(context)
              : null,
          child: const Text('Previous'),
        ),
        Text('Page $page of $pages'),
        TextButton(
          onPressed: page < pages
              ? () => route.copyWith(page: page + 1).go(context)
              : null,
          child: const Text('Next'),
        ),
      ],
    );
  }
}
