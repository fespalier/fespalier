/// A pretend backend, so the example needs no network.
class Item {
  const Item(this.id, this.name);

  final int id;
  final String name;
}

class ItemNotFound implements Exception {
  const ItemNotFound(this.id);

  final int id;

  @override
  String toString() => 'No item #$id';
}

const _catalog = {1: 'Teapot', 2: 'Kettle', 3: 'Whisk'};

/// Takes a moment, like a real request; fails for an id that isn't in
/// [_catalog].
Future<Item> fetchItem(int id) async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final name = _catalog[id];
  if (name == null) throw ItemNotFound(id);
  return Item(id, name);
}
