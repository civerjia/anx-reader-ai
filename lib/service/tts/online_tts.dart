import 'dart:async';
import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/tts_service.dart';
import 'package:anx_reader/service/tts/tts_service_provider.dart';
import 'package:anx_reader/service/tts/models/tts_segment.dart';
import 'package:anx_reader/service/tts/models/tts_sentence.dart';
import 'package:anx_reader/service/tts/models/tts_voice.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

class OnlineTts extends BaseTts {
  static final OnlineTts _instance = OnlineTts._internal();

  factory OnlineTts() {
    return _instance;
  }

  OnlineTts._internal();

  // ============ Configuration ============
  static const int _bufferCapacity = 10;
  static const int _maxRetries = 2;

  // Max concurrent fetches and the per sentence timeout depend on the
  // backend: a network service answers in a second and likes parallelism,
  // a local model is slower and runs one sentence at a time.
  int get _batchSize => backend.maxConcurrentFetches;

  int get _fetchTimeoutSeconds => backend.fetchTimeoutSeconds;

  // ============ Audio Player ============
  AudioPlayer? _player;
  StreamSubscription<void>? _playerCompleteSubscription;

  // ============ Ordered Buffer ============
  // Segments are added in order; audio is fetched in background
  final List<TtsSegment> _buffer = [];
  final Set<String> _bufferKeys = {};
  TtsSegment? _currentSegment;
  String? _currentVoiceText;
  int _audioFetchVersion = 0; // Version counter for audio fetches
  // ============ Prefetcher State ============
  bool _isPrefetcherRunning = false;
  Completer<void>? _prefetcherCompleter;

  // ============ Player State ============
  bool _isPlayerRunning = false;
  Completer<void>? _playerCompleter;
  Completer<void>? _playbackCompleter;

  Timer? _settingsDebounce;

  // Timing of the seam between sentences, for diagnosing stutter.
  DateTime? _lastSentenceEnd;
  int _lastAdvanceMs = 0;

  // ============ Lifecycle ============
  late Function getHereFunction;
  late Function getNextTextFunction;
  late Function getPrevTextFunction;
  bool isInit = false;
  bool _shouldStop = false;

  // ============ Backend ============
  TtsServiceProvider? _currentBackend;

  TtsServiceProvider get backend {
    TtsService service = getTtsService(Prefs().ttsService);
    if (_currentBackend?.service != service) {
      _currentBackend = service.provider;
    }
    return _currentBackend!;
  }

  // ============ TtsStateNotifier ============
  @override
  final ValueNotifier<TtsStateEnum> ttsStateNotifier =
      ValueNotifier<TtsStateEnum>(TtsStateEnum.stopped);

  @override
  void updateTtsState(TtsStateEnum newState) {
    ttsStateNotifier.value = newState;
  }

  // ============ Properties ============
  @override
  double get volume => Prefs().ttsVolume;

  @override
  set volume(double volume) {
    Prefs().ttsVolume = volume;
    _player?.setVolume(volume);
  }

  @override
  double get pitch => Prefs().ttsPitch;

  @override
  set pitch(double pitch) {
    Prefs().ttsPitch = pitch;
    _scheduleResynthesis();
  }

  @override
  set rate(double rate) {
    Prefs().ttsRate = rate;
    _scheduleResynthesis();
  }

  /// Throw the buffered audio away once the user settles on a value.
  ///
  /// Dragging the slider sets the rate on every step, and each step used to
  /// discard the whole buffer and everything already in flight; with a local
  /// model that is seconds of inference thrown away per step, and the new
  /// speed took correspondingly longer to be heard.
  void _scheduleResynthesis() {
    _settingsDebounce?.cancel();
    _settingsDebounce = Timer(
      const Duration(milliseconds: 400),
      () {
        _settingsDebounce = null;
        _clearPendingAudio();
      },
    );
  }

  @override
  double get rate => Prefs().ttsRate;

  @override
  @override
  bool get isPlaying => ttsStateNotifier.value == TtsStateEnum.playing;

  @override
  String? get currentVoiceText => _currentVoiceText;

  @override
  Future<List<TtsVoice>> getVoices() async {
    return await backend.getVoices();
  }

  // ============ Initialization ============
  @override
  Future<void> init(Function getCurrentText, Function getNextText,
      Function getPrevText) async {
    getHereFunction = getCurrentText;
    getNextTextFunction = getNextText;
    getPrevTextFunction = getPrevText;
    isInit = true;
  }

  // ============ Audio Player Management ============
  Future<AudioPlayer> _ensurePlayer() async {
    if (_player != null) return _player!;

    _player = AudioPlayer();
    await _player!.setReleaseMode(ReleaseMode.stop);
    await _player!.setPlayerMode(PlayerMode.mediaPlayer);
    await _player!.setVolume(volume);

    _playerCompleteSubscription = _player!.onPlayerComplete.listen((_) {
      _playbackCompleter?.complete();
    });

    return _player!;
  }

  Future<void> _disposePlayer() async {
    await _player?.stop();
    await _playerCompleteSubscription?.cancel();
    _playerCompleteSubscription = null;
    await _player?.dispose();
    _player = null;
  }

  // ============ Buffer Management ============
  String _segmentKey(TtsSentence sentence) {
    if (sentence.cfi != null && sentence.cfi!.isNotEmpty) {
      return sentence.cfi!;
    }
    return '${sentence.text.hashCode}';
  }

  void _resetBuffer() {
    _buffer.clear();
    _bufferKeys.clear();
    _currentSegment = null;
    _currentVoiceText = null;
  }

  /// Clear audio for all pending segments (not currently playing)
  /// so they will be re-fetched with new settings
  void _clearPendingAudio() {
    _audioFetchVersion++; // Increment version to invalidate in-flight fetches
    for (final segment in _buffer) {
      // Clear audio so it will be re-fetched
      segment.audio = null;
      segment.isSilent = false;
      segment.fetchVersion = _audioFetchVersion; // Mark with current version
    }
    AnxLog.info(
        'Cleared pending audio buffer - will re-fetch with new settings (version: $_audioFetchVersion)');
  }

  // ============ Producer: Prefetcher Loop ============
  Future<void> _startPrefetcher() async {
    if (_isPrefetcherRunning) return;
    _isPrefetcherRunning = true;
    _prefetcherCompleter = Completer<void>();

    try {
      while (!_shouldStop) {
        // Check for segments that need audio re-fetch (after settings change)
        final segmentsNeedingAudio =
            _buffer.where((s) => !s.isReady && !s.isSilent).toList();

        if (segmentsNeedingAudio.isNotEmpty) {
          // Re-fetch audio for segments that were cleared
          for (var i = 0; i < segmentsNeedingAudio.length; i += _batchSize) {
            if (_shouldStop) break;
            final batch =
                segmentsNeedingAudio.skip(i).take(_batchSize).toList();
            final futures =
                batch.map((segment) => _fetchAudioForSegment(segment));
            await Future.wait(futures);
          }
        }

        final neededCount = _bufferCapacity - _buffer.length;

        if (neededCount <= 0) {
          await Future.delayed(const Duration(milliseconds: 50));
          continue;
        }

        // Collect sentences from the reader
        final sentences = await _collectSentences(neededCount);

        if (sentences.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 100));
          continue;
        }

        // Create placeholder segments in ORDER first
        final newSegments = <TtsSegment>[];
        for (final sentence in sentences) {
          if (_shouldStop) break;
          final key = _segmentKey(sentence);
          if (_bufferKeys.contains(key)) continue;

          _bufferKeys.add(key);
          final segment = TtsSegment(sentence: sentence);
          newSegments.add(segment);
          _buffer.add(segment); // Add in order!
        }

        // Now fetch audio in batches to limit concurrency
        for (var i = 0; i < newSegments.length; i += _batchSize) {
          if (_shouldStop) break;
          final batch = newSegments.skip(i).take(_batchSize).toList();
          final futures =
              batch.map((segment) => _fetchAudioForSegment(segment));
          await Future.wait(futures);
        }
      }
    } catch (e) {
      AnxLog.severe('Prefetcher error: $e');
    } finally {
      _isPrefetcherRunning = false;
      _prefetcherCompleter?.complete();
      _prefetcherCompleter = null;
    }
  }

  Future<List<TtsSentence>> _collectSentences(int count) async {
    final state = epubPlayerKey.currentState;
    if (state == null) return [];

    try {
      final sentences = await state.ttsCollectDetails(
        count: count,
        includeCurrent: _buffer.isEmpty && _currentSegment == null,
      );

      // Filter out already buffered sentences
      final newSentences = <TtsSentence>[];
      for (final s in sentences) {
        final key = _segmentKey(s);
        if (!_bufferKeys.contains(key)) {
          newSentences.add(s);
        }
      }

      // Note: We do NOT call getNextTextFunction here.
      // Advancing the reader position should only happen in the player loop
      // after playback completes, to avoid interfering with highlighting.

      return newSentences;
    } catch (e) {
      AnxLog.severe('Collect sentences error: $e');
      return [];
    }
  }

  Future<void> _fetchAudioForSegment(TtsSegment segment) async {
    if (_shouldStop) return;
    if (segment.isReady) return;

    // Capture the version at the start of fetching
    final targetVersion = segment.fetchVersion;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      if (_shouldStop) return;
      if (segment.isReady) return;

      try {
        final bytes = await backend
            .speak(
              segment.sentence.text,
              null,
              rate,
              pitch,
            )
            .timeout(Duration(seconds: _fetchTimeoutSeconds));

        // Check if version is still valid (settings haven't changed during fetch)
        if (segment.fetchVersion != targetVersion) {
          AnxLog.info(
              'Audio fetch completed but version changed - discarding (segment version: ${segment.fetchVersion}, target: $targetVersion)');
          return;
        }

        if (bytes.isEmpty) {
          segment.isSilent = true;
        } else {
          segment.audio = bytes;
        }
        return; // Success, exit retry loop
      } on TimeoutException {
        AnxLog.severe(
            'Fetch timeout (attempt ${attempt + 1}/$_maxRetries): "${segment.sentence.text.substring(0, segment.sentence.text.length.clamp(0, 20))}..."');
        if (attempt == _maxRetries) {
          // Check version before marking as silent
          if (segment.fetchVersion == targetVersion) {
            segment.isSilent = true;
          }
        }
      } catch (e) {
        AnxLog.severe('Fetch error (attempt ${attempt + 1}): $e');
        if (attempt == _maxRetries) {
          // Check version before marking as silent
          if (segment.fetchVersion == targetVersion) {
            segment.isSilent = true;
          }
        }
      }
    }
  }

  // ============ Consumer: Player Loop ============
  Future<void> _startPlayer() async {
    if (_isPlayerRunning) return;
    _isPlayerRunning = true;
    _playerCompleter = Completer<void>();

    final audioPlayer = await _ensurePlayer();

    try {
      while (!_shouldStop) {
        // Wait for buffer to have a segment
        while (_buffer.isEmpty && !_shouldStop) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        if (_shouldStop) break;

        // Get the FIRST segment (preserving order)
        final segment = _buffer.first;

        // Wait for this segment's audio to be ready
        final waitStart = DateTime.now();
        while (!segment.isReady && !_shouldStop) {
          await Future.delayed(const Duration(milliseconds: 30));
        }
        if (_shouldStop) break;
        final waitedMs = DateTime.now().difference(waitStart).inMilliseconds;

        // Now remove it from buffer
        _buffer.removeAt(0);
        _currentSegment = segment;
        _currentVoiceText = segment.sentence.text;

        // Highlight current sentence
        final highlightStart = DateTime.now();
        await _highlightSegment(segment);
        final highlightMs =
            DateTime.now().difference(highlightStart).inMilliseconds;

        // Everything between the end of the last sentence and the start of
        // this one is silence the listener hears as a stutter, so account
        // for it: waiting on synthesis, the highlight round trip to the
        // webview, and the reader advancing at the end of the last sentence.
        final gapMs = _lastSentenceEnd == null
            ? 0
            : DateTime.now().difference(_lastSentenceEnd!).inMilliseconds;
        AnxLog.info('TTS gap ${gapMs}ms '
            '(synthesis $waitedMs, highlight $highlightMs, '
            'advance ${_lastAdvanceMs}ms) buffer ${_buffer.length}');

        // Handle silent segment
        if (segment.isSilent) {
          await Future.delayed(const Duration(milliseconds: 100));
          await getNextTextFunction();
          _currentSegment = null;
          continue;
        }

        // Play audio
        _playbackCompleter = Completer<void>();
        final source =
            BytesSource(segment.audio!, mimeType: backend.audioMimeType);

        final playStart = DateTime.now();
        try {
          // The backend may have capped how fast it asked the model to
          // talk; the player makes up the difference.
          await audioPlayer.setPlaybackRate(backend.playbackRate);
          await audioPlayer.play(source);
          await _playbackCompleter!.future;
        } catch (e) {
          AnxLog.severe('Playback error: $e');
        }

        // A clip that stops well before its own length means the player cut
        // the end of the sentence off, which is otherwise hard to tell from
        // a model that simply stopped talking.
        final playedMs = DateTime.now().difference(playStart).inMilliseconds;
        // A clip played faster than real time is shorter by design.
        final rate = backend.playbackRate <= 0 ? 1.0 : backend.playbackRate;
        final clipMs = (_waveDurationMs(segment.audio!) / rate).round();
        if (clipMs > 0 && playedMs < clipMs - 250) {
          AnxLog.warning('TTS playback ended early: ${playedMs}ms of ${clipMs}ms'
              ' - "${segment.sentence.text}"');
        }

        _playbackCompleter = null;
        _currentSegment = null;
        _lastSentenceEnd = DateTime.now();

        // Advance reader position
        if (!_shouldStop) {
          final advanceStart = DateTime.now();
          await getNextTextFunction();
          _lastAdvanceMs =
              DateTime.now().difference(advanceStart).inMilliseconds;
        }
      }
    } catch (e) {
      AnxLog.severe('Player loop error: $e');
    } finally {
      _isPlayerRunning = false;
      _playerCompleter?.complete();
      _playerCompleter = null;
    }
  }

  /// Length of a RIFF clip in milliseconds, or 0 when it is not one.
  int _waveDurationMs(Uint8List bytes) {
    if (bytes.length < 44) return 0;
    final data = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);
    if (data.getUint32(0, Endian.big) != 0x52494646) return 0; // 'RIFF'
    final sampleRate = data.getUint32(24, Endian.little);
    final byteRate = data.getUint32(28, Endian.little);
    if (sampleRate == 0 || byteRate == 0) return 0;
    return ((bytes.length - 44) * 1000 / byteRate).round();
  }

  Future<void> _highlightSegment(TtsSegment segment) async {
    final state = epubPlayerKey.currentState;
    final cfi = segment.sentence.cfi;
    if (state == null || cfi == null || cfi.isEmpty) return;
    try {
      await state.ttsHighlightByCfi(cfi);
    } catch (_) {}
  }

  // ============ Public API ============
  @override
  Future<void> speak({String? content}) async {
    _shouldStop = false;
    updateTtsState(TtsStateEnum.playing);

    // Local backends load their model here, so failures surface before the
    // reader starts scrolling through silent sentences.
    try {
      await backend.prepare();
    } catch (e) {
      updateTtsState(TtsStateEnum.stopped);
      AnxLog.severe('TTS backend prepare failed: $e');
      rethrow;
    }

    // Sync to current location first
    try {
      await getHereFunction();
    } catch (_) {}

    // Start both loops
    unawaited(_startPrefetcher());
    await _startPlayer();
  }

  @override
  Future<void> stop() async {
    _settingsDebounce?.cancel();
    _settingsDebounce = null;
    _shouldStop = true;
    _lastSentenceEnd = null;
    _lastAdvanceMs = 0;
    updateTtsState(TtsStateEnum.stopped);

    // Complete any pending playback
    _playbackCompleter?.complete();

    // Wait for loops to finish
    await _prefetcherCompleter?.future;
    await _playerCompleter?.future;

    // Cleanup
    await _disposePlayer();
    _resetBuffer();
  }

  @override
  Future<void> pause() async {
    await _player?.pause();
    updateTtsState(TtsStateEnum.paused);
  }

  @override
  Future<void> resume() async {
    await _player?.resume();
    updateTtsState(TtsStateEnum.playing);
  }

  @override
  Future<void> prev() async {
    await stop();
    await getPrevTextFunction();
    await speak();
  }

  @override
  Future<void> next() async {
    await stop();
    await getNextTextFunction();
    await speak();
  }

  @override
  Future<void> restart() async {
    await stop();
    await speak();
  }

  /// For testing a specific voice in settings
  Future<void> speakWithVoice(String content, String voice) async {
    await stop();
    await backend.prepare();
    final audioPlayer = await _ensurePlayer();

    final bytes = await backend.speak(content, voice, rate, pitch);
    if (bytes.isNotEmpty) {
      final source = BytesSource(bytes, mimeType: backend.audioMimeType);
      await audioPlayer.setPlaybackRate(backend.playbackRate);
      await audioPlayer.play(source);
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await backend.release();
    isInit = false;
  }
}
