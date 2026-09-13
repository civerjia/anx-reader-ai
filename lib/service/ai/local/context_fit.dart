import 'package:llm_llamacpp/llm_llamacpp.dart' show LLMMessage, LLMRole;

/// A cautious token count: CJK is about one token a character, sometimes more;
/// other text about four characters a token. Over-counting only drops history
/// sooner, while under-counting fails the whole request.
int roughTokens(String text) {
  var cjk = 0;
  var other = 0;
  for (final rune in text.runes) {
    if ((rune >= 0x3000 && rune <= 0x9FFF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFF00 && rune <= 0xFF60) ||
        (rune >= 0x20000 && rune <= 0x2FA1F)) {
      cjk++;
    } else {
      other++;
    }
  }
  return (cjk * 6 + 4) ~/ 5 + (other + 3) ~/ 4;
}

/// What is left of a conversation once it fits [available] tokens.
class FittedMessages {
  const FittedMessages(this.messages, {this.clipped = 0, this.dropped = 0});
  final List<LLMMessage> messages;
  final int clipped;
  final int dropped;
}

/// The longest an earlier turn stays once the conversation has to shrink.
const earlierTurnCharacterLimit = 1200;

/// Fits a conversation into the context a phone loads.
///
/// llama.cpp does not shorten anything: a prompt past the context fails with
/// "Failed to evaluate prompt", and every later question in that chat fails the
/// same way, since the whole history is sent again. So, oldest first, long
/// earlier turns are cut down, then whole earlier turns are left out. The
/// system turn and the latest user turn are always kept.
FittedMessages fitToContext(List<LLMMessage> messages, int available) {
  int total(List<LLMMessage> list) =>
      list.fold(0, (sum, m) => sum + roughTokens(m.content ?? '') + 8);
  if (total(messages) <= available) return FittedMessages(messages);

  final lastUser = messages.lastIndexWhere((m) => m.role == LLMRole.user);
  var list = [...messages];
  var clipped = 0;
  for (var i = 0; i < list.length && total(list) > available; i++) {
    final m = list[i];
    final content = m.content ?? '';
    if (m.role == LLMRole.system || i == lastUser) continue;
    if (content.length <= earlierTurnCharacterLimit) continue;
    list[i] = LLMMessage(
      role: m.role,
      toolCallId: m.toolCallId,
      content: '${content.substring(0, earlierTurnCharacterLimit)}\n…[earlier '
          'turn shortened to fit]',
    );
    clipped++;
  }

  var dropped = 0;
  while (total(list) > available) {
    final keepFrom = list.lastIndexWhere((m) => m.role == LLMRole.user);
    final victim = list.indexWhere((m) => m.role != LLMRole.system);
    if (victim < 0 || victim >= keepFrom) break;
    list.removeAt(victim);
    dropped++;
    // A tool result without the call before it confuses the template.
    while (victim < list.length &&
        victim < list.lastIndexWhere((m) => m.role == LLMRole.user) &&
        list[victim].role == LLMRole.tool) {
      list.removeAt(victim);
      dropped++;
    }
  }
  return FittedMessages(list, clipped: clipped, dropped: dropped);
}
