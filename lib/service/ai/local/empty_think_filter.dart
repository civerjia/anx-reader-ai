import 'dart:math' as math;

/// Routes a reply's leading `<think>…</think>` into reasoning when thinking
/// was not asked for. Qwen3.5 opens replies with an empty block, and on its
/// own sometimes with real reasoning; either way the chat showed the raw tags.
/// The tag arrives in pieces, so the start is held until it is clear. A reply
/// that does not open with `<think>` passes through unchanged.
class LeadingThinkRouter {
  static const _open = '<think>';

  final _held = StringBuffer();
  bool _decided = false;
  ThinkSplitter? _splitter;
  bool _reasoningStarted = false;

  ({String reasoning, String answer}) add(String piece) {
    if (_decided) return _route(piece);
    _held.write(piece);
    final text = _held.toString();
    final trimmed = text.trimLeft();
    if (trimmed.length < _open.length && _open.startsWith(trimmed)) {
      return (reasoning: '', answer: '');
    }
    _decided = true;
    _held.clear();
    if (trimmed.startsWith(_open)) {
      _splitter = ThinkSplitter();
      return _route(trimmed.substring(_open.length));
    }
    return (reasoning: '', answer: text);
  }

  ({String reasoning, String answer}) close() {
    if (!_decided) {
      final text = _held.toString();
      _held.clear();
      _decided = true;
      return (reasoning: '', answer: text);
    }
    final splitter = _splitter;
    if (splitter == null) return (reasoning: '', answer: '');
    return _clean(splitter.close());
  }

  ({String reasoning, String answer}) _route(String piece) {
    final splitter = _splitter;
    if (splitter == null) return (reasoning: '', answer: piece);
    return _clean(splitter.add(piece));
  }

  /// An empty block has only blank lines as reasoning; they are not shown.
  ({String reasoning, String answer}) _clean(({String reasoning, String answer}) parts) {
    var reasoning = parts.reasoning;
    if (!_reasoningStarted) {
      reasoning = reasoning.trimLeft();
      if (reasoning.isNotEmpty) _reasoningStarted = true;
    }
    return (reasoning: reasoning, answer: parts.answer);
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
