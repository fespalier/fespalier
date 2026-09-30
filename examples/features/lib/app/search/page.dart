import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

class SearchPage extends StatelessWidget {
  const SearchPage({
    super.key,
    required this.results,
    this.q,
    this.page,
    this.tags = const [],
  });

  /// Required, and what data.dart yields: the data.
  final List<String> results;

  /// Optional and nullable, or a List: query parameters.
  final String? q;
  final int? page;
  final List<String> tags;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
              '${q ?? 'everything'}, page ${page ?? 1}: ${results.join(', ')}'),
          Text('tags: ${tags.join(', ')}'),
          TextButton(
            onPressed: () =>
                SearchRoute(q: q, page: (page ?? 1) + 1, tags: tags)
                    .go(context),
            child: const Text('Next'),
          ),
        ],
      );
}
