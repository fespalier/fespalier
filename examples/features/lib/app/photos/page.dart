import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

/// The page the dialog, sheet and full-screen routes below it open over.
class PhotosPage extends StatelessWidget {
  const PhotosPage({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Photos'),
            TextButton(
              onPressed: () => const PhotoRoute(id: 7).push(context),
              child: const Text('Open photo 7'),
            ),
            TextButton(
              onPressed: () => const SortRoute().push(context),
              child: const Text('Sort'),
            ),
            TextButton(
              onPressed: () => const UploadRoute().push(context),
              child: const Text('Upload'),
            ),
          ],
        ),
      );
}
