import 'dart:ui' as ui;

import 'package:anx_reader/widgets/reading_page/page_curl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(390, 844);
  final corners = [
    Offset.zero,
    const Offset(390, 0),
    const Offset(0, 844),
    const Offset(390, 844),
  ];

  group('curlFold', () {
    test('a flat page has no fold', () {
      expect(curlFold(size, 0), isNull);
    });

    test('folding lays the corner exactly where it was pulled', () {
      for (final progress in [0.1, 0.4, 0.7]) {
        final fold = curlFold(size, progress)!;
        final corner = corners.last;
        final landed = fold.reflect(corner);
        // The corner is on the lifted side, lands on the flat side, and the
        // crease is equidistant from both.
        expect(fold.side(corner), greaterThan(0));
        expect(fold.side(landed), closeTo(-fold.side(corner), 1e-6));
        expect(fold.reflect(landed).dx, closeTo(corner.dx, 1e-6));
        expect(fold.reflect(landed).dy, closeTo(corner.dy, 1e-6));
      }
    });

    test('points on the crease stay put', () {
      final fold = curlFold(size, 0.5)!;
      final onCrease = fold.origin + Offset(-fold.normal.dy, fold.normal.dx) * 120;
      final folded = fold.reflect(onCrease);
      expect(folded.dx, closeTo(onCrease.dx, 1e-6));
      expect(folded.dy, closeTo(onCrease.dy, 1e-6));
    });

    test('the lifted part grows as the turn goes on', () {
      int liftedCorners(double progress) =>
          corners.where((c) => curlFold(size, progress)!.side(c) > 0).length;
      expect(liftedCorners(0.05), 1);
      expect(liftedCorners(1), 4);
    });

    test('a finished turn lays the whole page off screen', () {
      final fold = curlFold(size, 1)!;
      for (final corner in corners) {
        expect(fold.reflect(corner).dx, lessThanOrEqualTo(0));
      }
    });
  });

  testWidgets('covers, turns away and clears', (tester) async {
    final key = GlobalKey<PageCurlOverlayState>();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: PageCurlOverlay(key: key),
    ));
    final image = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 39, 84), Paint()..color = Colors.teal);
      return recorder.endRecording().toImage(39, 84);
    }))!;

    key.currentState!.cover(image);
    await tester.pump();
    expect(key.currentState!.covering, isTrue);
    expect(find.byType(CustomPaint), findsOneWidget);

    final turned = key.currentState!.turnAway();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    await turned;
    expect(key.currentState!.covering, isFalse);
    expect(find.byType(CustomPaint), findsNothing);
  });
}
