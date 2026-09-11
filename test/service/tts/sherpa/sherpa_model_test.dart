import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/tts/sherpa/sherpa_model.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_wav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Creates a model folder with empty files, which is all the resolver looks at.
Directory _modelDir(String name, List<String> files,
    {List<String> dirs = const []}) {
  final dir = Directory.systemTemp.createTempSync('sherpa-$name-');
  for (final file in files) {
    File(p.join(dir.path, file)).writeAsStringSync('');
  }
  for (final sub in dirs) {
    Directory(p.join(dir.path, sub)).createSync();
  }
  return dir;
}

void main() {
  group('SherpaModelResolver kokoro', () {
    late Directory dir;

    setUp(() {
      dir = _modelDir('kokoro', [
        'model.onnx',
        'model.int8.onnx',
        'voices.bin',
        'tokens.txt',
        'lexicon-us-en.txt',
        'lexicon-zh.txt',
      ], dirs: [
        'espeak-ng-data',
        'dict',
      ]);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('prefers the quantized model and finds every lexicon', () async {
      final spec = await SherpaModelResolver.resolve(
        dirInput: dir.path,
        type: SherpaModelType.kokoro,
      );

      expect(p.basename(spec.model), 'model.int8.onnx');
      expect(p.basename(spec.voices), 'voices.bin');
      expect(p.basename(spec.tokens), 'tokens.txt');
      expect(p.basename(spec.dataDir), 'espeak-ng-data');
      expect(p.basename(spec.dictDir), 'dict');
      expect(spec.lexicon.split(',').map(p.basename).toList(),
          ['lexicon-us-en.txt', 'lexicon-zh.txt']);
    });

    test('keeps the float model when int8 is not preferred', () async {
      final spec = await SherpaModelResolver.resolve(
        dirInput: dir.path,
        type: SherpaModelType.kokoro,
        preferInt8: false,
      );

      expect(p.basename(spec.model), 'model.onnx');
    });

    test('an explicit lexicon overrides the ones found in the folder',
        () async {
      final spec = await SherpaModelResolver.resolve(
        dirInput: dir.path,
        type: SherpaModelType.kokoro,
        lexiconOverride: 'lexicon-zh.txt',
      );

      expect(spec.lexicon, p.join(dir.path, 'lexicon-zh.txt'));
    });

    test('keeps one English lexicon and orders the rule FSTs', () async {
      // The layout of the real kokoro-multi-lang-v1_0 release.
      final real = _modelDir('kokoro-real', [
        'model.onnx',
        'voices.bin',
        'tokens.txt',
        'lexicon-gb-en.txt',
        'lexicon-us-en.txt',
        'lexicon-zh.txt',
        'date-zh.fst',
        'number-zh.fst',
        'phone-zh.fst',
      ], dirs: [
        'espeak-ng-data',
        'dict',
      ]);
      addTearDown(() => real.deleteSync(recursive: true));

      final spec = await SherpaModelResolver.resolve(
        dirInput: real.path,
        type: SherpaModelType.kokoro,
      );

      // Loading both English lexicons only produces duplicate warnings.
      expect(spec.lexicon.split(',').map(p.basename).toList(),
          ['lexicon-us-en.txt', 'lexicon-zh.txt']);
      // Numbers have to be normalised after dates and phone numbers.
      expect(spec.ruleFsts.split(',').map(p.basename).toList(),
          ['date-zh.fst', 'phone-zh.fst', 'number-zh.fst']);
    });

    test('reports the missing file by name', () async {
      final incomplete = _modelDir('kokoro-bad', ['model.onnx', 'voices.bin']);
      addTearDown(() => incomplete.deleteSync(recursive: true));

      await expectLater(
        SherpaModelResolver.resolve(
          dirInput: incomplete.path,
          type: SherpaModelType.kokoro,
        ),
        throwsA(isA<SherpaModelException>()
            .having((e) => e.message, 'message', contains('tokens.txt'))),
      );
    });
  });

  group('SherpaModelResolver zipvoice', () {
    test('separates encoder, decoder and vocoder', () async {
      final dir = _modelDir('zipvoice', [
        'encoder.int8.onnx',
        'decoder.int8.onnx',
        'vocos_24khz.onnx',
        'tokens.txt',
        'lexicon.txt',
        'prompt.wav',
      ], dirs: [
        'espeak-ng-data'
      ]);
      addTearDown(() => dir.deleteSync(recursive: true));

      final spec = await SherpaModelResolver.resolve(
        dirInput: dir.path,
        type: SherpaModelType.zipvoice,
        referenceAudio: 'prompt.wav',
        referenceText: 'hello',
        numSteps: 4,
      );

      expect(p.basename(spec.encoder), 'encoder.int8.onnx');
      expect(p.basename(spec.decoder), 'decoder.int8.onnx');
      expect(p.basename(spec.vocoder), 'vocos_24khz.onnx');
      expect(p.basename(spec.referenceAudio), 'prompt.wav');
      expect(spec.referenceText, 'hello');
      expect(spec.numSteps, 4);
    });

    test('says what to do when the vocoder is missing', () async {
      final dir = _modelDir('zipvoice-bad', [
        'encoder.onnx',
        'decoder.onnx',
        'tokens.txt',
      ]);
      addTearDown(() => dir.deleteSync(recursive: true));

      await expectLater(
        SherpaModelResolver.resolve(
          dirInput: dir.path,
          type: SherpaModelType.zipvoice,
        ),
        throwsA(isA<SherpaModelException>()
            .having((e) => e.message, 'message', contains('vocoder'))),
      );
    });
  });

  group('SherpaModelSpec', () {
    test('engine key changes with the reference audio', () {
      const a = SherpaModelSpec(
        type: SherpaModelType.zipvoice,
        dir: '/models/zipvoice',
        referenceAudio: '/models/a.wav',
      );
      const b = SherpaModelSpec(
        type: SherpaModelType.zipvoice,
        dir: '/models/zipvoice',
        referenceAudio: '/models/b.wav',
      );

      expect(a.engineKey, isNot(b.engineKey));
    });

    test('engine key ignores per request settings', () {
      const a = SherpaModelSpec(
        type: SherpaModelType.zipvoice,
        dir: '/models/zipvoice',
        referenceText: 'one',
        numSteps: 4,
      );
      const b = SherpaModelSpec(
        type: SherpaModelType.zipvoice,
        dir: '/models/zipvoice',
        referenceText: 'two',
        numSteps: 8,
      );

      expect(a.engineKey, b.engineKey);
    });
  });

  group('wave', () {
    test('round trips mono samples', () {
      final samples = Float32List.fromList([0, 0.5, -0.5, 0.999, -0.999]);

      final decoded = decodeWav(encodeWav(samples, 24000));

      expect(decoded, isNotNull);
      expect(decoded!.sampleRate, 24000);
      expect(decoded.samples.length, samples.length);
      for (var i = 0; i < samples.length; i++) {
        // 16 bit quantisation, plus the 32767 / 32768 asymmetry between
        // encoding and decoding.
        expect(decoded.samples[i], closeTo(samples[i], 1 / 16384));
      }
    });

    test('rejects data that is not a wave file', () {
      expect(decodeWav(Uint8List.fromList(List.filled(64, 7))), isNull);
    });
  });
}
