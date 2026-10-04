import 'package:fespalier/fespalier.dart';
import 'package:fespalier_adaptive/fespalier_adaptive.dart';
import 'package:flutter/material.dart';
import 'package:tabs/app.g.dart';

/// A tab layout inside a branch of `(tabs)/layout.dart`: `library/` is one of
/// the outer tabs, and Books and Authors are tabs of their own. Each keeps its
/// state while you look at the other, and the outer layout keeps this whole
/// tab alive while you look at Home.
const tabs = ['books', 'authors'];

/// Books is built as soon as the Library tab is, even when it opens on Authors.
const tabOptions = {'books': TabOptions(preload: true)};

/// The chips are the menu too: `AdaptiveNavBuilder` hands the entries below `library/` to a
/// builder that draws them as it likes (`AdaptiveNavScaffold` is the Material bar, rail and
/// drawer). The model is the same at every width, so there are no breakpoints to say here.
class LibraryLayout extends StatelessWidget {
  const LibraryLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => AdaptiveNavBuilder(
        menu: (ref) => AppMenu.watch(ref, under: '(tabs)/library'),
        shell: navigationShell,
        breakpoints: const NavBreakpoints(rail: null, drawer: null),
        builder: (context, nav) => Column(
          children: [
            SafeArea(
              bottom: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final (i, item) in nav.destinations.indexed)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: ChoiceChip(
                        label: Text(item.label(context)),
                        selected: nav.selectedIndex == i,
                        // goBranch: the current chip again goes back to its first page.
                        onSelected: (_) => nav.select(context, i),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(child: navigationShell),
          ],
        ),
      );
}
