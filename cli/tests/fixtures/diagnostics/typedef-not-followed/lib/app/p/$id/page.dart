import 'package:common/json.dart';
import 'package:flutter/widgets.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.id, required this.data});

  final int id;
  final JsonMap data;

  @override
  Widget build(BuildContext context) => Text('$id');
}
