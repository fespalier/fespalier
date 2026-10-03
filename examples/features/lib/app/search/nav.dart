import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(label: 'Search', icon: Icons.search, order: 1);

/// The label a menu shows, for the language of the app: it gets a `BuildContext`.
/// `Nav.label` is what `fsp routes` and a test without a context see.
String label(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'fr' => 'Recherche',
      _ => 'Search',
    };
