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
