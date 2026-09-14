import 'dart:convert';

import 'package:llm_llamacpp/src/isolate_messages.dart';

const _bos = '<｜start▁of▁sentence｜>';
const _eos = '<｜end▁of▁sentence｜>';

/// Whether [template] is Spark-X2.5's chat template.
///
/// llama.cpp's `llama_chat_apply_template` does not know it (as of b10950) and
/// the package would fall back to ChatML, a format the model was never trained
/// on. Recognised by the markers only this template writes.
bool isSparkChatTemplate(String? template) =>
    template != null &&
    template.contains('<|Bot|>') &&
    template.contains(_bos);

/// Renders [messages] the way XHToken/Spark-X2.5's chat_template.jinja does,
/// ending with the generation prompt `<｜start▁of▁sentence｜><|Bot|>`.
///
/// Tool definitions are expected to be in the system message already (see
/// `injectToolDefinitions`); the template's tool block and the system prompt it
/// is given are both placed after its default system line. Whether the reply
/// thinks is decided by the caller, which appends `<think>` or `</think>`.
String renderSparkPrompt(List<IsolateMessage> messages) {
  final out = StringBuffer();
  var rest = messages;
  var initialSystem = '';
  if (rest.isNotEmpty && rest.first.role == 'system') {
    initialSystem = rest.first.content;
    rest = rest.sublist(1);
  }
  out
    ..write('$_bos<|System|>\nyou are a helpful assistant.')
    ..write(initialSystem.isEmpty ? '' : '\n\n$initialSystem')
    ..write(_eos);

  for (var i = 0; i < rest.length; i++) {
    final message = rest[i];
    switch (message.role) {
      case 'system':
        out.write('$_bos<|System|>\n${message.content}$_eos');
      case 'user':
        out.write('$_bos<|User|>${message.content}$_eos');
      case 'assistant':
        out.write('$_bos<|Bot|></think>'
            '${sparkToolCalls(message.content)}$_eos');
      case 'tool':
        final first = i == 0 || rest[i - 1].role != 'tool';
        final last = i == rest.length - 1 || rest[i + 1].role != 'tool';
        if (first) out.write('$_bos<|Tool|>');
        out.write('<tool_response>${message.content}</tool_response>');
        if (last) out.write(_eos);
      default:
        out.write('$_bos<|User|>${message.content}$_eos');
    }
  }
  out.write('$_bos<|Bot|>');
  return out.toString();
}

/// Rewrites Hermes-style calls replayed in an assistant turn —
/// `<tool_call>{"name": …, "arguments": {…}}</tool_call>` — into the shape
/// Spark writes them, so the history shows the model its own format.
String sparkToolCalls(String content) {
  return content.replaceAllMapped(
    RegExp(r'<tool_call>\s*(\{[\s\S]*?\})\s*</tool_call>'),
    (match) {
      final Object? decoded;
      try {
        decoded = json.decode(match[1]!);
      } on FormatException {
        return match[0]!;
      }
      if (decoded is! Map || decoded['name'] is! String) return match[0]!;
      final arguments = decoded['arguments'];
      final call = StringBuffer('<tool_call>${decoded['name']}');
      if (arguments is Map) {
        arguments.forEach((key, value) {
          call.write('<arg_key>$key</arg_key><arg_value>'
              '${value is String ? value : json.encode(value)}</arg_value>');
        });
      }
      call.write('</tool_call>');
      return call.toString();
    },
  );
}
