const _digits = '零一二三四五六七八九';

/// [n] as a Chinese numeral read by value: 12 → 十二, 105 → 一百零五.
String chineseNumber(int n) {
  if (n < 0) return '负${chineseNumber(-n)}';
  if (n < 10) return _digits[n];
  if (n >= 100000000) return chineseDigits(n.toString());
  final wan = n ~/ 10000;
  final rest = n % 10000;
  if (wan == 0) return _belowTenThousand(n, leading: true);
  final head = '${_belowTenThousand(wan, leading: true)}万';
  if (rest == 0) return head;
  return '$head${rest < 1000 ? '零' : ''}${_belowTenThousand(rest, leading: false)}';
}

/// [n] as a count said before a measure word: 两 instead of 二 leading
/// hundreds, thousands and ten thousands (两千零二十四箱).
String chineseCount(int n) {
  final words = chineseNumber(n);
  return RegExp(r'^二(?=[百千万])').hasMatch(words) ? '两${words.substring(1)}' : words;
}

/// [digits] read one by one: 221 → 二二一.
String chineseDigits(String digits) =>
    digits.split('').map((d) => _digits[int.parse(d)]).join();

String _belowTenThousand(int n, {required bool leading}) {
  const units = ['', '十', '百', '千'];
  final s = n.toString();
  final out = StringBuffer();
  var pendingZero = false;
  for (var i = 0; i < s.length; i++) {
    final d = int.parse(s[i]);
    final unit = units[s.length - 1 - i];
    if (d == 0) {
      pendingZero = true;
      continue;
    }
    if (pendingZero && out.isNotEmpty) out.write('零');
    pendingZero = false;
    // 十二, not 一十二, at the start of a number.
    if (!(d == 1 && unit == '十' && i == 0 && leading)) out.write(_digits[d]);
    out.write(unit);
  }
  return out.toString();
}
