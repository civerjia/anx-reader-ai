import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/tts/sherpa/sherpa_model.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_onnx_meta.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_loudness.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_pace.dart';
import 'package:anx_reader/service/tts/sherpa/sherpa_text.dart';
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

  group('SherpaModelResolver installed models', () {
    test('lists folders that look like models', () {
      final root = Directory.systemTemp.createTempSync('sherpa-root-');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory(p.join(root.path, 'kokoro-multi-lang-v1_1')).createSync();
      File(p.join(root.path, 'kokoro-multi-lang-v1_1', 'model.onnx'))
          .writeAsStringSync('');
      Directory(p.join(root.path, 'vits-zh')).createSync();
      File(p.join(root.path, 'vits-zh', 'tokens.txt')).writeAsStringSync('');
      Directory(p.join(root.path, 'not-a-model')).createSync();
      File(p.join(root.path, 'not-a-model', 'readme.txt'))
          .writeAsStringSync('');

      expect(SherpaModelResolver.listInstalled([root.path]),
          ['kokoro-multi-lang-v1_1', 'vits-zh']);
    });

    test('an unset folder falls back to the only model installed', () async {
      final root = Directory.systemTemp.createTempSync('sherpa-root-');
      addTearDown(() => root.deleteSync(recursive: true));
      final only = Directory(p.join(root.path, 'kokoro'))..createSync();
      File(p.join(only.path, 'tokens.txt')).writeAsStringSync('');

      expect(await SherpaModelResolver.resolveDir('', roots: [root.path]),
          only.path);
    });

    test('an unset folder with several models says which ones', () async {
      final root = Directory.systemTemp.createTempSync('sherpa-root-');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final name in ['kokoro-a', 'kokoro-b']) {
        final dir = Directory(p.join(root.path, name))..createSync();
        File(p.join(dir.path, 'tokens.txt')).writeAsStringSync('');
      }

      await expectLater(
        SherpaModelResolver.resolveDir('', roots: [root.path]),
        throwsA(isA<SherpaModelException>().having(
            (e) => e.message, 'message', allOf(contains('kokoro-a'), contains('kokoro-b')))),
      );
    });

    test('finds a folder whose absolute path has moved', () async {
      final root = Directory.systemTemp.createTempSync('sherpa-moved-');
      addTearDown(() => root.deleteSync(recursive: true));
      final model = Directory(p.join(root.path, 'kokoro'))..createSync();
      File(p.join(model.path, 'tokens.txt')).writeAsStringSync('');

      // The path the app stored before the container was recreated.
      const stale = '/var/mobile/Containers/Data/Application/OLD/Documents'
          '/tts_models/kokoro';

      expect(await SherpaModelResolver.resolveDir(stale, roots: [root.path]),
          model.path);
    });

    test('no model at all points at where to put one', () async {
      final root = Directory.systemTemp.createTempSync('sherpa-root-');
      addTearDown(() => root.deleteSync(recursive: true));

      await expectLater(
        SherpaModelResolver.resolveDir('', roots: [root.path]),
        throwsA(isA<SherpaModelException>()
            .having((e) => e.message, 'message', contains(root.path))),
      );
    });
  });

  group('SherpaModelResolver transcripts', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sherpa-clips-');
      File(p.join(dir.path, 'leijun-1.wav')).writeAsBytesSync([0]);
      File(p.join(dir.path, 'news-female.wav')).writeAsBytesSync([0]);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('reads the line naming the clip in prompt.txt', () {
      File(p.join(dir.path, 'prompt.txt')).writeAsStringSync(
        'news-female.wav 各位村民, 大家新年好!\n'
        'leijun-1.wav 那还是36年前, 1987年.\n',
      );

      expect(SherpaModelResolver.transcriptFor(p.join(dir.path, 'leijun-1.wav')),
          '那还是36年前, 1987年.');
    });

    test('prefers a text file next to the clip', () {
      File(p.join(dir.path, 'leijun-1.txt')).writeAsStringSync('  同一段话  ');

      expect(SherpaModelResolver.transcriptFor(p.join(dir.path, 'leijun-1.wav')),
          '同一段话');
    });

    test('returns nothing when there is no transcript', () {
      expect(
          SherpaModelResolver.transcriptFor(p.join(dir.path, 'leijun-1.wav')),
          '');
      expect(SherpaModelResolver.transcriptFor('/no/such/clip.wav'), '');
    });
  });

  group('SherpaModelResolver family detection', () {
    Directory modelDir(String name, List<String> files) {
      final root = Directory.systemTemp.createTempSync('sherpa-kind-');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory(p.join(root.path, name))..createSync();
      for (final file in files) {
        File(p.join(dir.path, file)).writeAsStringSync('');
      }
      return dir;
    }

    test('tells the families apart by what is in the folder', () {
      expect(
        SherpaModelResolver.detectType(modelDir('kokoro-multi-lang-v1_1',
                ['model.onnx', 'voices.bin', 'tokens.txt']).path),
        SherpaModelType.kokoro,
      );
      expect(
        SherpaModelResolver.detectType(modelDir('kitten-nano',
                ['model.onnx', 'voices.bin', 'tokens.txt']).path),
        SherpaModelType.kitten,
      );
      expect(
        SherpaModelResolver.detectType(modelDir('zipvoice-distill',
                ['encoder.onnx', 'decoder.onnx', 'tokens.txt']).path),
        SherpaModelType.zipvoice,
      );
      expect(
        SherpaModelResolver.detectType(modelDir('matcha-icefall-zh-baker',
                ['model-steps-3.onnx', 'tokens.txt']).path),
        SherpaModelType.matcha,
      );
      expect(
        SherpaModelResolver.detectType(modelDir('vits-melo-tts-zh_en',
                ['model.onnx', 'tokens.txt', 'lexicon.txt']).path),
        SherpaModelType.vits,
      );
    });

    test('refuses to load a model as the wrong family', () async {
      final dir = modelDir(
          'kokoro-multi-lang-v1_1', ['model.onnx', 'voices.bin', 'tokens.txt']);

      await expectLater(
        SherpaModelResolver.resolve(
            dirInput: dir.path, type: SherpaModelType.vits),
        throwsA(isA<SherpaModelException>().having((e) => e.message, 'message',
            allOf(contains('Kokoro'), contains('VITS')))),
      );
    });

    test('lists only the folders of one family', () {
      final root = Directory.systemTemp.createTempSync('sherpa-list-');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final entry in {
        'kokoro-multi-lang-v1_1': ['model.onnx', 'voices.bin'],
        'vits-melo-tts-zh_en': ['model.onnx', 'tokens.txt'],
      }.entries) {
        final dir = Directory(p.join(root.path, entry.key))..createSync();
        for (final file in entry.value) {
          File(p.join(dir.path, file)).writeAsStringSync('');
        }
      }

      expect(
        SherpaModelResolver.listInstalled([root.path],
            ofType: SherpaModelType.vits),
        ['vits-melo-tts-zh_en'],
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
      final split =
          SherpaPace.split(rate: SherpaPace.referenceRate, factor: 1.2);

      expect(split.model, closeTo(1.2, 0.001));
      expect(split.playback, closeTo(1.0, 0.001));
    });

    test('the slider reads as a multiplier of the natural pace', () {
      final split = SherpaPace.split(rate: 1.25, factor: 1.0);

      // 1.25 on the slider is 1.25x, which the model still does cleanly.
      expect(split.model, closeTo(1.25, 0.001));
      expect(split.playback, closeTo(1.0, 0.001));
    });

    test('the player takes over past what the model reads cleanly', () {
      final split = SherpaPace.split(rate: 2.5, factor: 1.0);

      expect(split.model, SherpaPace.maxModelSpeed);
      expect(split.model * split.playback, closeTo(2.5, 0.001));
    });

    test('slow reading stays entirely in the model', () {
      final split = SherpaPace.split(rate: 0.5, factor: 1.0);

      expect(split.model, closeTo(0.5, 0.001));
      expect(split.playback, closeTo(1.0, 0.001));
    });

    test('a rate of zero falls back to normal speed', () {
      final split = SherpaPace.split(rate: 0, factor: 1.2);

      expect(split.model, closeTo(1.2, 0.001));
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

  group('SherpaText', () {
    test('says a percentage the Chinese way round', () {
      expect(SherpaText.normalize('增长了 1% 左右'), '增长了 百分之1 左右');
      expect(SherpaText.normalize('about 1% higher'), 'about 1 percent higher');
    });

    test('reads symbols that are not in the lexicon', () {
      expect(SherpaText.normalize('今天 25℃ 左右'), '今天 25摄氏度 左右');
      expect(SherpaText.normalize('A & B 的对比'), 'A 和 B 的对比');
    });

    test('turns a dash between numbers into a range', () {
      expect(SherpaText.normalize('大约 3~5 天'), '大约 3到5 天');
      expect(SherpaText.normalize('takes 3~5 days'), 'takes 3 to 5 days');
    });

    test('leaves ordinary text alone', () {
      const plain = '夜色渐深，他合上书走到窗前。';
      expect(SherpaText.normalize(plain), plain);
    });
  });

  group('tightenPauses', () {
    Float32List clip(int sampleRate, List<double> plan) {
      // plan: alternating seconds of tone and of silence.
      final out = <double>[];
      for (var i = 0; i < plan.length; i++) {
        final samples = (plan[i] * sampleRate).round();
        out.addAll(List<double>.filled(samples, i.isEven ? 0.5 : 0.0));
      }
      return Float32List.fromList(out);
    }

    test('shortens a long pause and keeps the speech', () {
      const sr = 24000;
      final input = clip(sr, [0.5, 0.9, 0.5]);

      final out = tightenPauses(input, sr, scale: 0.4);

      // 0.9s of pause becomes 0.36s, speech untouched.
      expect(out.length / sr, closeTo(0.5 + 0.36 + 0.5, 0.01));
    });

    test('leaves a short gap between syllables alone', () {
      const sr = 24000;
      final input = clip(sr, [0.3, 0.08, 0.3]);

      final out = tightenPauses(input, sr, scale: 0.4);

      expect(out.length, input.length);
    });

    test('never cuts a pause to nothing', () {
      const sr = 24000;
      final input = clip(sr, [0.3, 0.6, 0.3]);

      final out = tightenPauses(input, sr, scale: 0.05);

      expect(out.length / sr, closeTo(0.3 + 0.12 + 0.3, 0.01));
    });

    test('a scale of one is a no-op', () {
      const sr = 24000;
      final input = clip(sr, [0.3, 0.9, 0.3]);

      expect(tightenPauses(input, sr, scale: 1.0).length, input.length);
    });
  });

  group('normalizeLoudness', () {
    const sr = 24000;

    Float32List tone(double amplitude, {double seconds = 2.0}) =>
        Float32List.fromList(List<double>.generate(
            (sr * seconds).round(), (i) => amplitude * math.sin(i * 0.4)));

    test('brings a quiet clip to the target loudness', () {
      final out = normalizeLoudness(tone(0.05), sr);

      expect(SherpaLoudness.measure(out, sr),
          closeTo(SherpaLoudness.targetLufs, 0.5));
    });

    test('brings a loud clip down to it', () {
      final out = normalizeLoudness(tone(0.5), sr);

      expect(SherpaLoudness.measure(out, sr),
          closeTo(SherpaLoudness.targetLufs, 0.5));
    });

    test('a short sentence lands where a long one does', () {
      final short = normalizeLoudness(tone(0.05, seconds: 0.6), sr);
      final long = normalizeLoudness(tone(0.05, seconds: 6.0), sr);

      expect(SherpaLoudness.measure(short, sr)!,
          closeTo(SherpaLoudness.measure(long, sr)!, 1.0));
    });

    test('the pause after a sentence does not count as quiet speech', () {
      final speech = tone(0.05, seconds: 2.0);
      final withPause = Float32List(speech.length * 2)
        ..setRange(0, speech.length, speech);

      final plain = normalizeLoudness(speech, sr);
      final padded = normalizeLoudness(withPause, sr);

      expect(SherpaLoudness.measure(padded, sr)!,
          closeTo(SherpaLoudness.measure(plain, sr)!, 0.5));
    });

    test('holds peaks under the ceiling', () {
      final out = normalizeLoudness(tone(0.01), sr, ceiling: 0.95);

      var peak = 0.0;
      for (final sample in out) {
        if (sample.abs() > peak) peak = sample.abs();
      }
      expect(peak, lessThanOrEqualTo(0.95));
    });

    test('lifts a sentence that opens quietly', () {
      // A sentence whose first second is 8 dB below its body: after
      // levelling the two halves must sit much closer together.
      const sr2 = sr;
      final quiet = List<double>.generate(
          sr2, (i) => 0.02 * math.sin(i * 0.4));
      final loud = List<double>.generate(
          sr2 * 2, (i) => 0.05 * math.sin(i * 0.4));
      final uneven = Float32List.fromList([...quiet, ...loud]);

      double levelDb(Float32List s, int from, int to) {
        var sum = 0.0;
        for (var i = from; i < to; i++) {
          sum += s[i] * s[i];
        }
        return 10 * (math.log(sum / (to - from)) / math.ln10);
      }

      final before = levelDb(uneven, sr2, sr2 * 2) - levelDb(uneven, 0, sr2);
      final out = SherpaLoudness.level(uneven, sr2);
      final after = levelDb(out, sr2, sr2 * 2) - levelDb(out, 0, sr2);

      expect(before, greaterThan(6));
      // Levelled, not flattened: the point is to pull the opening up
      // without ironing the speech out.
      expect(after, lessThan(before * 0.6));
    });

    test('leaves silence alone', () {
      final quiet = Float32List.fromList(List<double>.filled(sr, 0.0));

      expect(normalizeLoudness(quiet, sr), everyElement(0.0));
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
