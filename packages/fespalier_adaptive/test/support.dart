// The typed routes, the node tree and the routers `fsp gen` would write for a tab layout like
// examples/tabs (Home, Search, Profile and Library, which is a heading with Books and Authors
// below it), by hand, so these tests need no generated code.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/nav.dart';
import 'package:fespalier_adaptive/material.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class HomeRoute extends TypedLocation {
  const HomeRoute();
  @override
  String get location => '/';
}

final class SearchRoute extends TypedLocation {
  const SearchRoute();
  @override
  String get location => '/search';
}

final class ProfileRoute extends TypedLocation {
  const ProfileRoute();
  @override
  String get location => '/profile';
}

final class BooksRoute extends TypedLocation {
  const BooksRoute();
  @override
  String get location => '/library/books';
}

final class AuthorsRoute extends TypedLocation {
  const AuthorsRoute();
  @override
  String get location => '/library/authors';
}

UrlMatch? matchUrl(Uri uri) {
  UrlMatch hit(TypedLocation r) => UrlMatch(uri, r, const {}, const []);
  return switch (uri.path) {
    '/' => hit(const HomeRoute()),
    '/search' => hit(const SearchRoute()),
    '/profile' => hit(const ProfileRoute()),
    '/library/books' => hit(const BooksRoute()),
    '/library/authors' => hit(const AuthorsRoute()),
    _ => null,
  };
}

TypedLocation homeAt(Map<String, Object?> p) => const HomeRoute();
TypedLocation searchAt(Map<String, Object?> p) => const SearchRoute();
TypedLocation profileAt(Map<String, Object?> p) => const ProfileRoute();
TypedLocation booksAt(Map<String, Object?> p) => const BooksRoute();
TypedLocation authorsAt(Map<String, Object?> p) => const AuthorsRoute();

const home = NavNode(
  folder: '(tabs)/(home)',
  nav: Nav(label: 'Home', icon: Icons.home_outlined, selectedIcon: Icons.home),
  route: homeAt,
  tabs: {'(tabs)': 0},
);
const search = NavNode(
  folder: '(tabs)/search',
  nav: Nav(label: 'Search', icon: Icons.search),
  route: searchAt,
  tabs: {'(tabs)': 1},
);
const profile = NavNode(
  folder: '(tabs)/profile',
  nav: Nav(label: 'Profile', icon: Icons.person_outline),
  route: profileAt,
  tabs: {'(tabs)': 2},
);

/// A heading: `library/` has no page.dart, so the entry is the tab.
const library = NavNode(
  folder: '(tabs)/library',
  nav: Nav(label: 'Library', icon: Icons.library_books_outlined),
  tabs: {'(tabs)': 3},
  children: [books, authors],
);
const books = NavNode(
  folder: '(tabs)/library/books',
  nav: Nav(label: 'Books'),
  route: booksAt,
  tabs: {'(tabs)/library': 0},
);
const authors = NavNode(
  folder: '(tabs)/library/authors',
  nav: Nav(label: 'Authors', order: 1),
  route: authorsAt,
  tabs: {'(tabs)/library': 1},
);

const tabsTree = [home, search, profile, library];

const trails = <Type, List<NavNode>>{
  HomeRoute: [home],
  SearchRoute: [search],
  ProfileRoute: [profile],
  BooksRoute: [library, books],
  AuthorsRoute: [library, authors],
};

/// What `AppMenu.watch(ref, under: '(tabs)')` is for [tree].
List<NavItem> Function(WidgetRef ref) menuOf(List<NavNode> tree) =>
    (ref) => watchNav(ref, tree, matchUrl, trails, under: '(tabs)');

/// A page with state of its own: `Search count 2`.
class Counter extends StatefulWidget {
  const Counter(this.label, {super.key});

  final String label;

  @override
  State<Counter> createState() => _CounterState();
}

class _CounterState extends State<Counter> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('${widget.label} count $_count'),
      IconButton(
        tooltip: '+ ${widget.label}',
        icon: const Icon(Icons.add),
        onPressed: () => setState(() => _count++),
      ),
    ],
  );
}

/// The layout the router uses by default: the scaffold around the shell.
Widget Function(StatefulNavigationShell shell) scaffoldFor(
  List<NavNode> tree, {
  NavBreakpoints breakpoints = NavBreakpoints.material,
}) =>
    (shell) => AdaptiveNavScaffold(
      shell: shell,
      menu: menuOf(tree),
      breakpoints: breakpoints,
    );

/// The shell of the last layout built, and a context below the router, for `AdaptiveNav.select`.
StatefulNavigationShell? lastShell;
BuildContext? lastContext;

/// A router with one `StatefulShellRoute` branch per tab, `layout` around it. Library's first page
/// is Books.
GoRouter tabsRouter(
  String initial, {
  Widget Function(StatefulNavigationShell shell)? layout,
}) => GoRouter(
  initialLocation: initial,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) {
        lastShell = shell;
        lastContext = context;
        return (layout ?? scaffoldFor(tabsTree))(shell);
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const Counter('Home')),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/search',
              builder: (_, _) => const Counter('Search'),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/profile',
              builder: (_, _) => const Counter('Profile'),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library/books',
              builder: (_, _) => const Counter('Books'),
            ),
            GoRoute(
              path: '/library/authors',
              builder: (_, _) => const Counter('Authors'),
            ),
          ],
        ),
      ],
    ),
  ],
);

/// An entry as `AppMenu.watch` would give it.
NavItem entry(
  String label, {
  TypedLocation? route,
  bool selected = false,
  NavAccess access = NavAccess.allowed,
  int? tab,
  List<NavItem> children = const [],
}) => NavItem(
  node: NavNode(
    folder: label.toLowerCase(),
    nav: Nav(label: label),
  ),
  route: route,
  params: const {},
  selected: selected,
  access: access,
  tab: tab,
  children: children,
);

List<String> labels(Iterable<NavItem> items) => [
  for (final i in items) i.nav.label,
];

/// Sizes the test window to [width] by [height] logical pixels (a test's default is 800 by 600).
void resize(WidgetTester tester, double width, [double height = 900]) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// [label]'s text inside the widget of type [T] (not the page's own text).
Finder inside<T extends Widget>(String label) =>
    find.descendant(of: find.byType(T), matching: find.text(label));
