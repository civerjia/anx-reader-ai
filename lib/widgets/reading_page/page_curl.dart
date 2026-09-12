import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Where a turning page is folded: the fold line passes through [origin], and
/// [normal] points from it into the part of the page that has lifted off.
class CurlFold {
  const CurlFold(this.origin, this.normal);

  final Offset origin;
  final Offset normal;

  /// Positive on the lifted side of the fold, negative on the side lying flat.
  double side(Offset point) {
    final offset = point - origin;
    return offset.dx * normal.dx + offset.dy * normal.dy;
  }

  /// Where [point] lands once the lifted part is folded over.
  Offset reflect(Offset point) => point - normal * (2 * side(point));
}

/// The fold of a page of [size] lifted by its bottom-right corner, at
/// [progress] from 0 (flat) to 1 (turned away past the left edge); null while
/// flat.
///
/// The corner is pulled towards the left along a slight arc. The fold is the
/// perpendicular bisector of the corner and the point it has been pulled to,
/// which is exactly where a sheet creases when that corner is laid there.
CurlFold? curlFold(Size size, double progress) {
  if (progress <= 0) return null;
  final t = math.min(progress, 1.0);
  final corner = Offset(size.width, size.height);
  final pulled = Offset(
    size.width - 2.5 * size.width * t,
    size.height - 0.2 * size.height * math.sin(math.pi * t),
  );
  final delta = corner - pulled;
  final length = delta.distance;
  if (length < 1e-6) return null;
  return CurlFold((corner + pulled) / 2, delta / length);
}

class PageCurlPainter extends CustomPainter {
  PageCurlPainter({required this.page, this.under, required this.progress});

  final ui.Image page;
  final ui.Image? under;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final imagePaint = Paint()..filterQuality = FilterQuality.medium;
    Rect sourceOf(ui.Image image) =>
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());

    final under = this.under;
    if (under != null) {
      canvas.drawImageRect(under, sourceOf(under), bounds, imagePaint);
    }

    final fold = curlFold(size, progress);
    if (fold == null) {
      canvas.drawImageRect(page, sourceOf(page), bounds, imagePaint);
      return;
    }

    final reach = 4.0 * math.max(size.width, size.height);
    Path halfPlane(double towards) {
      final along = Offset(-fold.normal.dy, fold.normal.dx) * reach;
      final away = fold.normal * (reach * towards);
      final a = fold.origin + along;
      final b = fold.origin - along;
      return Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo((b + away).dx, (b + away).dy)
        ..lineTo((a + away).dx, (a + away).dy)
        ..close();
    }

    final pagePath = Path()..addRect(bounds);
    final flat = Path.combine(PathOperation.intersect, pagePath, halfPlane(-1));
    final lifted =
        Path.combine(PathOperation.intersect, pagePath, halfPlane(1));
    final lift = math.sin(math.pi * math.min(progress, 1.0));

    // Shadow the lifted page casts just past the crease.
    canvas.save();
    canvas.clipPath(lifted);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.linear(
          fold.origin,
          fold.origin + fold.normal * (16 + 36 * lift),
          [const Color(0x59000000), const Color(0x00000000)],
        ),
    );
    canvas.restore();

    // The part still lying flat, darkening into the crease.
    canvas.save();
    canvas.clipPath(flat);
    canvas.drawImageRect(page, sourceOf(page), bounds, imagePaint);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.linear(
          fold.origin,
          fold.origin - fold.normal * 28,
          [const Color(0x2E000000), const Color(0x00000000)],
        ),
    );
    canvas.restore();

    // The lifted part folded over: the back of the sheet, with the print
    // showing through mirrored.
    final n = fold.normal;
    final d = fold.origin.dx * n.dx + fold.origin.dy * n.dy;
    final reflection = Matrix4.identity()
      ..setEntry(0, 0, 1 - 2 * n.dx * n.dx)
      ..setEntry(0, 1, -2 * n.dx * n.dy)
      ..setEntry(1, 0, -2 * n.dx * n.dy)
      ..setEntry(1, 1, 1 - 2 * n.dy * n.dy)
      ..setEntry(0, 3, 2 * d * n.dx)
      ..setEntry(1, 3, 2 * d * n.dy);
    canvas.save();
    canvas.transform(reflection.storage);
    canvas.clipPath(lifted);
    canvas.drawImageRect(page, sourceOf(page), bounds, imagePaint);
    canvas.drawRect(bounds, Paint()..color = const Color(0xD6F2EFE8));
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.linear(
          fold.origin,
          fold.origin + n * 44,
          [const Color(0x40000000), const Color(0x00000000)],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(PageCurlPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.page != page ||
      oldDelegate.under != under;
}

/// Draws page turns as a curl over the reader.
///
/// The overlay only ever shows snapshots. To turn forward, cover the reader
/// with a snapshot of the page, turn the reader underneath, then [turnAway]
/// the snapshot to reveal it. To turn back, cover, turn, snapshot the page the
/// reader now shows, and [bringBack] that page down over the covering one.
class PageCurlOverlay extends StatefulWidget {
  const PageCurlOverlay({super.key});

  static const duration = Duration(milliseconds: 450);

  @override
  State<PageCurlOverlay> createState() => PageCurlOverlayState();
}

class PageCurlOverlayState extends State<PageCurlOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress =
      AnimationController(vsync: this, duration: PageCurlOverlay.duration);
  ui.Image? _page;
  ui.Image? _under;

  bool get covering => _page != null;

  /// Holds [page] flat over the reader so the reader can change underneath.
  /// The overlay owns the image from here on.
  void cover(ui.Image page) {
    _release();
    _progress.value = 0;
    setState(() => _page = page);
  }

  /// Turns the covering page away, revealing the reader beneath.
  Future<void> turnAway() async {
    if (_page == null) return;
    try {
      await _progress
          .animateTo(1, curve: Curves.easeInOut)
          .orCancel;
    } on TickerCanceled {
      return;
    }
    clear();
  }

  /// Lays [page] down over the covering page, the way a page comes back.
  Future<void> bringBack(ui.Image page) async {
    final covered = _page;
    if (covered == null) {
      page.dispose();
      return;
    }
    _progress.value = 1;
    setState(() {
      _under = covered;
      _page = page;
    });
    try {
      await _progress
          .animateBack(0, curve: Curves.easeInOut)
          .orCancel;
    } on TickerCanceled {
      return;
    }
    clear();
  }

  void clear() {
    if (!mounted) {
      _release();
      return;
    }
    setState(_release);
  }

  void _release() {
    _page?.dispose();
    _under?.dispose();
    _page = null;
    _under = null;
  }

  @override
  void dispose() {
    _progress.dispose();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final page = _page;
        if (page == null) return const SizedBox.shrink();
        return SizedBox.expand(
          child: CustomPaint(
            painter: PageCurlPainter(
              page: page,
              under: _under,
              progress: _progress.value,
            ),
          ),
        );
      },
    );
  }
}
