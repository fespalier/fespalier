import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

/// A menu button and the breadcrumbs of the page, at the foot of every page. The button
/// shows or hides [AppMenuList]; nothing of the menu is built (or asked of a guard) while it
/// is hidden.
class AppMenuBar extends StatefulWidget {
  const AppMenuBar({super.key});

  @override
  State<AppMenuBar> createState() => _AppMenuBarState();
}

class _AppMenuBarState extends State<AppMenuBar> {
  var _open = false;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_open)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: const SingleChildScrollView(child: AppMenuList()),
            ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => setState(() => _open = !_open),
              ),
              const Expanded(child: Breadcrumbs()),
            ],
          ),
        ],
      );
}

/// Every entry `nav.dart` files describe, nested as their folders are.
///
/// `AppMenu.watch(ref)` is the menu at the current location, with what each guard answers
/// now. An entry whose guards refuse is left out (`Admin`) or off (`Inbox`), and follows
/// the session without a navigation.
class AppMenuList extends ConsumerWidget {
  const AppMenuList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = AppMenu.watch(ref);
    return Column(
      children: [for (final item in items) ..._tiles(context, item, 0)],
    );
  }

  Iterable<Widget> _tiles(BuildContext context, NavItem item, int depth) sync* {
    yield ListTile(
      dense: true,
      contentPadding: EdgeInsets.only(left: 16.0 + 24 * depth, right: 16),
      leading: item.icon == null ? null : Icon(item.icon),
      title: Text(item.label(context)),
      subtitle:
          item.access == NavAccess.pending ? const Text('checking…') : null,
      selected: item.selected,
      enabled: item.enabled,
      onTap: () => item.go(context),
    );
    for (final child in item.children) {
      yield* _tiles(context, child, depth + 1);
    }
  }
}

/// The path to the page, from `AppMenu.breadcrumbs(ref)`: `Home › Order #7 › Refund`. Where
/// only the app folder's entry covers the page there is nothing to show.
class Breadcrumbs extends ConsumerWidget {
  const Breadcrumbs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final crumbs = AppMenu.breadcrumbs(ref);
    if (crumbs.length < 2) return const SizedBox.shrink();
    return Text(
      crumbs.map((c) => c.label(context)).join(' › '),
      key: const Key('breadcrumbs'),
    );
  }
}

/// A row of buttons for the entries below the team: `AppMenu.watch(ref, under: ...)` is the
/// menu of one folder, here the team's.
class TeamMenu extends ConsumerWidget {
  const TeamMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = AppMenu.watch(ref, under: r'teams/$teamId');
    return Wrap(
      spacing: 8,
      children: [
        for (final item in team.expand((t) => t.children))
          OutlinedButton.icon(
            icon: item.icon == null ? null : Icon(item.icon),
            label: Text(item.label(context)),
            style: item.selected
                ? OutlinedButton.styleFrom(
                    backgroundColor: Colors.black12,
                  )
                : null,
            onPressed: item.enabled ? () => item.go(context) : null,
          ),
      ],
    );
  }
}
