import 'package:fespalier/nav.dart';
import 'package:flutter/widgets.dart';

/// Not in the menu (it needs an order), but in the breadcrumbs of everything below it.
const nav = Nav(label: 'Order', inMenu: false);

/// `label()` can ask for the segments of its folder and above.
String label(BuildContext context, {required int id}) => 'Order #$id';
