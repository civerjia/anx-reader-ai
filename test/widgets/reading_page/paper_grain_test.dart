import 'dart:math' as math;

import 'package:anx_reader/widgets/reading_page/paper_grain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = 128;
  final watch = Stopwatch()..start();
  final pixels = paperGrainPixels(size: size);
  // Signed strength: dark negative, light positive.
  double at(int x, int y) {
    final i = (y * size + x) * 4;
    final alpha = pixels[i + 3] / 255;
    return pixels[i] > 0 ? alpha : -alpha;
  }

  test('generation is quick enough to run once', () {
    final full = Stopwatch()..start();
    paperGrainPixels();
    // ignore: avoid_print
    print('128 px: ${watch.elapsedMilliseconds} ms (with first test), '
        '512 px: ${full.elapsedMilliseconds} ms');
    expect(full.elapsedMilliseconds, lessThan(3000));
  });

  test('the grain is not uniform', () {
    final values = [
      for (var y = 0; y < size; y++)
        for (var x = 0; x < size; x++) at(x, y)
    ];
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance =
        values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
            values.length;
    expect(math.sqrt(variance), greaterThan(0.03));
    // Faint: never close to covering the paper.
    expect(values.map((v) => v.abs()).reduce(math.max), lessThan(0.2));
  });

  test('the tile wraps without a seam', () {
    double step(int x0, int y0, int x1, int y1) => (at(x0, y0) - at(x1, y1)).abs();
    var inside = 0.0;
    var across = 0.0;
    for (var y = 0; y < size; y++) {
      inside += step(size ~/ 2, y, size ~/ 2 + 1, y);
      across += step(size - 1, y, 0, y);
    }
    for (var x = 0; x < size; x++) {
      inside += step(x, size ~/ 2, x, size ~/ 2 + 1);
      across += step(x, size - 1, x, 0);
    }
    expect(across, lessThan(inside * 2));
  });

  test('the same seed gives the same grain', () {
    expect(paperGrainPixels(size: size), pixels);
  });
}
