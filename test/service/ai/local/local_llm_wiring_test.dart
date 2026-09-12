import 'dart:io';

import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/service/ai/ai_key_rotator.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/ai/langchain_ai_config.dart';
import 'package:anx_reader/service/ai/langchain_registry.dart';
import 'package:anx_reader/service/ai/local/local_llm_chat_model.dart';
import 'package:anx_reader/service/ai/local/local_llm_models.dart';
import 'package:flutter_test/flutter_test.dart';

AiProvider _localProvider({String model = 'Qwen3.5-2B.gguf'}) {
  final now = DateTime.now();
  return AiProvider(
    id: 'local-test',
    title: 'On device',
    url: '',
    protocol: AiProtocol.local,
    apiKeys: const [],
    model: model,
    keyIndex: 0,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('a local provider passes the gates a remote one needs a key for', () {
    test('counts as configured without any API key', () {
      final provider = _localProvider();
      expect(provider.apiKeys, isEmpty);
      expect(provider.hasValidKey, isTrue);
      expect(AiKeyRotator.hasValidKey(provider), isTrue);
    });

    test('yields an empty key rather than null', () {
      // The call sites read null as "unusable", so empty is the distinction
      // that keeps a keyless provider selectable.
      expect(AiKeyRotator.getNextKey(_localProvider()), '');
    });

    test('a remote provider with no key is still rejected', () {
      final now = DateTime.now();
      final remote = AiProvider(
        id: 'remote-test',
        title: 'Remote',
        url: 'https://example.com/v1',
        protocol: AiProtocol.openai,
        apiKeys: const [],
        model: 'gpt-4o-mini',
        keyIndex: 0,
        createdAt: now,
        updatedAt: now,
      );
      expect(remote.hasValidKey, isFalse);
      expect(AiKeyRotator.getNextKey(remote), isNull);
    });
  });

  group('config', () {
    test('local needs no url or key', () {
      final config = LangchainAiConfig.local(
        providerId: 'local-test',
        model: 'Qwen3.5-2B.gguf',
      );
      expect(config.model, 'Qwen3.5-2B.gguf');
      expect(config.apiKey, isEmpty);
      expect(config.baseUrl, isNull);
    });

    test('local still insists on a model file', () {
      expect(
        () => LangchainAiConfig.local(providerId: 'x', model: '   '),
        throwsArgumentError,
      );
    });

    test('the remote factory would have rejected an empty url', () {
      expect(
        () => LangchainAiConfig.fromProvider(
          providerId: 'x',
          model: 'm',
          apiKey: 'k',
          url: '',
        ),
        throwsArgumentError,
      );
    });
  });

  group('registry', () {
    test('the local protocol resolves to the on-device model', () {
      final pipeline = const LangchainAiRegistry(null).resolveByProtocol(
        AiProtocol.local,
        LangchainAiConfig.local(
          providerId: 'local-test',
          model: 'Qwen3.5-2B.gguf',
        ),
      );
      final model = pipeline.model;
      expect(model, isA<LocalLlmChatModel>());
      expect((model as LocalLlmChatModel).modelName, 'Qwen3.5-2B.gguf');
      expect(model.modelType, 'local-llama-cpp');
    });
  });

  group('a provider only offers itself when it can answer', () {
    test('a local provider needs its weights chosen', () {
      expect(_localProvider(model: '').isUsable, isFalse);
      expect(_localProvider(model: 'Qwen3.5-2B.gguf').isUsable, isTrue);
    });

    test('a built-in shipped without a key is not offered', () {
      final now = DateTime.now();
      final remote = AiProvider(
        id: 'openai',
        title: 'OpenAI',
        url: 'https://api.openai.com/v1',
        protocol: AiProtocol.openai,
        apiKeys: const [],
        model: 'gpt-4o-mini',
        keyIndex: 0,
        createdAt: now,
        updatedAt: now,
      );
      expect(remote.enabled, isTrue);
      expect(remote.isUsable, isFalse);
    });
  });

  group('agent mode', () {
    test('every protocol, local included, can run the tool loop', () {
      for (final protocol in AiProtocol.values) {
        expect(supportsAgentMode(protocol), isTrue, reason: protocol.name);
      }
    });
  });

  group('model resolution', () {
    test('an absolute path that exists is taken as given', () async {
      final file = File('${Directory.systemTemp.path}/anx-local-llm-test.gguf');
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      file.writeAsBytesSync(const [0x47, 0x47, 0x55, 0x46]);

      expect(await LocalLlmModels.resolve(file.path), file.path);
    });

    test('an empty name resolves to nothing', () async {
      expect(await LocalLlmModels.resolve(''), isNull);
    });
  });
}
