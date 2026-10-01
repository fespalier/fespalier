# Section data

As of v0.4.0. A folder with a `layout.dart` and **no `page.dart`** (a `(group)`,
or a plain folder that only holds routes) can have a `data.dart` too. It is then
the data of the **whole section**: the layout waits for it, and the layout and
the pages below can take it.

```dart
// lib/teams.dart
class Team {
  const Team(this.id, this.name);

  final String id;
  final String name;
}

var teamLoads = 0;

Future<Team> fetchTeam(String id) async {
  teamLoads++;
  return Team(id, 'Team ${id.toUpperCase()}');
}
```

```dart
// lib/app/teams/$teamId/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/teams.dart';

Future<Team> data(Ref ref, {required String teamId}) => fetchTeam(teamId);
```

```dart
// lib/app/teams/$teamId/layout.dart
import 'package:flutter/material.dart';
import 'package:my_app/teams.dart';

// By type (or a parameter named `data`).
class TeamLayout extends StatelessWidget {
  const TeamLayout({super.key, required this.team, required this.child});

  final Team team;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Column(children: [Text('layout: ${team.name}'), child]);
}
```

```dart
// lib/app/teams/$teamId/members/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/teams.dart';

// The page takes the section's data by type as well.
class MembersPage extends StatelessWidget {
  const MembersPage(this.team, {super.key});

  final Team team;

  @override
  Widget build(BuildContext context) => Text('members of ${team.id}');
}
```

```dart
// lib/app/teams/$teamId/settings/page.dart
import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('settings');
}
```

```dart
// lib/app/teams/$teamId/not_found.dart
import 'package:flutter/material.dart';

// For unknown paths below /teams/:teamId. The segments of its own path arrive
// as Strings, as the URL spells them.
class TeamNotFound extends StatelessWidget {
  const TeamNotFound({super.key, required this.uri, required this.teamId});

  final Uri uri;
  final String teamId;

  @override
  Widget build(BuildContext context) =>
      Text('team $teamId has no ${uri.path}');
}
```

- **Loading and errors.** While the section loads, the nearest `loading.dart`
  (inherited as usual) replaces the layout **and** the pages inside it, and a
  failure shows the nearest `error.dart` with its `retry`. Nothing below is built
  until the data is there.
- **Sharing.** The layout watches the provider and the pages below read the
  **same one**, so `data()` runs **once** however many of them take it, and
  moving between the section's pages does not load it again. When the data
  reloads (`retry`, an invalidation), the section keeps showing what it has
  (`keep_previous`; with `keep_previous: false` it shows loading again).
- **Which one.** A parameter called `data` gets the **nearest** data: the
  route's own `data.dart`, then the section's, then the next section up. **By
  type**, a parameter gets the `data.dart` that yields that type, and it is an
  **error if two do** (a page's own and a section's, or two sections'): name the
  parameter `data` for the nearest, or give one of them another type. A page can
  have its own `data.dart` and take a section's by type.
- **Where it applies.** A layout of any kind can be a section's, tab layouts
  included. A `data.dart` beside a `page.dart` keeps feeding that page, so the
  folder that holds the section's layout **must not have a page**.
- **A section's data can be any of the three forms** (function, selector or
  your own provider), keyed by segments at or above its folder and by query
  parameters.

## Query keys

A section's `data()` takes segments (at or above its folder) and, like a page's,
**query parameters**. The layout reads them from the URL like any layout query
parameter, and **every route below the section is keyed by it too**: `period`
becomes a query parameter of each of their typed routes, so the pages read the
same provider the layout loaded. A page that declares the same name with another
type is an error.

```dart
// lib/app/reports/data.dart
import 'package:fespalier/fespalier.dart';

Future<String> data(Ref ref, {String? period}) async => 'report ${period ?? 'all'}';
```

```dart
// lib/app/reports/layout.dart
import 'package:flutter/material.dart';

class ReportsLayout extends StatelessWidget {
  const ReportsLayout({super.key, required this.data, required this.child});

  final String data;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Column(children: [Text(data), child]);
}
```

```dart
// lib/app/reports/monthly/page.dart
import 'package:flutter/material.dart';

class MonthlyReportPage extends StatelessWidget {
  const MonthlyReportPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('monthly');
}
```

`MonthlyReportRoute(period: '2026-01')` writes `/reports/monthly?period=2026-01`.

## The typed handle

A section has no route of its own, so it gets a class named after its folder with
`Section` on the end: `teams/$teamId` is `TeamsTeamIdSection`, `(shop)` is
`ShopSection`, the app folder itself `RootSection`; `(group)` folders add
nothing to the name, and two folders that would name the same class are an
error (``the section's typed handle `X` is already taken by ...``). Its members
are **static** and take the section's keys as named arguments, like a route's:

```dart
TeamsTeamIdSection.data('acme');                          // the provider
TeamsTeamIdSection.watch(ref, teamId: 'acme');            // AsyncValue<Team>
await TeamsTeamIdSection.read(ref, teamId: 'acme');       // Future<Team>
final h = TeamsTeamIdSection.prefetch(ref, teamId: 'acme'); // PrefetchHandle
await TeamsTeamIdSection.refresh(ref, teamId: 'acme');
```

A key cannot be called `ref`, `keepFor` or another member of the handle
(`` `read` can't be a key of a section's data.dart ... ``). A section keyed by
**a query parameter** has it as a named argument too
(`ReportsSection.watch(ref, period: '2026-01')`).

## Section data in lookups

`AppRoutes.dataAt(uri)` lists the providers **outermost first**: the `data.dart`
of each section above the route, then its own. So the route of
`/teams/acme/members` has one (the section's, which the page also reads), and a
route with a `data.dart` below a section has two. Warming the list warms the
page and its layout (see `prefetch-and-lookup.md`).
