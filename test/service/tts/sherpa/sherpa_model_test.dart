import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/tts/sherpa/sherpa_model.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_onnx_meta.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_pace.dart';
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

  group('SherpaOnnxMeta', () {
    /// One `StringStringEntryProto`: key, then field 2 with a varint length.
    List<int> entry(String key, String value) {
      final valueBytes = utf8.encode(value);
      final length = <int>[];
      var remaining = valueBytes.length;
      do {
        var byte = remaining & 0x7f;
        remaining >>= 7;
        if (remaining > 0) byte |= 0x80;
        length.add(byte);
      } while (remaining > 0);
      return [
        0x0a, key.length, ...ascii.encode(key),
        0x12, ...length, ...valueBytes,
      ];
    }

    File onnxWith(List<int> tail) {
      final file = File(p.join(
          Directory.systemTemp.createTempSync('sherpa-onnx-').path,
          'model.onnx'));
      // Something in front of the metadata, as in a real model.
      file.writeAsBytesSync([...List.filled(4096, 0x42), ...tail]);
      addTearDown(() => file.parent.deleteSync(recursive: true));
      return file;
    }

    test('reads the speaker names out of the metadata', () {
      final file = onnxWith(entry('speaker_names',
          'af_heart,zf_xiaoxiao,zm_yunxi'));

      expect(SherpaOnnxMeta.speakerNames(file.path),
          ['af_heart', 'zf_xiaoxiao', 'zm_yunxi']);
    });

    test('handles a value longer than one varint byte', () {
      final names = List.generate(200, (i) => 'v$i');
      final file = onnxWith(entry('speaker_names', names.join(',')));

      expect(SherpaOnnxMeta.speakerNames(file.path), names);
    });

    test('returns nothing for a model without the entry', () {
      final file = onnxWith(entry('model_type', 'kokoro'));

      expect(SherpaOnnxMeta.speakerNames(file.path), isEmpty);
    });

    test('returns nothing for a missing file', () {
      expect(SherpaOnnxMeta.speakerNames('/no/such/model.onnx'), isEmpty);
    });
  });

  group('SherpaPace', () {
    test('counts CJK characters and Latin words', () {
      expect(SherpaPace.syllables('夜色渐深'), 4);
      expect(SherpaPace.syllables('hello there'), closeTo(2.8, 0.001));
      expect(SherpaPace.syllables('第三章 Chapter'), closeTo(4.4, 0.001));
      expect(SherpaPace.syllables('2026 年'), 1);
    });

    test('the reference rate keeps the calibrated pace', () {
      expect(
        SherpaPace.speed(rate: SherpaPace.referenceRate, factor: 1.3),
        closeTo(1.3, 0.001),
      );
    });

    test('a higher rate scales the calibrated pace', () {
      expect(SherpaPace.speed(rate: 1.0, factor: 1.0), closeTo(2.0, 0.001));
      expect(SherpaPace.speed(rate: 0.25, factor: 1.0), closeTo(0.5, 0.001));
    });

    test('a rate of zero falls back to normal speed', () {
      expect(SherpaPace.speed(rate: 0, factor: 1.2), closeTo(1.2, 0.001));
    });

    test('speed stays in a range a model can handle', () {
      expect(SherpaPace.speed(rate: 2.0, factor: 1.8), lessThanOrEqualTo(3.0));
      expect(SherpaPace.speed(rate: 0.06, factor: 0.6), greaterThanOrEqualTo(0.2));
    });

    test('a slow model gets a factor above one', () {
      // 30 syllables in 10 seconds is 3 per second, the target is 4.
      expect(SherpaPace.factorFrom(syllables: 30, naturalSeconds: 10),
          closeTo(4 / 3, 0.001));
    });

    test('waits for enough speech before calibrating', () {
      expect(SherpaPace.factorFrom(syllables: 10, naturalSeconds: 3), isNull);
      expect(SherpaPace.factorFrom(syllables: 30, naturalSeconds: 0), isNull);
    });

    test('clamps a nonsense measurement', () {
      expect(SherpaPace.factorFrom(syllables: 100, naturalSeconds: 1),
          SherpaPace.minFactor);
      expect(SherpaPace.factorFrom(syllables: 30, naturalSeconds: 100),
          SherpaPace.maxFactor);
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
