// End to end check of the offline sherpa-onnx backend, running inside the
// real app so the native library and the plugin paths are the real ones.
//
// It needs a model on the device. Put one in the app's documents directory:
//
//   <app documents>/tts_models/kokoro-multi-lang-v1_0
//
// and run, for example:
//
//   flutter test integration_test/sherpa_tts_test.dart -d macos
//
// The test is skipped when no model is present, so it stays safe in CI.

import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_model_roots.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_tts_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String modelFolder = String.fromEnvironment(
  'SHERPA_MODEL',
  defaultValue: 'kokoro-multi-lang-v1_0',
);

const String sampleText =
    '中英文语音合成测试。This is Kokoro running offline inside Anx Reader. '
    '今天是二零二六年九月十一日。';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('synthesizes a sentence with a local model', (tester) async {
    await Prefs().initPrefs();

    final roots = await SherpaModelRoots.all();
    final installed = roots
        .map((root) => Directory(p.join(root, modelFolder)))
        .where((dir) => dir.existsSync())
        .toList();
    if (installed.isEmpty) {
      markTestSkipped('No model at ${roots.join(' or ')} / $modelFolder');
      return;
    }

    final provider = SherpaTtsProvider();
    provider.saveConfig({
      'modelType': 'kokoro',
      'modelDir': modelFolder,
      'vocoder': '',
      'referenceAudio': '',
      'referenceText': '',
      'numSteps': 4,
      'numThreads': 2,
      'preferInt8': true,
      'lexicon': '',
    });
    Prefs().setTtsVoiceModel('sherpa', '45');

    final spec = await provider.resolveSpec();
    // ignore: avoid_print
    print('SHERPA SPEC: $spec');

    final loading = Stopwatch()..start();
    await provider.prepare();
    loading.stop();

    final synthesis = Stopwatch()..start();
    final bytes = await provider.speak(sampleText, null, 1.0, 1.0);
    synthesis.stop();

    expect(bytes.length, greaterThan(44), reason: 'expected wave audio');

    final seconds = (bytes.length - 44) / 2 / 24000;
    final out = File(p.join(
        (await getApplicationDocumentsDirectory()).path,
        'sherpa_tts_sample.wav'));
    await out.writeAsBytes(bytes);

    // ignore: avoid_print
    print('SHERPA RESULT: ${out.path} bytes=${bytes.length} '
        'load=${loading.elapsedMilliseconds}ms '
        'synth=${synthesis.elapsedMilliseconds}ms '
        'audio=${seconds.toStringAsFixed(1)}s');

    final voices = await provider.getVoices();
    expect(voices, isNotEmpty);
    // ignore: avoid_print
    print('SHERPA VOICES: ${voices.length}');

    await provider.release();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
