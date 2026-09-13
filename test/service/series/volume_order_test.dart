import 'package:anx_reader/models/book_series.dart';
import 'package:anx_reader/service/series/volume_order.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('volume of a title', () {
    for (final (title, base, number) in const [
      ('三体Ⅱ：黑暗森林', '三体', 2.0),
      ('三体III 死神永生', '三体', 3.0),
      ('明朝那些事儿（第三部）', '明朝那些事儿', 3.0),
      ('明朝那些事儿 第7部', '明朝那些事儿', 7.0),
      ('平凡的世界（下）', '平凡的世界', 3.0),
      ('平凡的世界 上册', '平凡的世界', 1.0),
      ('资治通鉴 卷十二', '资治通鉴', 12.0),
      ('Dune II', 'Dune', 2.0),
      ('Harry Potter Vol. 4', 'Harry Potter', 4.0),
      ('进击的巨人 12', '进击的巨人', 12.0),
      ('进击的巨人（３）', '进击的巨人', 3.0),
      ('The Expanse #5: Nemesis Games', 'The Expanse', 5.0),
      ('冰与火之歌 卷二十一', '冰与火之歌', 21.0),
    ]) {
      test(title, () {
        final volume = volumeOfTitle(title);
        expect(volume, isNotNull);
        expect(volume!.base, base);
        expect(volume.number, number);
      });
    }

    for (final title in const ['活着', 'CIVIC Duty', '2', 'I', '上', '2024年度报告']) {
      test('no volume in $title', () => expect(volumeOfTitle(title), isNull));
    }
  });

  group('ordering a folder', () {
    List<String> order(List<String> titles, [Map<String, BookSeries>? series]) => orderVolumes(
          titles,
          title: (t) => t,
          series: series == null ? null : (t) => series[t],
        );

    test('volumes of one series in order, others keep their place', () {
      expect(
        order(['三体III 死神永生', '活着', '三体', '三体Ⅱ：黑暗森林', '三体Ⅰ']),
        ['三体Ⅰ', '三体Ⅱ：黑暗森林', '三体III 死神永生', '活着', '三体'],
      );
    });

    test('two series each in order, gathered where their first stood', () {
      expect(
        order(['平凡的世界（下）', '明朝那些事儿 第2部', '平凡的世界（上）', '明朝那些事儿 第1部', '平凡的世界（中）']),
        ['平凡的世界（上）', '平凡的世界（中）', '平凡的世界（下）', '明朝那些事儿 第1部', '明朝那些事儿 第2部'],
      );
    });

    test('series position from the book wins over the title', () {
      expect(
        order(['Leviathan Wakes', "Caliban's War", 'Abaddon'], {
          'Leviathan Wakes': const BookSeries('The Expanse', 1),
          "Caliban's War": const BookSeries('The Expanse', 2),
          'Abaddon': const BookSeries('The Expanse', 3),
        }.map((k, v) => MapEntry(k, v))),
        ['Leviathan Wakes', "Caliban's War", 'Abaddon'],
      );
      expect(
        order(['Abaddon', 'Leviathan Wakes', "Caliban's War"], {
          'Leviathan Wakes': const BookSeries('The Expanse', 1),
          "Caliban's War": const BookSeries('The Expanse', 2),
          'Abaddon': const BookSeries('The Expanse', 3),
        }),
        ['Leviathan Wakes', "Caliban's War", 'Abaddon'],
      );
    });

    test('a lone volume stays put', () {
      expect(order(['活着', '三体Ⅱ', '兄弟']), ['活着', '三体Ⅱ', '兄弟']);
    });
  });
}
