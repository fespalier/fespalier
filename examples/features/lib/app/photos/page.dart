import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

/// The page the dialog, sheet and full-screen routes below it open over. It
/// keeps its state (the "liked" flag) while they are on top.
class PhotosPage extends StatefulWidget {
  const PhotosPage({super.key});

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> {
  bool _liked = false;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Photos'),
        Text('Liked: ${_liked ? 'yes' : 'no'}'),
        TextButton(
          onPressed: () => setState(() => _liked = !_liked),
          child: const Text('Like'),
        ),
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
        TextButton(
          onPressed: () => const ShareSheetRoute().push(context),
          child: const Text('Share'),
        ),
      ],
    ),
  );
}
