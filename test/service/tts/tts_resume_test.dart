import 'package:anx_reader/service/tts/tts_resume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each book keeps one point, the latest', () {
    var points = withResumePoint({}, 7, 'epubcfi(/6/8!/4/2)');
    points = withResumePoint(points, 7, 'epubcfi(/6/8!/4/9)');
    expect(points, {'7': 'epubcfi(/6/8!/4/9)'});
  });

  test('saving a book again makes it the newest', () {
    var points = withResumePoint({}, 1, 'a');
    points = withResumePoint(points, 2, 'b');
    points = withResumePoint(points, 1, 'c');
    expect(points.keys.toList(), ['2', '1']);
  });

  test('the oldest books drop off past the limit', () {
    var points = <String, String>{};
    for (var id = 1; id <= 5; id++) {
      points = withResumePoint(points, id, 'cfi$id', limit: 3);
    }
    expect(points.keys.toList(), ['3', '4', '5']);
  });

  test('the input is never modified', () {
    final original = {'1': 'a'};
    withResumePoint(original, 2, 'b');
    expect(original, {'1': 'a'});
  });
}
