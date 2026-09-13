import 'package:anx_reader/models/book_series.dart';

/// Which volume of what a book is, read from its title when the book does
/// not say: 三体Ⅱ：黑暗森林 is volume 2 of 三体, 明朝那些事儿（第三部） volume 3,
/// Dune II volume 2, 平凡的世界（下） the last of three.
({String base, double number})? volumeOfTitle(String title) {
  final text = _normalize(title).trim();
  if (text.isEmpty) return null;
  for (final pattern in _patterns) {
    final matches = pattern.regex.allMatches(text).toList();
    for (final match in matches.reversed) {
      final number = pattern.value(match);
      if (number == null) continue;
      final base = _cleanBase(text.substring(0, match.start));
      if (base.isEmpty) continue;
      // What follows the volume may only be a subtitle after a separator,
      // or closing brackets.
      final rest = text.substring(match.end);
      if (rest.trim().isNotEmpty && !_subtitleStart.hasMatch(rest)) continue;
      return (base: base, number: number);
    }
  }
  return null;
}

/// [items] with the volumes of each series in order, gathered where the
/// first of them stood; everything else keeps its place. A book's series
/// position, when it has one, wins over its title.
List<T> orderVolumes<T>(
  List<T> items, {
  required String Function(T) title,
  BookSeries? Function(T)? series,
}) {
  final keys = <({String base, double number})?>[
    for (final item in items) _volumeKey(title(item), series?.call(item)),
  ];
  final byBase = <String, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    final key = keys[i];
    if (key != null) byBase.putIfAbsent(key.base, () => []).add(i);
  }
  final placedAt = <int, List<int>>{};
  final moved = <int>{};
  for (final indices in byBase.values) {
    if (indices.length < 2) continue;
    final sorted = [...indices]..sort((a, b) {
        final byNumber = keys[a]!.number.compareTo(keys[b]!.number);
        return byNumber != 0 ? byNumber : a.compareTo(b);
      });
    placedAt[indices.first] = sorted;
    moved.addAll(indices);
  }
  if (placedAt.isEmpty) return List.of(items);
  return [
    for (var i = 0; i < items.length; i++)
      if (placedAt.containsKey(i))
        for (final j in placedAt[i]!) items[j]
      else if (!moved.contains(i))
        items[i],
  ];
}

({String base, double number})? _volumeKey(String title, BookSeries? series) {
  final position = series?.position;
  if (series != null && position != null) {
    return (base: 'series:${_compact(series.name)}', number: position);
  }
  final volume = volumeOfTitle(title);
  if (volume == null) return null;
  return (base: 'title:${_compact(volume.base)}', number: volume.number);
}

class _Pattern {
  const _Pattern(this.regex, this.value);
  final RegExp regex;
  final double? Function(RegExpMatch) value;
}

final _subtitleStart = RegExp(r'^[\s：:·\-—–_,，.。)）\]】》>]');

final _patterns = <_Pattern>[
  // 第三卷, 第3册, 卷二, 上册
  _Pattern(
    RegExp(r'第\s*([0-9]+|[零〇一二两三四五六七八九十百千]+)\s*[卷册部集辑季篇本辑]'),
    (m) => _number(m.group(1)!),
  ),
  _Pattern(
    RegExp(r'[卷册]\s*([0-9]+|[零〇一二两三四五六七八九十百千]+)'),
    (m) => _number(m.group(1)!),
  ),
  // （上） / 上册 / 下卷, and 上中下 at the very end
  _Pattern(
    RegExp(r'[（(【\[]?\s*([上中下])\s*[册卷部篇集]?\s*[）)】\]]?$'),
    (m) => const {'上': 1.0, '中': 2.0, '下': 3.0}[m.group(1)!],
  ),
  // Vol. 3, #3, No.3, (3), 3
  _Pattern(
    RegExp(r'(?:vol(?:ume)?\.?|no\.?|#|book\s)?\s*[（(【\[]?\s*(?<![0-9])(\d{1,3})\s*[）)】\]]?(?![0-9])',
        caseSensitive: false),
    (m) => double.tryParse(m.group(1)!),
  ),
  // Roman numerals, ASCII (as their own word) or the Unicode forms
  _Pattern(
    RegExp(r'(?<![A-Za-z])([IVXLC]{1,6})(?![A-Za-z])|([ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ])'),
    (m) => m.group(2) != null
        ? (_unicodeRoman.indexOf(m.group(2)!) + 1).toDouble()
        : _roman(m.group(1)!),
  ),
];

const _unicodeRoman = 'ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ';

String _normalize(String text) => String.fromCharCodes(text.runes.map((r) {
      // Full-width digits and Latin letters to ASCII.
      if (r >= 0xFF10 && r <= 0xFF19) return r - 0xFF10 + 0x30;
      if (r >= 0xFF21 && r <= 0xFF3A) return r - 0xFF21 + 0x41;
      if (r >= 0xFF41 && r <= 0xFF5A) return r - 0xFF41 + 0x61;
      return r;
    }));

String _cleanBase(String text) => text
    .replaceAll(RegExp(r'[\s：:·\-—–_,，.。（(【\[《<]+$'), '')
    .trim();

String _compact(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');

double? _roman(String text) {
  const values = {'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100};
  var total = 0;
  for (var i = 0; i < text.length; i++) {
    final value = values[text[i]]!;
    final next = i + 1 < text.length ? values[text[i + 1]]! : 0;
    total += value < next ? -value : value;
  }
  // A real numeral writes back the same: rejects words like "CIVIC".
  return total > 0 && total <= 60 && _toRoman(total) == text ? total.toDouble() : null;
}

String _toRoman(int n) {
  const table = [
    (50, 'L'), (40, 'XL'), (10, 'X'), (9, 'IX'), (5, 'V'), (4, 'IV'), (1, 'I'),
  ];
  final out = StringBuffer();
  for (final (value, numeral) in table) {
    while (n >= value) {
      out.write(numeral);
      n -= value;
    }
  }
  return out.toString();
}

double? _number(String text) {
  final digits = int.tryParse(text);
  if (digits != null) return digits.toDouble();
  const units = {'十': 10, '百': 100, '千': 1000};
  const digitsZh = {
    '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };
  var total = 0;
  var current = 0;
  for (final char in text.split('')) {
    final digit = digitsZh[char];
    if (digit != null) {
      current = digit;
      continue;
    }
    final unit = units[char];
    if (unit == null) return null;
    total += (current == 0 ? 1 : current) * unit;
    current = 0;
  }
  total += current;
  return total > 0 ? total.toDouble() : null;
}
