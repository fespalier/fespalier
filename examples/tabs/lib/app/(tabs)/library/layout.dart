import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// A tab layout inside a branch of `(tabs)/layout.dart`: `library/` is one of
/// the outer tabs, and Books and Authors are tabs of their own. Each keeps its
/// state while you look at the other, and the outer layout keeps this whole
/// tab alive while you look at Home.
const tabs = ['books', 'authors'];

/// Books is built as soon as the Library tab is, even when it opens on Authors.
const tabOptions = {'books': TabOptions(preload: true)};

class LibraryLayout extends StatelessWidget {
  const LibraryLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SafeArea(
            bottom: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final (i, label) in ['Books', 'Authors'].indexed)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: navigationShell.currentIndex == i,
                      onSelected: (_) => navigationShell.goBranch(
                        i,
                        initialLocation: i == navigationShell.currentIndex,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: navigationShell),
        ],
      );
}
