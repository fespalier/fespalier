import 'package:flutter/material.dart';

class ReviewsPage extends StatelessWidget {
  const ReviewsPage({super.key, required this.reviews});

  final List<String> reviews;

  @override
  Widget build(BuildContext context) => Text(reviews.join(' | '));
}
