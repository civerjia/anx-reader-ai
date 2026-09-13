import 'dart:math' as math;

/// Drops the empty `<think></think>` a Qwen model writes at the start of a
/// reply when thinking is turned off. It arrives in pieces (`<think>`, a
/// newline, `</think>`), so the start of the reply is held back until it is
/// clear whether it is that block. Anything else passes through unchanged,
/// including real thinking.
class EmptyThinkFilter {
  static const _open = '<think>';
  static const _close = '</think>';
  static final _emptyBlock = RegExp(r'^\s*<think>\s*</think>\s*');

  final _held = StringBuffer();
  bool _decided = false;

  /// The part of [piece] that can be shown now.
  String add(String piece) {
    if (_decided) return piece;
    _held.write(piece);
    final text = _held.toString();
    final block = _emptyBlock.firstMatch(text);
    if (block != null) {
      final rest = text.substring(block.end);
      // Whitespace after the block may still be followed by more; wait for
      // the first visible character.
      if (rest.isEmpty) return '';
      _decided = true;
      _held.clear();
      return rest;
    }
    if (_couldBecomeEmptyBlock(text.trimLeft())) return '';
    _decided = true;
    _held.clear();
    return text;
  }

  /// Whatever is still held when the reply ends.
  String close() {
    final text = _held.toString();
    _held.clear();
    _decided = true;
    return _emptyBlock.hasMatch(text) ? text.replaceFirst(_emptyBlock, '') : text;
  }

  static bool _couldBecomeEmptyBlock(String text) {
    if (_open.startsWith(text)) return true;
    if (!text.startsWith(_open)) return false;
    final inside = text.substring(_open.length).trimLeft();
    return _close.startsWith(inside);
  }
}

/// Splits a reply that was opened with `<think>` into the reasoning, up to
/// `</think>`, and the answer after it. The closing tag may arrive in pieces,
/// so a possible start of it is held back.
class ThinkSplitter {
  static const _close = '</think>';

  bool _answering = false;
  bool _answerStarted = false;
  String _held = '';

  ({String reasoning, String answer}) add(String piece) {
    if (_answering) return (reasoning: '', answer: _trimStart(piece));
    final text = _held + piece;
    final at = text.indexOf(_close);
    if (at >= 0) {
      _answering = true;
      _held = '';
      return (
        reasoning: text.substring(0, at),
        answer: _trimStart(text.substring(at + _close.length)),
      );
    }
    var keep = 0;
    for (var k = math.min(_close.length - 1, text.length); k > 0; k--) {
      if (_close.startsWith(text.substring(text.length - k))) {
        keep = k;
        break;
      }
    }
    _held = text.substring(text.length - keep);
    return (reasoning: text.substring(0, text.length - keep), answer: '');
  }

  /// What is still held when the reply ends: reasoning if `</think>` never
  /// came (the token cap cut it off).
  ({String reasoning, String answer}) close() {
    final held = _held;
    _held = '';
    return _answering ? (reasoning: '', answer: held) : (reasoning: held, answer: '');
  }

  /// The blank lines after `</think>` are not part of the answer.
  String _trimStart(String text) {
    if (_answerStarted) return text;
    final trimmed = text.trimLeft();
    if (trimmed.isNotEmpty) _answerStarted = true;
    return trimmed;
  }
}
