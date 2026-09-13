/*
 * Copyright (c) 2024 flutter_tts contributors
 * Licensed under the MIT License
 */

import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { BusinessError } from '@ohos.base';

const TAG = 'FlutterTtsOhosPlugin';
const CHANNEL_NAME = 'flutter_tts';

// Interface for voice info returned to Flutter
class VoiceInfoResult {
  name: string = '';
  locale: string = '';
  gender: string = '';
  status: string = '';
  description: string = '';

  constructor(name: string, locale: string, gender: string, status: string, description: string) {
    this.name = name;
    this.locale = locale;
    this.gender = gender;
    this.status = status;
    this.description = description;
  }
}

// Interface for speech rate range
class SpeechRateRange {
  min: number = 0.0;
  normal: number = 0.5;
  max: number = 1.0;
  platform: string = 'ohos';

  constructor(min: number, normal: number, max: number, platform: string) {
    this.min = min;
    this.normal = normal;
    this.max = max;
    this.platform = platform;
  }
}

export default class FlutterTtsOhosPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private ttsEngine: textToSpeech.TextToSpeechEngine | null = null;
  private speaking: boolean = false;
  private awaitSpeakCompletion: boolean = false;
  private pendingResult: MethodResult | null = null;

  // TTS settings
  private language: string = 'zh-CN';
  private person: number = 0;
  private speed: number = 1.0;
  private volume: number = 1.0;
  private pitch: number = 1.0;

  getUniqueClassName(): string {
    return TAG;
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
    this.initTtsEngine();
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.shutdownTtsEngine();
  }

  private initTtsEngine(): void {
    const params: textToSpeech.CreateEngineParams = {
      language: this.language,
      person: this.person,
      online: 1, // 1 for online, 0 for offline
    };

    textToSpeech.createEngine(params, (err: BusinessError, engine: textToSpeech.TextToSpeechEngine) => {
      if (err || !engine) {
        console.error(TAG, `Failed to create TTS engine: ${err?.message}`);
        return;
      }
      this.ttsEngine = engine;
      this.setTtsListener();
      console.info(TAG, 'TTS engine initialized successfully');
    });
  }

  private shutdownTtsEngine(): void {
    if (this.ttsEngine) {
      try {
        this.ttsEngine.shutdown();
      } catch (e) {
        console.error(TAG, `Failed to shutdown TTS engine: ${JSON.stringify(e)}`);
      }
      this.ttsEngine = null;
    }
  }

  private setTtsListener(): void {
    if (!this.ttsEngine) return;

    const listener: textToSpeech.SpeakListener = {
      onStart: (requestId: string, response: textToSpeech.StartResponse) => {
        this.speaking = true;
        this.invokeMethod('speak.onStart', null);
      },
      onComplete: (requestId: string, response: textToSpeech.CompleteResponse) => {
        if (response && response.type === 1) {
          this.speaking = false;
          this.invokeMethod('speak.onComplete', null);
          this.completePendingResult(1);
        }
      },
      onStop: (requestId: string, response: textToSpeech.StopResponse) => {
        this.speaking = false;
        this.invokeMethod('speak.onCancel', null);
      },
      onData: (requestId: string, audio: ArrayBuffer, response: textToSpeech.SynthesisResponse) => {
        // Audio data callback - not used for direct playback
      },
      onError: (requestId: string, errorCode: number, errorMessage: string) => {
        this.speaking = false;
        this.invokeMethod('speak.onError', errorMessage);
        this.completePendingResult(0);
      },
    };

    this.ttsEngine.setListener(listener);
  }

  private invokeMethod(method: string, args: Object | null): void {
    if (this.channel) {
      this.channel.invokeMethod(method, args);
    }
  }

  private completePendingResult(result: number): void {
    if (this.awaitSpeakCompletion && this.pendingResult) {
      this.pendingResult.success(result);
      this.pendingResult = null;
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'speak':
        this.speak(call, result);
        break;
      case 'stop':
        this.stop(result);
        break;
      case 'pause':
        // Pause is not directly supported by CoreSpeechKit
        result.success(0);
        break;
      case 'setLanguage':
        this.setLanguage(call, result);
        break;
      case 'setSpeechRate':
        this.setSpeechRate(call, result);
        break;
      case 'setVolume':
        this.setVolume(call, result);
        break;
      case 'setPitch':
        this.setPitch(call, result);
        break;
      case 'setVoice':
        this.setVoice(call, result);
        break;
      case 'clearVoice':
        this.clearVoice(result);
        break;
      case 'getLanguages':
        this.getLanguages(result);
        break;
      case 'getVoices':
        this.getVoices(result);
        break;
      case 'isLanguageAvailable':
        this.isLanguageAvailable(call, result);
        break;
      case 'awaitSpeakCompletion':
        this.awaitSpeakCompletion = call.args as boolean;
        result.success(1);
        break;
      case 'getSpeechRateValidRange':
        this.getSpeechRateValidRange(result);
        break;
      default:
        result.notImplemented();
    }
  }

  private speak(call: MethodCall, result: MethodResult): void {
    if (!this.ttsEngine) {
      result.error('TTS_NOT_READY', 'TTS engine is not initialized', null);
      return;
    }

    let text: string;
    if (typeof call.args === 'string') {
      text = call.args;
    } else if (call.args && typeof call.args === 'object') {
      text = (call.args as Record<string, Object>)['text'] as string;
    } else {
      result.error('INVALID_ARGUMENT', 'Text argument is required', null);
      return;
    }

    if (!text || text.length === 0) {
      result.success(1);
      return;
    }

    // Stop any ongoing speech
    if (this.speaking) {
      try {
        this.ttsEngine.stop();
      } catch (e) {
        // Ignore stop errors
      }
    }

    const speakParams: textToSpeech.SpeakParams = {
      requestId: `tts_${Date.now()}`,
      extraParams: {
        speed: this.speed,
        volume: this.volume,
        pitch: this.pitch,
      },
    };

    if (this.awaitSpeakCompletion) {
      this.pendingResult = result;
    }

    try {
      this.ttsEngine.speak(text, speakParams);
      if (!this.awaitSpeakCompletion) {
        result.success(1);
      }
    } catch (e) {
      console.error(TAG, `Failed to speak: ${JSON.stringify(e)}`);
      result.error('SPEAK_FAILED', `Failed to speak: ${JSON.stringify(e)}`, null);
    }
  }

  private stop(result: MethodResult): void {
    if (!this.ttsEngine) {
      result.success(1);
      return;
    }

    try {
      this.ttsEngine.stop();
      this.speaking = false;
      result.success(1);
    } catch (e) {
      console.error(TAG, `Failed to stop: ${JSON.stringify(e)}`);
      result.error('STOP_FAILED', `Failed to stop: ${JSON.stringify(e)}`, null);
    }
  }

  private setLanguage(call: MethodCall, result: MethodResult): void {
    const language = call.args as string;
    if (!language) {
      result.error('INVALID_ARGUMENT', 'Language argument is required', null);
      return;
    }

    this.language = language;
    // Recreate engine with new language
    this.shutdownTtsEngine();
    this.initTtsEngine();
    result.success(1);
  }

  private setSpeechRate(call: MethodCall, result: MethodResult): void {
    const rate = call.args as number;
    if (rate === undefined || rate === null) {
      result.error('INVALID_ARGUMENT', 'Rate argument is required', null);
      return;
    }

    // Flutter TTS uses 0.0-1.0 range, OHOS uses different scale
    // Map 0.0-1.0 to 0.5-2.0 (where 0.5 is normal)
    this.speed = 0.5 + rate * 1.5;
    result.success(1);
  }

  private setVolume(call: MethodCall, result: MethodResult): void {
    const volume = call.args as number;
    if (volume === undefined || volume === null) {
      result.error('INVALID_ARGUMENT', 'Volume argument is required', null);
      return;
    }

    this.volume = volume;
    result.success(1);
  }

  private setPitch(call: MethodCall, result: MethodResult): void {
    const pitch = call.args as number;
    if (pitch === undefined || pitch === null) {
      result.error('INVALID_ARGUMENT', 'Pitch argument is required', null);
      return;
    }

    this.pitch = pitch;
    result.success(1);
  }

  private setVoice(call: MethodCall, result: MethodResult): void {
    const voice = call.args as Record<string, string>;
    if (!voice) {
      result.error('INVALID_ARGUMENT', 'Voice argument is required', null);
      return;
    }

    // Extract person/voice ID if available
    if (voice['name']) {
      const personId = parseInt(voice['name'], 10);
      if (!isNaN(personId)) {
        this.person = personId;
        this.shutdownTtsEngine();
        this.initTtsEngine();
      }
    }

    result.success(1);
  }

  private clearVoice(result: MethodResult): void {
    this.person = 0;
    this.shutdownTtsEngine();
    this.initTtsEngine();
    result.success(1);
  }

  private getLanguages(result: MethodResult): void {
    // Use listVoices to get available languages
    const queryParams: textToSpeech.VoiceQuery = {
      requestId: `query_lang_${Date.now()}`,
      online: 1, // 1 for offline mode (currently only supported)
    };

    textToSpeech.listVoices(queryParams).then((voiceInfoList: textToSpeech.VoiceInfo[]) => {
      // Extract unique languages from voice list
      const languageSet = new Set<string>();
      voiceInfoList.forEach((voice: textToSpeech.VoiceInfo) => {
        if (voice.language) {
          languageSet.add(voice.language);
        }
      });
      const languages = Array.from(languageSet);
      result.success(languages);
    }).catch((err: BusinessError) => {
      console.error(TAG, `Failed to list voices for languages: ${err.message}`);
      // Fallback to commonly supported languages
      const languages: string[] = ['zh-CN', 'en-US'];
      result.success(languages);
    });
  }

  private getVoices(result: MethodResult): void {
    // Use listVoices API to get available voices
    const queryParams: textToSpeech.VoiceQuery = {
      requestId: `query_voice_${Date.now()}`,
      online: 1, // 1 for offline mode (currently only supported)
    };

    textToSpeech.listVoices(queryParams).then((voiceInfoList: textToSpeech.VoiceInfo[]) => {
      // Convert to format expected by flutter_tts
      const voices: VoiceInfoResult[] = [];
      for (const voice of voiceInfoList) {
        voices.push(new VoiceInfoResult(
          voice.person?.toString() ?? '0',
          voice.language ?? 'zh-CN',
          voice.gender ?? 'unknown',
          voice.status ?? 'unknown',
          voice.description ?? ''
        ));
      }
      result.success(voices);
    }).catch((err: BusinessError) => {
      console.error(TAG, `Failed to list voices: ${err.message}`);
      // Fallback to default voices
      const voices: VoiceInfoResult[] = [
        new VoiceInfoResult('0', 'zh-CN', 'Female', 'INSTALLED', '聆小珊'),
        new VoiceInfoResult('13', 'zh-CN', 'Female', 'INSTALLED', '聆小珊'),
      ];
      result.success(voices);
    });
  }

  private isLanguageAvailable(call: MethodCall, result: MethodResult): void {
    const language = call.args as string;
    if (!language) {
      result.error('INVALID_ARGUMENT', 'Language argument is required', null);
      return;
    }

    // Check if language is in supported list
    const supportedLanguages = ['zh-CN', 'zh-TW', 'en-US', 'en-GB'];
    const isAvailable = supportedLanguages.some(l =>
      language.toLowerCase().startsWith(l.split('-')[0].toLowerCase())
    );

    result.success(isAvailable ? 1 : 0);
  }

  private getSpeechRateValidRange(result: MethodResult): void {
    result.success(new SpeechRateRange(0.0, 0.5, 1.0, 'ohos'));
  }
}
