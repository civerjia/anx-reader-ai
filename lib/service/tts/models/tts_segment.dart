import 'dart:typed_data';

import 'package:anx_reader/service/tts/models/tts_sentence.dart';

class TtsSegment {
  TtsSegment({required this.sentence});

  final TtsSentence sentence;
  Uint8List? audio;
  bool isSilent = false;

  /// Why there is no audio, when the backend failed rather than the
  /// sentence being empty. Silence from a failure must not be treated as a
  /// sentence that simply had nothing to say.
  String? error;
  int fetchVersion =
      0; // Version to track if audio was fetched with current settings

  bool get isReady => isSilent || (audio != null && audio!.isNotEmpty);
}
