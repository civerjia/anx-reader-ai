/// A book's place in a series, as the book's own metadata states it.
class BookSeries {
  const BookSeries(this.name, [this.position]);

  final String name;
  final double? position;

  /// "Name #2", or just the name when the book gives no position.
  String get label {
    final position = this.position;
    if (position == null) return name;
    final number = position == position.truncateToDouble()
        ? position.toInt().toString()
        : position.toString();
    return '$name #$number';
  }

  @override
  bool operator ==(Object other) =>
      other is BookSeries && other.name == name && other.position == position;

  @override
  int get hashCode => Object.hash(name, position);

  @override
  String toString() => 'BookSeries($name, $position)';
}
