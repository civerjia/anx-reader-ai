import 'dart:convert';
import 'dart:math' as math;

import 'package:llm_llamacpp/llm_llamacpp.dart';

/// Small local models mis-copy what the user typed into tool arguments: asked
/// about 林特·艾萨克, a 2B model searched the book for 林特·艾克撒克 and found
/// nothing. A string argument in CJK that is not in the user's words, but is a
/// character or two away from something that is, is taken to be that.
List<LLMToolCall> repairToolCalls(List<LLMToolCall> calls, String userText) {
  if (userText.isEmpty) return calls;
  return [
    for (final call in calls) _repairCall(call, userText),
  ];
}

LLMToolCall _repairCall(LLMToolCall call, String userText) {
  final Object? decoded;
  try {
    decoded = jsonDecode(call.arguments);
  } on FormatException {
    return call;
  }
  if (decoded is! Map) return call;
  var changed = false;
  final repaired = <String, dynamic>{};
  decoded.forEach((key, value) {
    if (value is String) {
      final fixed = repairAgainst(value, userText);
      if (fixed != value) changed = true;
      repaired[key.toString()] = fixed;
    } else {
      repaired[key.toString()] = value;
    }
  });
  if (!changed) return call;
  return LLMToolCall(
      id: call.id, name: call.name, arguments: jsonEncode(repaired));
}

final _cjk = RegExp(r'[぀-ヿ㐀-鿿가-힯]');

/// [value] replaced by the closest stretch of [source], when it is close.
String repairAgainst(String value, String source) {
  final wanted = value.trim();
  if (!_cjk.hasMatch(wanted) || source.contains(wanted)) return value;
  final v = wanted.runes.toList();
  if (v.length < 3 || v.length > 24) return value;
  final s = source.runes.toList();
  final allowed = (v.length * 0.4).floor();

  List<int>? best;
  var bestDistance = allowed + 1;
  var bestLengthGap = 1 << 30;
  for (var start = 0; start < s.length; start++) {
    for (var length = math.max(3, v.length - allowed);
        length <= v.length + allowed && start + length <= s.length;
        length++) {
      final candidate = s.sublist(start, start + length);
      final distance = _levenshtein(v, candidate);
      final gap = (length - v.length).abs();
      if (distance < bestDistance ||
          (distance == bestDistance && gap < bestLengthGap)) {
        best = candidate;
        bestDistance = distance;
        bestLengthGap = gap;
      }
    }
  }
  if (best == null || bestDistance > allowed) return value;
  // The stretch must be recognisably the same words: most characters shared.
  final pool = [...best];
  var shared = 0;
  for (final r in v) {
    if (pool.remove(r)) shared++;
  }
  if (shared * 2 <= v.length) return value;
  return String.fromCharCodes(best);
}

int _levenshtein(List<int> a, List<int> b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      current[j] = math.min(
          math.min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost);
    }
    previous = current;
  }
  return previous[b.length];
}
