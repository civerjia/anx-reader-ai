import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/material.dart';

/// The line a page rolls around. The page lies flat on the side against
/// [normal]; past [origin] along [normal] it wraps around a cylinder of the
/// curl radius and then lies face down on top of itself.
class CurlAxis {
  const CurlAxis(this.origin, this.normal);

  final Offset origin;
  final Offset normal;

  /// Distance of [point] past the axis, towards the lifted edge.
  double distance(Offset point) {
    final offset = point - origin;
    return offset.dx * normal.dx + offset.dy * normal.dy;
  }
}

/// Where a point of the page appears once curled, and how far round the
/// cylinder it has gone: 0 lying flat, up to pi when face down on top.
class CurlPoint {
  const CurlPoint(this.position, this.angle);

  final Offset position;
  final double angle;
}

CurlPoint curlPoint(Offset point, CurlAxis axis, double radius) {
  final d = axis.distance(point);
  if (d <= 0) return CurlPoint(point, 0);
  final foot = point - axis.normal * d;
  if (d < math.pi * radius) {
    final angle = d / radius;
    return CurlPoint(foot + axis.normal * (radius * math.sin(angle)), angle);
  }
  return CurlPoint(foot - axis.normal * (d - math.pi * radius), math.pi);
}

/// The axis that puts the page point [grab] under the [finger]: the edge the
/// reader took hold of goes wherever the finger goes. Null while the page is
/// flat.
CurlAxis? curlAxis(Offset grab, Offset finger, double radius) {
  final delta = grab - finger;
  final pulled = delta.distance;
  if (pulled < 0.5) return null;
  final normal = delta / pulled;
  final halfTurn = math.pi * radius;
  double reach;
  if (pulled >= halfTurn) {
    // The grabbed point is face down on top: it sits as far before the axis as
    // it originally was past the half turn.
    reach = (pulled + halfTurn) / 2;
  } else {
    // Still on the cylinder: solve reach - r sin(reach / r) = pulled, which
    // rises steadily from 0 to a half turn.
    var low = 0.0;
    var high = halfTurn;
    for (var i = 0; i < 40; i++) {
      final mid = (low + high) / 2;
      if (mid - radius * math.sin(mid / radius) < pulled) {
        low = mid;
      } else {
        high = mid;
      }
    }
    reach = (low + high) / 2;
  }
  return CurlAxis(grab - normal * reach, normal);
}

/// Curl radius for a page [width] wide.
double curlRadius(double width) => width * 0.1;

/// A finger position that has turned the whole page, grabbed at [grab], face
/// down past the left edge.
Offset turnedAwayFinger(Size size, Offset grab) =>
    Offset(-(1.25 * size.width + math.pi * curlRadius(size.width)), grab.dy);

/// The finger position of a page turned back over, with only its roll showing
/// at the left edge: where a previous page waits before it is laid down.
Offset rolledAtLeftFinger(Size size, Offset grab) =>
    Offset(math.pi * curlRadius(size.width) - size.width - 1, grab.dy);

/// Turning back to the previous page: the page starts rolled up at the left
/// edge and unrolls as the finger moves right, wherever the finger went down
/// (a drag from the very edge is the system's back gesture, not a page turn).
/// [progress] runs from 0 at [start] to 1 at the right edge, where the page
/// lies flat; the finger's height still tilts the roll.
({double progress, Offset finger}) backTurnFinger({
  required Size size,
  required Offset grab,
  required Offset start,
  required Offset point,
}) {
  final span = math.max(1.0, size.width - start.dx);
  final progress = ((point.dx - start.dx) / span).clamp(0.0, 1.0).toDouble();
  final from = rolledAtLeftFinger(size, grab);
  return (
    progress: progress,
    finger: Offset(from.dx + (grab.dx - from.dx) * progress, point.dy),
  );
}

/// Triangles of a page of [size] curled around [axis], textured from an image
/// of [imageSize]. [front] holds the triangles facing up, [back] those turned
/// face down, which have to be drawn over the front ones.
class CurlMesh {
  CurlMesh._(this.positions, this.textureCoordinates, this.angles, this.front,
      this.back);

  final Float32List positions;
  final Float32List textureCoordinates;
  final Float32List angles;
  final Uint16List front;
  final Uint16List back;

  factory CurlMesh.build(
    Size size,
    Size imageSize,
    CurlAxis? axis,
    double radius, {
    int columns = 32,
  }) {
    final rows =
        math.max(2, (columns * size.height / size.width).round()).toInt();
    final count = (columns + 1) * (rows + 1);
    final positions = Float32List(count * 2);
    final textures = Float32List(count * 2);
    final angles = Float32List(count);
    final sx = imageSize.width / size.width;
    final sy = imageSize.height / size.height;
    var v = 0;
    for (var row = 0; row <= rows; row++) {
      for (var column = 0; column <= columns; column++) {
        final point = Offset(
            size.width * column / columns, size.height * row / rows);
        final curled =
            axis == null ? CurlPoint(point, 0) : curlPoint(point, axis, radius);
        positions[v * 2] = curled.position.dx;
        positions[v * 2 + 1] = curled.position.dy;
        textures[v * 2] = point.dx * sx;
        textures[v * 2 + 1] = point.dy * sy;
        angles[v] = curled.angle;
        v++;
      }
    }
    final front = <int>[];
    final back = <int>[];
    void triangle(int a, int b, int c) {
      final target =
          (angles[a] + angles[b] + angles[c]) / 3 > math.pi / 2 ? back : front;
      target
        ..add(a)
        ..add(b)
        ..add(c);
    }

    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        final topLeft = row * (columns + 1) + column;
        final bottomLeft = topLeft + columns + 1;
        triangle(topLeft, topLeft + 1, bottomLeft);
        triangle(topLeft + 1, bottomLeft + 1, bottomLeft);
      }
    }
    return CurlMesh._(positions, textures, angles, Uint16List.fromList(front),
        Uint16List.fromList(back));
  }
}

class PageCurlPainter extends CustomPainter {
  PageCurlPainter({
    required this.page,
    required this.under,
    required this.grab,
    required this.finger,
    required this.paper,
  });

  final ui.Image page;
  final ui.Image? under;
  final Offset? grab;
  final Offset? finger;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final under = this.under;
    if (under != null) {
      canvas.drawImageRect(
          under,
          Rect.fromLTWH(0, 0, under.width.toDouble(), under.height.toDouble()),
          bounds,
          Paint()..filterQuality = FilterQuality.medium);
    }

    final radius = curlRadius(size.width);
    final grab = this.grab;
    final finger = this.finger;
    final axis =
        grab == null || finger == null ? null : curlAxis(grab, finger, radius);

    if (axis != null) {
      // Shadow the roll casts on the page beneath, just past its outer edge.
      final edge = axis.origin + axis.normal * radius;
      final halfPlane = Path()
        ..addPolygon(_halfPlane(edge, axis.normal, size), true);
      canvas.save();
      canvas.clipPath(halfPlane);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.linear(
            edge,
            edge + axis.normal * (radius * 1.2),
            [const Color(0x66000000), const Color(0x00000000)],
          ),
      );
      canvas.restore();
    }

    final mesh = CurlMesh.build(
      size,
      Size(page.width.toDouble(), page.height.toDouble()),
      axis,
      radius,
    );
    final texture = ImageShader(page, TileMode.clamp, TileMode.clamp,
        Matrix4.identity().storage,
        filterQuality: FilterQuality.medium);

    // Face up: the print, darkening as the paper rolls away from the light.
    final count = mesh.angles.length;
    final frontColors = Int32List(count);
    final backShade = Int32List(count);
    for (var i = 0; i < count; i++) {
      final angle = mesh.angles[i];
      final up = math.min(angle, math.pi / 2) / (math.pi / 2);
      final light = (255 * (1 - 0.45 * math.pow(up, 1.6))).round();
      frontColors[i] = 0xFF000000 | (light << 16) | (light << 8) | light;
      final down = angle <= math.pi / 2
          ? 1.0
          : 1 - (angle - math.pi / 2) / (math.pi / 2);
      final alpha = (255 * 0.35 * down).round();
      backShade[i] = alpha << 24;
    }
    if (mesh.front.isNotEmpty) {
      canvas.drawVertices(
        ui.Vertices.raw(
          VertexMode.triangles,
          mesh.positions,
          textureCoordinates: mesh.textureCoordinates,
          colors: frontColors,
          indices: mesh.front,
        ),
        BlendMode.modulate,
        Paint()..shader = texture,
      );
    }

    // Face down: the back of the sheet, the print faintly showing through
    // mirrored, shaded where it bends over. Drawn in layers with vertex colours
    // only: a colour filter on drawVertices was ignored on the phone, and the
    // back showed the page as crisp as the front.
    if (mesh.back.isNotEmpty) {
      canvas.drawVertices(
        ui.Vertices.raw(
          VertexMode.triangles,
          mesh.positions,
          textureCoordinates: mesh.textureCoordinates,
          indices: mesh.back,
        ),
        BlendMode.src,
        Paint()..shader = texture,
      );
      // Paper over the print: how much of it still shows through.
      const through = 0.18;
      final veil = Int32List(count);
      final paperArgb = (((1 - through) * 255).round() << 24) |
          ((paper.r * 255).round() << 16) |
          ((paper.g * 255).round() << 8) |
          (paper.b * 255).round();
      veil.fillRange(0, count, paperArgb);
      canvas.drawVertices(
        ui.Vertices.raw(
          VertexMode.triangles,
          mesh.positions,
          colors: veil,
          indices: mesh.back,
        ),
        BlendMode.dst,
        Paint(),
      );
      canvas.drawVertices(
        ui.Vertices.raw(
          VertexMode.triangles,
          mesh.positions,
          colors: backShade,
          indices: mesh.back,
        ),
        BlendMode.dst,
        Paint(),
      );
    }
  }

  static List<Offset> _halfPlane(Offset through, Offset normal, Size size) {
    final reach = 4.0 * math.max(size.width, size.height);
    final along = Offset(-normal.dy, normal.dx) * reach;
    final away = normal * reach;
    return [
      through + along,
      through - along,
      through - along + away,
      through + along + away,
    ];
  }

  @override
  bool shouldRepaint(PageCurlPainter oldDelegate) =>
      oldDelegate.page != page ||
      oldDelegate.under != under ||
      oldDelegate.grab != grab ||
      oldDelegate.finger != finger ||
      oldDelegate.paper != paper;
}

/// Draws a page curl over the reader from snapshots, following a finger.
///
/// The overlay holds a curling [page] image, optionally over an [under]
/// image; where neither covers, the reader shows through. The page is held at
/// a grab point on its edge, and that point follows the finger.
class PageCurlOverlay extends StatefulWidget {
  const PageCurlOverlay({super.key, required this.paper});

  /// Colour of the paper, for the back of a turning page.
  final Color paper;

  @override
  State<PageCurlOverlay> createState() => PageCurlOverlayState();
}

class PageCurlOverlayState extends State<PageCurlOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settle =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
  ui.Image? _page;
  ui.Image? _under;
  Offset? _grab;
  Offset? _finger;

  bool get active => _page != null;

  Size get size => context.size ?? Size.zero;

  /// Covers the reader with [image] lying flat. The overlay owns it from here.
  void cover(ui.Image image) => curl(page: image, grab: null, finger: null);

  /// Shows [page] held at [grab] with that point under [finger], over [under].
  /// Images passed in are owned by the overlay; any it held and no longer
  /// shows are released.
  void curl({
    required ui.Image page,
    ui.Image? under,
    required Offset? grab,
    required Offset? finger,
  }) {
    _settle.stop();
    for (final old in [_page, _under]) {
      if (old != null && old != page && old != under) old.dispose();
    }
    setState(() {
      _page = page;
      _under = under;
      _grab = grab;
      _finger = finger;
    });
  }

  void moveFinger(Offset finger) {
    if (_grab == null || _settle.isAnimating) return;
    setState(() => _finger = finger);
  }

  Offset? get finger => _finger;

  /// Carries the finger to [target] as a hand letting go would.
  Future<void> settle(Offset target) async {
    final from = _finger ?? _grab;
    if (from == null || _grab == null) return;
    final width = math.max(size.width, 1.0);
    final ms = (380 * (target - from).distance / (1.5 * width)).clamp(140, 420);
    _settle.duration = Duration(milliseconds: ms.round());
    void follow() {
      final t = Curves.easeOutCubic.transform(_settle.value);
      setState(() => _finger = Offset.lerp(from, target, t));
    }

    _settle.addListener(follow);
    try {
      await _settle
          .forward(from: 0)
          .orCancel
          .timeout(_settle.duration! + const Duration(milliseconds: 500));
    } on TickerCanceled {
      // Interrupted by a new curl.
    } on TimeoutException {
      // The animation stopped advancing, and the page stayed half turned
      // until touched again. Finish the move without it.
      _settle.stop();
      AnxLog.info('Page curl: settle animation stalled; finishing without it');
      if (mounted) setState(() => _finger = target);
    } finally {
      _settle.removeListener(follow);
    }
  }

  void clear() {
    _settle.stop();
    void release() {
      _page?.dispose();
      _under?.dispose();
      _page = null;
      _under = null;
      _grab = null;
      _finger = null;
    }

    if (mounted) {
      setState(release);
    } else {
      release();
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    _page?.dispose();
    _under?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    if (page == null) return const SizedBox.expand();
    return SizedBox.expand(
      child: CustomPaint(
        painter: PageCurlPainter(
          page: page,
          under: _under,
          grab: _grab,
          finger: _finger,
          paper: widget.paper,
        ),
      ),
    );
  }
}
