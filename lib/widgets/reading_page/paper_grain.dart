import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Side of the grain tile, in pixels. It tiles seamlessly; at the size of a
/// page snapshot (about 1200 px wide) it repeats a little over twice, too few
/// times for the repeat to be seen in fibres this fine.
const paperGrainSize = 512;

/// Periodic 2D Perlin noise on a lattice of [period] cells, so the tile wraps.
class _Perlin {
  _Perlin(int seed) {
    final random = math.Random(seed);
    _perm = List<int>.generate(256, (i) => i)..shuffle(random);
  }

  late final List<int> _perm;

  double _gradient(int hash, double x, double y) {
    switch (hash & 7) {
      case 0:
        return x + y;
      case 1:
        return -x + y;
      case 2:
        return x - y;
      case 3:
        return -x - y;
      case 4:
        return x;
      case 5:
        return -x;
      case 6:
        return y;
      default:
        return -y;
    }
  }

  int _hash(int x, int y) => _perm[(_perm[x & 255] + y) & 255];

  static double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);

  /// Noise at (x, y) in lattice units, wrapping every [period] cells; roughly
  /// within -1..1.
  double at(double x, double y, int period) {
    final x0 = x.floor();
    final y0 = y.floor();
    final fx = x - x0;
    final fy = y - y0;
    final xa = x0 % period;
    final ya = y0 % period;
    final xb = (xa + 1) % period;
    final yb = (ya + 1) % period;
    final u = _fade(fx);
    final v = _fade(fy);
    final n00 = _gradient(_hash(xa, ya), fx, fy);
    final n10 = _gradient(_hash(xb, ya), fx - 1, fy);
    final n01 = _gradient(_hash(xa, yb), fx, fy - 1);
    final n11 = _gradient(_hash(xb, yb), fx - 1, fy - 1);
    final top = n00 + (n10 - n00) * u;
    final bottom = n01 + (n11 - n01) * u;
    return top + (bottom - top) * v;
  }
}

/// Premultiplied RGBA pixels of a paper grain tile: black and white at low
/// alpha, to lay over
/// the paper colour. Broad cloudy unevenness from several octaves of Perlin
/// noise, plus fine fibres from noise stretched along one direction.
Uint8List paperGrainPixels({int size = paperGrainSize, int seed = 7}) {
  final noise = _Perlin(seed);
  final fibres = _Perlin(seed + 1);
  final pixels = Uint8List(size * size * 4);
  const octaves = [
    // (cells across the tile, weight)
    (8, 0.45),
    (32, 0.30),
    (128, 0.25),
  ];
  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var cloud = 0.0;
      for (final (cells, weight) in octaves) {
        cloud += weight *
            noise.at(px * cells / size, py * cells / size, cells);
      }
      // Fibres: 256 cells across but only 32 down, so each is a short streak.
      final fibre = fibres.at(px * 256 / size, py * 32 / size, 256)
          .abs();
      final streak = math.max(0.0, 0.35 - fibre) / 0.35;
      final value = (cloud * 1.4 - streak * streak * 0.5).clamp(-1.0, 1.0);
      final i = (py * size + px) * 4;
      if (value < 0) {
        // Darker: a touch of black.
        pixels[i + 3] = (-value * 34).round();
      } else {
        // Lighter: a touch of white, gentler than the dark. Premultiplied, as
        // the image is read: full white at low alpha drew solid white blots.
        final alpha = (value * 20).round();
        pixels[i] = alpha;
        pixels[i + 1] = alpha;
        pixels[i + 2] = alpha;
        pixels[i + 3] = alpha;
      }
    }
  }
  return pixels;
}

Future<ui.Image>? _grain;

/// The grain tile, generated once off the UI isolate.
Future<ui.Image> paperGrainImage() {
  return _grain ??= () async {
    final pixels = await Isolate.run(paperGrainPixels);
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: paperGrainSize,
      height: paperGrainSize,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }();
}
