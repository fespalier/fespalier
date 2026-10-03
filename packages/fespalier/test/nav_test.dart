import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/nav.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The typed routes and the node tree `fsp gen` writes, by hand.

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

final class InboxRoute extends TypedLocation {
  const InboxRoute();
  @override
  String get location => '/inbox';
}

final class AdminRoute extends TypedLocation {
  const AdminRoute();
  @override
  String get location => '/admin';
}

final class OrderRoute extends TypedLocation {
  const OrderRoute({required this.id});
  final int id;
  @override
  String get location => '/orders/$id';
}

final class RefundRoute extends TypedLocation {
  const RefundRoute({required this.id});
  final int id;
  @override
  String get location => '/orders/$id/refund';
}

final class MembersRoute extends TypedLocation {
  const MembersRoute({required this.teamId});
  final String teamId;
  @override
  String get location => '/teams/$teamId/members';
}

final class SettingsRoute extends TypedLocation {
  const SettingsRoute({required this.teamId});
  final String teamId;
  @override
  String get location => '/teams/$teamId/settings';
}

UrlMatch? matchUrl(Uri uri) {
  UrlMatch hit(TypedLocation r, [Map<String, Object?> p = const {}]) =>
      UrlMatch(uri, r, p, const []);
  switch (uri.pathSegments) {
    case []:
      return hit(const HomeRoute());
    case ['search']:
      return hit(const SearchRoute());
    case ['inbox']:
      return hit(const InboxRoute());
    case ['admin']:
      return hit(const AdminRoute());
    case ['orders', final id]:
      final n = int.tryParse(id);
      return n == null ? null : hit(OrderRoute(id: n), {'id': n});
    case ['orders', final id, 'refund']:
      final n = int.tryParse(id);
      return n == null ? null : hit(RefundRoute(id: n), {'id': n});
    case ['teams', final t, 'members']:
      return hit(MembersRoute(teamId: t), {'teamId': t});
    case ['teams', final t, 'settings']:
      return hit(SettingsRoute(teamId: t), {'teamId': t});
  }
  return null;
}

class Flag extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

final signedIn = NotifierProvider<Flag, bool>(Flag.new);

/// How often each guard was asked.
var asked = <String, int>{};

/// What the async guard waits for.
late Completer<String?> gate;

GuardResult inboxGuard(Ref ref, TypedLocation route) {
  asked['inbox'] = (asked['inbox'] ?? 0) + 1;
  return ref.watch(signedIn) ? null : '/login';
}

GuardResult adminGuard(Ref ref, TypedLocation route) {
  asked['admin'] = (asked['admin'] ?? 0) + 1;
  return ref.watch(signedIn) ? null : '/login';
}

/// Made when it is asked, in the test's own zone: a completer from `setUp` would run its
/// callbacks outside the fake clock.
GuardResult slowGuard(Ref ref, TypedLocation route) {
  gate = Completer<String?>();
  return gate.future;
}

GuardResult brokenGuard(Ref ref, TypedLocation route) =>
    throw StateError('the guard broke');

TypedLocation homeAt(Map<String, Object?> p) => const HomeRoute();
TypedLocation searchAt(Map<String, Object?> p) => const SearchRoute();
TypedLocation inboxAt(Map<String, Object?> p) => const InboxRoute();
TypedLocation adminAt(Map<String, Object?> p) => const AdminRoute();
TypedLocation orderAt(Map<String, Object?> p) =>
    OrderRoute(id: p['id']! as int);
TypedLocation refundAt(Map<String, Object?> p) =>
    RefundRoute(id: p['id']! as int);
TypedLocation membersAt(Map<String, Object?> p) =>
    MembersRoute(teamId: p['teamId']! as String);
TypedLocation settingsAt(Map<String, Object?> p) =>
    SettingsRoute(teamId: p['teamId']! as String);

String searchLabel(BuildContext context, Map<String, Object?> p) =>
    'Find things';
String orderLabel(BuildContext context, Map<String, Object?> p) =>
    'Order #${p['id']}';
String teamLabel(BuildContext context, Map<String, Object?> p) =>
    'Team ${p['teamId']}';

const orderScope = <Type>[OrderRoute, RefundRoute];
const teamScope = <Type>[MembersRoute, SettingsRoute];

const home = NavNode(
  folder: '',
  nav: Nav(label: 'Home', icon: IconData(1), selectedIcon: IconData(2)),
  route: homeAt,
  flat: true,
);
const search = NavNode(
  folder: 'search',
  nav: Nav(label: 'Search', order: 1),
  route: searchAt,
  label: searchLabel,
);
const inbox = NavNode(
  folder: '(members)/inbox',
  nav: Nav(label: 'Inbox', order: 2, whenRefused: NavRefused.disable),
  route: inboxAt,
  guard: inboxGuard,
);
const admin = NavNode(
  folder: '(members)/admin',
  nav: Nav(label: 'Admin', order: 3),
  route: adminAt,
  guard: adminGuard,
);
const order = NavNode(
  folder: r'orders/$id',
  nav: Nav(label: 'Order', inMenu: false),
  route: orderAt,
  within: orderScope,
  label: orderLabel,
  children: [refund],
);
const refund = NavNode(
  folder: r'orders/$id/refund',
  nav: Nav(label: 'Refund'),
  route: refundAt,
  within: orderScope,
);
const team = NavNode(
  folder: r'teams/$teamId',
  nav: Nav(label: 'Team', order: 4),
  within: teamScope,
  label: teamLabel,
  children: [members, settings],
);
const members = NavNode(
  folder: r'teams/$teamId/members',
  nav: Nav(label: 'Members'),
  route: membersAt,
  within: teamScope,
  tabs: {'teams': 0},
);
const settings = NavNode(
  folder: r'teams/$teamId/settings',
  nav: Nav(label: 'Settings'),
  route: settingsAt,
  within: teamScope,
  tabs: {'teams': 1},
);
const lonely = NavNode(
  folder: 'lonely',
  nav: Nav(label: 'Lonely'),
);

const trails = <Type, List<NavNode>>{
  HomeRoute: [home],
  SearchRoute: [home, search],
  InboxRoute: [home, inbox],
  AdminRoute: [home, admin],
  OrderRoute: [home, order],
  RefundRoute: [home, order, refund],
  MembersRoute: [home, team, members],
  SettingsRoute: [home, team, settings],
};

/// What the tests show: `Home*` selected, `Inbox!` disabled, `Inbox?` pending, `Team[A, B]`
/// with children, `~` a heading.
String show(BuildContext context, List<NavItem> items) => items
    .map((i) {
      final kids = i.children.isEmpty ? '' : '[${show(context, i.children)}]';
      final mark =
          (i.selected ? '*' : '') +
          (i.enabled || i.route == null ? '' : '!') +
          (i.access == NavAccess.pending ? '?' : '') +
          (i.route == null ? '~' : '');
      return '${i.label(context)}$mark$kids';
    })
    .join(', ');

/// What the last `Menu` built, as items.
var seen = <NavItem>[];

/// A menu in a layout: what `AppMenu.watch(ref, under:)` and `breadcrumbs(ref)` give.
class Menu extends ConsumerWidget {
  const Menu({
    super.key,
    required this.tree,
    this.under,
    this.crumbs = false,
    this.mark = 'menu',
  });

  final List<NavNode> tree;
  final String? under;
  final bool crumbs;
  final String mark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = crumbs
        ? watchNavTrail(ref, matchUrl, trails)
        : watchNav(ref, tree, matchUrl, trails, under: under);
    seen = items;
    return Text(show(context, items), key: Key(mark));
  }
}

GoRouter routerAt(String initial, Widget Function() menu) => GoRouter(
  initialLocation: initial,
  routes: [
    ShellRoute(
      builder: (context, state, child) => Column(
        children: [
          menu(),
          Expanded(child: child),
        ],
      ),
      routes: [
        for (final p in [
          '/',
          '/search',
          '/inbox',
          '/admin',
          '/orders/:id',
          '/orders/:id/refund',
          '/teams/:teamId/members',
          '/teams/:teamId/settings',
          '/lonely',
        ])
          GoRoute(path: p, builder: (_, _) => const SizedBox()),
      ],
    ),
  ],
);

const roots = [home, search, inbox, admin, order, team, lonely];

String menuText(WidgetTester tester, [String mark = 'menu']) =>
    tester.widget<Text>(find.byKey(Key(mark))).data!;

void main() {
  setUp(() {
    asked = {};
  });

  group('watch', () {
    testWidgets('lists the tree, selects the page and keeps a flat entry beside', (
      tester,
    ) async {
      final r = routerAt('/search', () => const Menu(tree: roots));
      await pumpRouter(tester, r);
      // Home is flat: selected only on its own page. Hidden: Admin (refused, `hide`).
      // Team needs its segments, Order is `inMenu: false`, Lonely is a heading with
      // nothing under it.
      expect(menuText(tester), 'Home, Find things*, Inbox!');
    });

    testWidgets('the flat entry is selected on its own route only', (
      tester,
    ) async {
      await pumpRouter(tester, routerAt('/', () => const Menu(tree: roots)));
      expect(menuText(tester), 'Home*, Find things, Inbox!');
    });

    testWidgets('an entry with segments is listed only below its folder', (
      tester,
    ) async {
      final r = routerAt('/teams/t1/members', () => const Menu(tree: roots));
      await pumpRouter(tester, r);
      expect(
        menuText(tester),
        'Home, Find things, Inbox!, Team t1*~[Members*, Settings]',
      );
      r.go('/teams/t2/settings');
      await tester.pumpAndSettle();
      expect(
        menuText(tester),
        'Home, Find things, Inbox!, Team t2*~[Members, Settings*]',
      );
      r.go('/orders/7');
      await tester.pumpAndSettle();
      // Below the folder of `$id`, Order is `inMenu: false`: it and its children are out.
      expect(menuText(tester), 'Home, Find things, Inbox!');
    });

    testWidgets('an unknown location lists what needs no segments', (
      tester,
    ) async {
      final r = routerAt('/lonely', () => const Menu(tree: roots));
      await pumpRouter(tester, r);
      expect(menuText(tester), 'Home, Find things, Inbox!');
    });

    testWidgets('a heading with nothing to show is left out', (tester) async {
      final r = routerAt(
        '/teams/t1/members',
        () => const Menu(tree: [home, team]),
      );
      await pumpRouter(tester, r);
      expect(menuText(tester), 'Home, Team t1*~[Members*, Settings]');
      r.go('/search');
      await tester.pumpAndSettle();
      expect(menuText(tester), 'Home');
    });

    testWidgets('the icon follows the selection', (tester) async {
      late List<NavItem> items;
      final r = routerAt(
        '/',
        () => Consumer(
          builder: (context, ref, _) {
            items = watchNav(ref, roots, matchUrl, trails);
            return const SizedBox();
          },
        ),
      );
      await pumpRouter(tester, r);
      expect(items.first.icon, const IconData(2));
      r.go('/search');
      await tester.pumpAndSettle();
      expect(items.first.icon, const IconData(1));
    });
  });

  group('under', () {
    testWidgets('lists the topmost entries at or below a folder', (
      tester,
    ) async {
      final r = routerAt(
        '/teams/t1/members',
        () => const Menu(tree: roots, under: r'teams/$teamId'),
      );
      await pumpRouter(tester, r);
      // The heading itself is the topmost entry in its folder.
      expect(menuText(tester), 'Team t1*~[Members*, Settings]');
    });

    testWidgets('a folder in the middle gives the entries below it', (
      tester,
    ) async {
      final r = routerAt(
        '/teams/t1/settings',
        () => const Menu(tree: roots, under: r'teams/$teamId/members'),
      );
      await pumpRouter(tester, r);
      expect(menuText(tester), 'Members');
    });

    testWidgets('an empty folder name is the whole tree', (tester) async {
      final r = routerAt('/search', () => const Menu(tree: roots, under: ''));
      await pumpRouter(tester, r);
      expect(menuText(tester), 'Home, Find things*, Inbox!');
    });

    testWidgets('a folder with no nav.dart in or below it asserts in debug', (
      tester,
    ) async {
      final r = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Menu(tree: roots, under: 'nowhere'),
          ),
        ],
      );
      await pumpRouter(tester, r, settle: false);
      final error = tester.takeException();
      expect(error, isA<AssertionError>());
      expect(
        error.toString(),
        contains('no nav.dart is in or below the folder `nowhere`'),
      );
    });

    testWidgets('gives each entry its index as a tab of the folder', (
      tester,
    ) async {
      final r = routerAt(
        '/teams/t1/members',
        () => const Menu(tree: roots, under: r'teams/$teamId'),
      );
      await pumpRouter(tester, r);
      // `tabs` is keyed by the folder of the tab layout: here, `teams`.
      expect(seen.single.children.map((i) => i.tab), [null, null]);
      final byLayout = routerAt(
        '/teams/t1/members',
        () => const Menu(tree: roots, under: 'teams'),
      );
      await pumpRouter(tester, byLayout);
      expect(seen.single.children.map((i) => i.tab), [0, 1]);
      expect(seen.single.tab, isNull);
    });

    testWidgets('has no tab index without a folder to be a tab of', (
      tester,
    ) async {
      final r = routerAt('/teams/t1/members', () => const Menu(tree: roots));
      await pumpRouter(tester, r);
      expect(seen.last.children.map((i) => i.tab), [null, null]);
    });
  });

  group('guards', () {
    testWidgets('a sync answer is in the first frame: refused hides', (
      tester,
    ) async {
      final r = routerAt('/search', () => const Menu(tree: roots));
      await pumpRouter(tester, r, settle: false);
      // No pump after the first frame, and nothing pending: Admin is out, Inbox is off.
      expect(menuText(tester), 'Home, Find things*, Inbox!');
    });

    testWidgets('refused with `disable` lists it, off', (tester) async {
      final r = routerAt('/search', () => const Menu(tree: roots));
      await pumpRouter(tester, r);
      expect(seen.map((i) => i.node.nav.label), ['Home', 'Search', 'Inbox']);
      final item = seen.last;
      expect(item.access, NavAccess.refused);
      expect(item.enabled, isFalse);
      expect(item.route, isNotNull);
    });

    testWidgets('follows what a guard watches, in the next frame', (
      tester,
    ) async {
      final r = routerAt('/search', () => const Menu(tree: roots));
      final c = await pumpRouter(tester, r);
      expect(menuText(tester), 'Home, Find things*, Inbox!');
      c.read(signedIn.notifier).set(true);
      await tester.pump();
      expect(menuText(tester), 'Home, Find things*, Inbox, Admin');
      c.read(signedIn.notifier).set(false);
      await tester.pump();
      expect(menuText(tester), 'Home, Find things*, Inbox!');
    });

    testWidgets('`show` lists it and does not ask its guards', (tester) async {
      const shown = NavNode(
        folder: 'admin',
        nav: Nav(label: 'Admin', whenRefused: NavRefused.show),
        route: adminAt,
        guard: adminGuard,
      );
      final r = routerAt('/', () => const Menu(tree: [home, shown]));
      await pumpRouter(tester, r);
      expect(menuText(tester), 'Home*, Admin');
      expect(asked['admin'], isNull);
    });

    testWidgets('an entry is asked once however often the menu builds', (
      tester,
    ) async {
      final r = routerAt('/search', () => const Menu(tree: roots));
      await pumpRouter(tester, r);
      expect(asked['inbox'], 1);
      r.go('/');
      await tester.pumpAndSettle();
      r.go('/search');
      await tester.pumpAndSettle();
      expect(asked['inbox'], 1);
    });

    testWidgets('two menus on screen share one answer per entry', (
      tester,
    ) async {
      final r = routerAt(
        '/search',
        () => const Column(
          children: [
            Menu(tree: roots),
            Menu(tree: roots, mark: 'second'),
          ],
        ),
      );
      await pumpRouter(tester, r);
      expect(asked['inbox'], 1);
      expect(menuText(tester, 'second'), 'Home, Find things*, Inbox!');
    });

    testWidgets('an async guard starts pending and settles', (tester) async {
      const slow = NavNode(
        folder: 'admin',
        nav: Nav(label: 'Admin'),
        route: adminAt,
        guard: slowGuard,
      );
      final r = routerAt('/', () => const Menu(tree: [home, slow]));
      await pumpRouter(tester, r, settle: false);
      // Listed and enabled while it is out.
      expect(menuText(tester), 'Home*, Admin?');
      expect(seen.last.enabled, isTrue);
      await tester.pump();
      expect(menuText(tester), 'Home*, Admin?');
      gate.complete(null);
      await tester.pump();
      await tester.pump();
      expect(menuText(tester), 'Home*, Admin');
    });

    testWidgets('an async refusal hides the entry once it is in', (
      tester,
    ) async {
      const slow = NavNode(
        folder: 'admin',
        nav: Nav(label: 'Admin'),
        route: adminAt,
        guard: slowGuard,
      );
      final r = routerAt('/', () => const Menu(tree: [home, slow]));
      await pumpRouter(tester, r, settle: false);
      expect(menuText(tester), 'Home*, Admin?');
      gate.complete('/login');
      await tester.pump();
      await tester.pump();
      expect(menuText(tester), 'Home*');
    });

    testWidgets('a guard that throws is reported and the entry stays listed', (
      tester,
    ) async {
      const broken = NavNode(
        folder: 'admin',
        nav: Nav(label: 'Admin'),
        route: adminAt,
        guard: brokenGuard,
      );
      final r = routerAt('/', () => const Menu(tree: [home, broken]));
      await pumpRouter(tester, r, settle: false);
      expect(tester.takeException(), isA<StateError>());
      expect(menuText(tester), 'Home*, Admin?');
    });

    testWidgets('an answer that arrives after the menu is gone is dropped', (
      tester,
    ) async {
      const slow = NavNode(
        folder: 'admin',
        nav: Nav(label: 'Admin'),
        route: adminAt,
        guard: slowGuard,
      );
      final r = routerAt('/', () => const Menu(tree: [home, slow]));
      await pumpRouter(tester, r, settle: false);
      await tester.pumpWidget(const SizedBox());
      gate.complete(null);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('breadcrumbs', () {
    testWidgets('are the entries from the top down to the page', (
      tester,
    ) async {
      final r = routerAt(
        '/orders/7/refund',
        () => const Menu(tree: roots, crumbs: true),
      );
      await pumpRouter(tester, r);
      // `inMenu: false` doesn't leave the order out of the trail, and every
      // crumb is selected, the flat one included.
      expect(menuText(tester), 'Home*, Order #7*, Refund*');
    });

    testWidgets('carry the segments the entry was built with', (tester) async {
      final r = routerAt(
        '/teams/t9/members',
        () => const Menu(tree: roots, crumbs: true),
      );
      await pumpRouter(tester, r);
      expect(seen.map((c) => c.folder), [
        '',
        r'teams/$teamId',
        r'teams/$teamId/members',
      ]);
      expect(seen[1].params, {'teamId': 't9'});
      expect(seen[1].route, isNull);
      expect(seen[2].route, isA<MembersRoute>());
      expect((seen[2].route! as MembersRoute).teamId, 't9');
      expect(seen[0].params, isEmpty);
      expect(menuText(tester), 'Home*, Team t9*~, Members*');
    });

    testWidgets('are empty where no nav.dart covers the page', (tester) async {
      final r = routerAt(
        '/lonely',
        () => const Menu(tree: roots, crumbs: true),
      );
      await pumpRouter(tester, r);
      expect(menuText(tester), '');
    });

    testWidgets('follow the navigation', (tester) async {
      final r = routerAt('/', () => const Menu(tree: roots, crumbs: true));
      await pumpRouter(tester, r);
      expect(menuText(tester), 'Home*');
      r.go('/search');
      await tester.pumpAndSettle();
      expect(menuText(tester), 'Home*, Find things*');
    });
  });

  group('NavItem', () {
    testWidgets('label is the nav.dart label() or else the Nav label', (
      tester,
    ) async {
      final r = routerAt('/search', () => const Menu(tree: roots));
      await pumpRouter(tester, r);
      final context = tester.element(find.byKey(const Key('menu')));
      expect(seen[1].label(context), 'Find things');
      expect(seen[1].nav.label, 'Search');
      expect(seen[0].label(context), 'Home');
    });

    testWidgets('go navigates to its route, and does nothing for a heading', (
      tester,
    ) async {
      final r = routerAt('/teams/t1/members', () => const Menu(tree: roots));
      await pumpRouter(tester, r);
      final context = tester.element(find.byKey(const Key('menu')));
      final heading = seen.last;
      expect(heading.route, isNull);
      expect(heading.enabled, isFalse);
      heading.go(context);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/teams/t1/members');
      seen.firstWhere((i) => i.folder == 'search').go(context);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/search');
    });
  });
}
