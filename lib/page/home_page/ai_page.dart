import 'package:anx_reader/service/ai/quick_prompt_chips.dart';
import 'package:anx_reader/widgets/ai/ai_chat_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AiPage extends ConsumerWidget {
  const AiPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: AiChatStream(
          quickPromptChips: buildAiQuickPromptChips(context, ref),
        ),
      ),
    );
  }
}
