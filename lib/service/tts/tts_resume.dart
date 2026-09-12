/// Remembers where narration stopped in each book.
///
/// Narration used to start from the top of the visible page every time, so
/// stopping mid-page and starting again repeated everything already heard. A
/// saved sentence is used once: taken when narration next starts, so a later
/// start from the same page does not keep jumping back to it.

/// At most this many books keep a resume point; the oldest drop off.
const int ttsResumeLimit = 50;

/// [points] with [bookId] set to [cfi], moved to the newest position and
/// trimmed to [limit] entries.
Map<String, String> withResumePoint(
  Map<String, String> points,
  int bookId,
  String cfi, {
  int limit = ttsResumeLimit,
}) {
  final next = Map<String, String>.of(points)..remove('$bookId');
  next['$bookId'] = cfi;
  while (next.length > limit) {
    next.remove(next.keys.first);
  }
  return next;
}
