import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:anx_reader/widgets/reading_page/page_curl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(390, 844);
  final radius = curlRadius(size.width);
  final corners = [
    Offset.zero,
    const Offset(390, 0),
    const Offset(0, 844),
    const Offset(390, 844),
  ];

  group('curl follows the finger', () {
    test('a page not pulled is flat', () {
      expect(curlAxis(const Offset(390, 600), const Offset(390, 600), radius),
          isNull);
    });

    for (final finger in const [
      Offset(380, 600), // barely pulled, still on the roll
      Offset(300, 620), // pulled less than a half turn
      Offset(120, 560), // well past it, and tilted
      Offset(-200, 700), // most of the page turned
    ]) {
      test('the grabbed point lands under the finger at $finger', () {
        const grab = Offset(390, 600);
        final axis = curlAxis(grab, finger, radius)!;
        final landed = curlPoint(grab, axis, radius).position;
        expect(landed.dx, closeTo(finger.dx, 0.01));
        expect(landed.dy, closeTo(finger.dy, 0.01));
      });
    }

    test('the page behind the axis does not move', () {
      final axis = curlAxis(const Offset(390, 600), const Offset(200, 600), radius)!;
      const flat = Offset(20, 300);
      expect(axis.distance(flat), lessThan(0));
      expect(curlPoint(flat, axis, radius).position, flat);
    });

    test('points on the roll stay within one radius of the axis', () {
      final axis = curlAxis(const Offset(390, 600), const Offset(200, 600), radius)!;
      for (var d = 1.0; d < math.pi * radius; d += 5) {
        final point = axis.origin + axis.normal * d;
        final curled = curlPoint(point, axis, radius);
        expect(axis.distance(curled.position), lessThanOrEqualTo(radius + 1e-6));
        expect(curled.angle, closeTo(d / radius, 1e-9));
      }
    });

    test('the turned-away finger leaves every corner face down', () {
      const grab = Offset(390, 760);
      final axis = curlAxis(grab, turnedAwayFinger(size, grab), radius)!;
      for (final corner in corners) {
        expect(curlPoint(corner, axis, radius).angle, math.pi);
        expect(curlPoint(corner, axis, radius).position.dx, lessThan(0));
      }
    });
  });

  group('mesh', () {
    test('a flat page is all face up and textured edge to edge', () {
      final mesh = CurlMesh.build(size, const Size(1170, 2532), null, radius);
      expect(mesh.back, isEmpty);
      expect(mesh.textureCoordinates.last, closeTo(2532, 1e-3));
      expect(mesh.positions.length ~/ 2, mesh.angles.length);
    });

    test('mid-turn some triangles are face down, all indices valid', () {
      final axis = curlAxis(const Offset(390, 600), const Offset(150, 640), radius);
      final mesh = CurlMesh.build(size, size, axis, radius);
      expect(mesh.back, isNotEmpty);
      expect(mesh.front, isNotEmpty);
      final vertices = mesh.angles.length;
      expect([...mesh.front, ...mesh.back].every((i) => i < vertices), isTrue);
      expect((mesh.front.length + mesh.back.length) % 3, 0);
    });
  });

  testWidgets('paints a curl and settles away', (tester) async {
    final key = GlobalKey<PageCurlOverlayState>();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: PageCurlOverlay(key: key, paper: const Color(0xFFFBFBF3)),
    ));
    final image = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 80, 160), Paint()..color = Colors.teal);
      return recorder.endRecording().toImage(80, 160);
    }))!;
    final state = key.currentState!;
    final grab = Offset(state.size.width, state.size.height * 0.8);
    state.curl(page: image, grab: grab, finger: grab);
    await tester.pump();
    state.moveFinger(grab - const Offset(200, 0));
    await tester.pump();
    expect(tester.takeException(), isNull);

    final settled = state.settle(turnedAwayFinger(state.size, grab));
    await tester.pumpAndSettle();
    await settled;
    expect(state.finger!.dx, lessThan(0));
    state.clear();
    await tester.pump();
    expect(state.active, isFalse);
  });
}
