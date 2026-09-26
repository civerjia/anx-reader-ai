import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/enums/page_turn_mode.dart';
import 'package:anx_reader/enums/reading_info.dart';
import 'package:anx_reader/enums/translation_mode.dart';
import 'package:anx_reader/enums/writing_mode.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_style.dart';
import 'package:anx_reader/models/bookmark.dart';
import 'package:anx_reader/models/font_model.dart';
import 'package:anx_reader/models/read_theme.dart';
import 'package:anx_reader/models/reading_rules.dart';
import 'package:anx_reader/models/search_result_model.dart';
import 'package:anx_reader/models/toc_item.dart';
import 'package:anx_reader/page/book_player/image_viewer.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/book_toc.dart';
import 'package:anx_reader/providers/bookmark.dart';
import 'package:anx_reader/providers/chapter_content_bridge.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:anx_reader/providers/toc_search.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/models/tts_sentence.dart';
import 'package:anx_reader/service/tts/tts_handler.dart';
import 'package:anx_reader/utils/coordinates_to_part.dart';
import 'package:anx_reader/utils/js/convert_dart_color_to_js.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/webView/gererate_url.dart';
import 'package:anx_reader/utils/webView/webview_console_message.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:anx_reader/widgets/context_menu/context_menu.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/diagram.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/types_and_icons.dart';
import 'package:anx_reader/widgets/reading_page/style_widget.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import 'package:anx_reader/widgets/reading_page/page_curl.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsx_plus/iconsx_plus.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:url_launcher/url_launcher.dart';

import 'minute_clock.dart';

class EpubPlayer extends ConsumerStatefulWidget {
  final Book book;
  final String? cfi;
  final Function showOrHideAppBarAndBottomBar;
  final Function onLoadEnd;
  final List<ReadTheme> initialThemes;
  final Function updateParent;

  const EpubPlayer(
      {super.key,
      required this.showOrHideAppBarAndBottomBar,
      required this.book,
      this.cfi,
      required this.onLoadEnd,
      required this.initialThemes,
      required this.updateParent});

  @override
  ConsumerState<EpubPlayer> createState() => EpubPlayerState();
}

class EpubPlayerState extends ConsumerState<EpubPlayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late InAppWebViewController webViewController;
  late ContextMenu contextMenu;
  String cfi = '';
  double percentage = 0.0;
  String chapterTitle = '';
  String chapterHref = '';
  int chapterCurrentPage = 0;
  int chapterTotalPages = 0;
  OverlayEntry? contextMenuEntry;
  AnimationController? _animationController;
  Animation<double>? _animation;
  bool showHistory = false;
  bool canGoBack = false;
  bool canGoForward = false;
  late Book book;
  String? backgroundColor;
  String? textColor;
  Timer? styleTimer;
  String bookmarkCfi = '';
  bool bookmarkExists = false;
  WritingModeEnum writingMode = WritingModeEnum.horizontalTb;
  String? _lastSelectionContextText;
  bool _selectionClearLocked = false;
  bool _selectionClearPending = false;

  // Scroll wheel debounce
  Timer? _scrollDebounceTimer;
  double _accumulatedScrollDelta = 0;
  static const double _scrollThreshold = 50.0;

  // to know anytime if we are on top of navigation stack
  bool get _isTopOfNavigationStack =>
      ModalRoute.of(context)?.isCurrent ?? false;

  final _pageCurlKey = GlobalKey<PageCurlOverlayState>();

  /// Timing of the curl in progress, logged when it ends, so where a turn
  /// feels slow can be read from the phone's log rather than guessed.
  _CurlTiming? _curlTiming;
  Future<void> _pageCurlQueue = Future.value();
  int _pageCurlRunning = 0;
  _CurlDrag? _curlDrag;
  Timer? _curlDragWatchdog;
  Timer? _curlRescueTimer;

  /// The finger as Flutter sees it. The reader's own touch events die with its
  /// page when a turn loads the next chapter under the finger, and the curl
  /// then stood half turned; these keep coming.
  VelocityTracker? _finger;
  int? _fingerPointer;
  DateTime? _fingerLiftedAt;
  Offset? _fingerLiftedWhere;
  double _fingerLiftVx = 0;

  /// Taps waiting behind a turn in progress; one is kept, more are dropped, so
  /// a few quick taps do not run on page after page.
  int _curlTapsWaiting = 0;

  /// When the last turn finished, to tell a second tap from a steady read.
  DateTime? _lastCurlEndedAt;

  /// How long the page is given to settle when turns are coming one after
  /// another: enough to see it land, short enough to be ready for the next.
  static const _rushedSettle = Duration(milliseconds: 120);

  /// Whether the reader is going through pages rather than reading one.
  bool get _rushing {
    final ended = _lastCurlEndedAt;
    return _pageCurlRunning > 1 ||
        (ended != null &&
            DateTime.now().difference(ended).inMilliseconds < 600);
  }

  /// Which turn owns the overlay. A turn interrupted by the next one must not
  /// clear the page the new one is already showing.
  int _curlOwner = 0;

  /// Pictures of pages seen in this session, by cfi, oldest first, so a turn
  /// starts from a picture already in hand. Taking one when the finger goes
  /// down cost 110–150 ms on the phone — about half of a quick swipe — and
  /// held the finger's own events back for as long. Each is about 12 MB.
  final _pageImages = <String, ui.Image>{};

  /// For a page reached by turning, the page before it.
  final _previousOf = <String, String>{};
  static const _pageImageLimit = 5;
  Timer? _snapshotHereTimer;
  int _pageImagesGeneration = 0;

  bool get _usePageCurl => Prefs().pageTurnStyle == PageTurn.curl;

  Color get _paperColor =>
      Color(int.tryParse(Prefs().readTheme.backgroundColor, radix: 16) ??
          0xFFFBFBF3);

  /// Waits for one step of a curl, but never forever: a curl left waiting
  /// keeps a picture of a page over the reader.
  Future<T?> _curlStep<T>(Future<T> step, int ms, String what) async {
    try {
      return await step.timeout(Duration(milliseconds: ms));
    } on TimeoutException {
      AnxLog.info('Page curl: $what took over $ms ms; going on without it');
      return null;
    }
  }

  Future<void> _turnInstantly(bool forward, {bool quick = false}) async {
    final watch = Stopwatch()..start();
    final frames = quick
        // Through a run the page that follows is prefetched after its own
        // paint, so one frame is enough to hand the turn back.
        ? 'requestAnimationFrame(r)'
        : 'requestAnimationFrame(() => requestAnimationFrame(r))';
    await _curlStep(
      webViewController.callAsyncJavaScript(
          functionBody:
              "if (typeof clearSelection === 'function') { clearSelection(); } "
              "await ${forward ? 'nextPage' : 'prevPage'}(); "
              // Resolve once the new page has been drawn: a snapshot taken
              // right after would otherwise still show the page just left.
              "await new Promise(r => $frames);"),
      1500,
      'turning the reader',
    );
    _curlTiming?.add('turn', watch.elapsedMilliseconds);
  }

  void _forgetPageImages() {
    _snapshotHereTimer?.cancel();
    _pageImagesGeneration++;
    for (final image in _pageImages.values) {
      image.dispose();
    }
    _pageImages.clear();
    _previousOf.clear();
  }

  void _keepPageImage(String at, ui.Image image) {
    if (at.isEmpty) {
      image.dispose();
      return;
    }
    _pageImages.remove(at)?.dispose();
    _pageImages[at] = image;
    while (_pageImages.length > _pageImageLimit) {
      _pageImages.remove(_pageImages.keys.first)?.dispose();
    }
  }

  bool _capturingHere = false;

  /// Takes the picture of the page now showing while the curl is still
  /// animating, so the next turn of a run has it in hand instead of waiting
  /// for a snapshot of its own.
  Future<void> _captureHereNow(double width) async {
    if (_capturingHere) return;
    _capturingHere = true;
    final generation = _pageImagesGeneration;
    try {
      // The first frames of the curl are the ones worth protecting.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final at = await _readerPageKey();
      if (at == null || at.isEmpty || _pageImages.containsKey(at)) return;
      final image = await _snapshotReader(width: width, quiet: true);
      if (image == null) return;
      if (!mounted || generation != _pageImagesGeneration) {
        image.dispose();
        return;
      }
      _keepPageImage(at, image);
    } catch (_) {
      // The next turn takes its own picture.
    } finally {
      _capturingHere = false;
    }
  }

  /// A copy of the picture of the page at [at], for the overlay to own.
  ui.Image? _pageImageAt(String? at) =>
      at == null ? null : _pageImages[at]?.clone();

  /// Where the reader is, asked of the page itself. The location the app last
  /// heard of can still be the page before when a turn follows quickly, and
  /// pictures looked up by it showed the wrong page curling. [afterPaint]
  /// waits for the page to be drawn, for a snapshot to match.
  Future<String?> _readerPageKey({bool afterPaint = false}) async {
    final watch = Stopwatch()..start();
    final result = await _curlStep(
      webViewController.callAsyncJavaScript(
          functionBody: (afterPaint
                  ? 'await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); '
                  : '') +
              'return globalThis.reader?.view?.lastLocation?.cfi ?? null;'),
      afterPaint ? 800 : 300,
      'reading the page location',
    );
    if (!afterPaint) _curlTiming?.add('key', watch.elapsedMilliseconds);
    final value = result?.value;
    return value is String && value.isNotEmpty ? value : null;
  }

  /// The picture of the page before [here], when [here] was reached by
  /// turning.
  ui.Image? _previousPageImage(String? here) =>
      _pageImageAt(here == null ? null : _previousOf[here]);

  /// Keeps [picture] — the page left when turning forward, the page arrived
  /// at when turning back — under where the reader says the turn from [from]
  /// arrived, with which page comes before which.
  Future<void> _rememberArrival({
    required String from,
    required ui.Image picture,
    required bool forward,
  }) async {
    final generation = _pageImagesGeneration;
    final arrived = await _readerPageKey();
    if (arrived == null ||
        arrived == from ||
        !mounted ||
        generation != _pageImagesGeneration) {
      picture.dispose();
      return;
    }
    if (forward) {
      _keepPageImage(from, picture);
      _previousOf[arrived] = from;
    } else {
      _keepPageImage(arrived, picture);
      _previousOf[from] = arrived;
    }
  }

  /// Photographs the page being read once it has settled and been drawn,
  /// unless a picture is already kept, so the next turn forward starts
  /// without a snapshot. A picture whose page moved meanwhile is dropped.
  void _scheduleSnapshotHere() {
    if (!_usePageCurl) return;
    _snapshotHereTimer?.cancel();
    _snapshotHereTimer = Timer(const Duration(milliseconds: 250), () async {
      bool busy() => !mounted || _pageCurlRunning > 0 || _curlDrag != null;
      if (busy()) return;
      final generation = _pageImagesGeneration;
      final at = await _readerPageKey(afterPaint: true);
      if (at == null || busy() || _pageImages.containsKey(at)) return;
      final image = await _snapshotReader();
      if (image == null) return;
      final still = await _readerPageKey();
      if (busy() || generation != _pageImagesGeneration || still != at) {
        image.dispose();
        return;
      }
      _keepPageImage(at, image);
    });
  }

  /// A tap, key or volume-button turn: the page is picked up by its edge and
  /// turned the whole way. Turns asked for while one is running follow it.
  void _curlTurn({required bool forward}) {
    if (_curlDrag != null) {
      AnxLog.info('Page curl: tap during a drag ignored');
      return;
    }
    if (_curlTapsWaiting >= 3) {
      AnxLog.info('Page curl: tap dropped; three are already waiting');
      return;
    }
    final ended = _lastCurlEndedAt;
    // Turning the page again while one is still going, or right after one,
    // is someone looking for a page rather than reading: the curl takes about
    // half a second, and playing them in turn caps it at two pages a second.
    // Those turns go through at once, without the animation.
    final rushing = _pageCurlRunning > 0 ||
        (ended != null && DateTime.now().difference(ended).inMilliseconds < 400);
    _curlTapsWaiting++;
    _pageCurlQueue = _pageCurlQueue
        .then((_) {
          _curlTapsWaiting--;
          final quick = rushing || _curlTapsWaiting > 0;
          return _runCurl(
              () => quick ? _turnInstantly(forward) : _playCurl(forward),
              kind: quick ? 'quick' : 'tap',
              forward: forward);
        })
        .catchError((Object e) => AnxLog.info('Page curl: turn failed: $e'));
  }

  Future<void> _runCurl(Future<void> Function() body,
      {required String kind, required bool forward}) async {
    _pageCurlRunning++;
    final timing = _CurlTiming(kind: kind, forward: forward);
    _curlTiming = timing;
    void onFrames(List<ui.FrameTiming> frames) => timing.frames.addAll(frames);
    SchedulerBinding.instance.addTimingsCallback(onFrames);
    try {
      await body();
    } finally {
      _pageCurlRunning--;
      _lastCurlEndedAt = DateTime.now();
      timing.mark('done');
      _scheduleSnapshotHere();
      if (identical(_curlTiming, timing)) _curlTiming = null;
      // Frame timings arrive in batches; give the last one a moment.
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        SchedulerBinding.instance.removeTimingsCallback(onFrames);
        AnxLog.info(timing.summary());
      });
    }
  }

  Future<void> _playCurl(bool forward) async {
    final overlay = _pageCurlKey.currentState;
    if (overlay == null) return _turnInstantly(forward);
    final owner = ++_curlOwner;
    final rushing = _rushing;
    final settleWithin = rushing ? _rushedSettle : null;
    if (rushing) _curlTiming?.note('rush', 'yes');
    final size = overlay.size;
    final grab = Offset(size.width, size.height * 0.9);
    final away = turnedAwayFinger(size, grab);
    final here = await _readerPageKey();

    if (!forward) {
      final previous = _previousPageImage(here);
      _curlTiming?.note('cache', previous != null ? 'hit' : 'miss');
      if (previous != null) {
        try {
          overlay.curl(
              page: previous, grab: grab, finger: rolledAtLeftFinger(size, grab));
          _curlTiming?.mark('shown');
          await overlay.settle(grab, within: settleWithin);
          await _turnInstantly(false);
        } finally {
          if (owner == _curlOwner) overlay.clear();
        }
        return;
      }
    }

    final kept = _pageImageAt(here);
    _curlTiming?.note('here', kept != null ? 'hit' : 'miss');
    final current = kept ?? await _snapshotReader();
    if (current == null) return _turnInstantly(forward);
    final from = here ?? cfi;
    ui.Image? keep;
    try {
      if (forward) {
        keep = current.clone();
        overlay.curl(page: current, grab: grab, finger: grab);
        _curlTiming?.mark('shown');
        await _turnInstantly(true, quick: rushing);
        if (rushing) unawaited(_captureHereNow(size.width / 2));
        await overlay.settle(away, within: settleWithin);
        unawaited(_rememberArrival(from: from, picture: keep, forward: true));
        keep = null;
      } else {
        overlay.cover(current);
        _curlTiming?.mark('covered');
        await _turnInstantly(false, quick: rushing);
        final previous =
            await _snapshotReader(width: rushing ? size.width / 2 : null);
        if (previous == null) return;
        _curlTiming?.mark('shown');
        keep = previous.clone();
        overlay.curl(
            page: previous,
            under: current,
            grab: grab,
            finger: rolledAtLeftFinger(size, grab));
        await overlay.settle(grab, within: settleWithin);
        unawaited(_rememberArrival(from: from, picture: keep, forward: false));
        keep = null;
      }
    } finally {
      keep?.dispose();
      if (owner == _curlOwner) overlay.clear();
    }
  }

  /// A drag whose end never arrives (the system took the touch) must not leave
  /// a page hanging over the reader.
  void _armCurlWatchdog(_CurlDrag drag) {
    _curlDragWatchdog?.cancel();
    _curlDragWatchdog = Timer(const Duration(seconds: 4), () {
      if (!drag.released.isCompleted) {
        AnxLog.info('Page curl: no touch for 4 s; letting the page go');
        drag.released.complete(0);
      }
    });
  }

  /// A curl still running well after the finger let go is stuck somewhere: a
  /// page must never stay half turned. Clears it and logs how far it got.
  void _armCurlRescue(_CurlDrag drag) {
    _curlRescueTimer?.cancel();
    _curlRescueTimer = Timer(const Duration(seconds: 3), () {
      if (!identical(_curlDrag, drag)) return;
      AnxLog.info('Page curl: still running 3 s after release; clearing it. '
          '${_curlTiming?.summary() ?? ''}');
      _pageCurlKey.currentState?.clear();
    });
  }

  /// A drag streamed from the reader: the page edge at the height the finger
  /// went down follows the finger, and letting go finishes or undoes the turn.
  void _onCurlDrag(Map<dynamic, dynamic> event) {
    final phase = event['phase'];
    final point = Offset(
      (event['x'] as num?)?.toDouble() ?? 0,
      (event['y'] as num?)?.toDouble() ?? 0,
    );
    final drag = _curlDrag;
    final sentAt = (event['t'] as num?)?.toInt();
    if (sentAt != null) {
      _curlTiming?.bridge(DateTime.now().millisecondsSinceEpoch - sentAt);
    }
    switch (phase) {
      case 'start':
        final overlay = _pageCurlKey.currentState;
        if (overlay == null) return;
        // Letting go leaves the page settling for about 400 ms, and the last
        // drag is only forgotten once that has finished. A drag begun in that
        // time was dropped whole — as a second finger, or as arriving while a
        // curl ran — and the page did not follow the finger at all, which
        // capped turning at about two pages a second. A drag whose finger is
        // gone hands the page over here instead.
        if (drag != null) {
          if (!drag.released.isCompleted) return; // a second finger
          AnxLog.info('Page curl: new drag takes over from the settling page');
          _curlDrag = null;
        }
        if (_pageCurlRunning > 0) overlay.finishNow();
        final forward = event['forward'] == true;
        final grab = Offset(overlay.size.width, point.dy);
        final started = _CurlDrag(
          forward: forward,
          grab: grab,
          start: point,
          size: overlay.size,
          finger: forward ? point : rolledAtLeftFinger(overlay.size, grab),
          key: event['key'] as String?,
        );
        _curlDrag = started;
        _armCurlWatchdog(started);
        // A quick flick can be over before its start is bridged.
        final lifted = _fingerLiftedAt;
        if (_fingerPointer == null &&
            lifted != null &&
            DateTime.now().difference(lifted).inMilliseconds < 1000) {
          _letGo(started, _fingerLiftedWhere ?? point, _fingerLiftVx);
        }
        _pageCurlQueue = _pageCurlQueue
            .then((_) => _runCurl(() => _followCurlDrag(started),
                kind: 'drag', forward: forward))
            .catchError((Object e) => AnxLog.info('Page curl: drag failed: $e'))
            .whenComplete(() {
          if (identical(_curlDrag, started)) _curlDrag = null;
        });
      case 'move':
        if (drag == null || drag.followingNatively) return;
        final shown = drag.follow(point);
        drag.show?.call(shown);
        _armCurlWatchdog(drag);
      case 'end':
        if (drag == null) return;
        _curlDragWatchdog?.cancel();
            if (!drag.followingNatively) {
          final shown = drag.follow(point);
          drag.show?.call(shown);
        }
        if (!drag.released.isCompleted) {
          drag.released.complete((event['vx'] as num?)?.toDouble() ?? 0);
        }
        _armCurlRescue(drag);
    }
  }

  void _onFingerDown(PointerDownEvent event) {
    if (_fingerPointer != null) return;
    _fingerPointer = event.pointer;
    _fingerLiftedAt = null;
    _finger = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
  }

  void _onFingerMove(PointerMoveEvent event) {
    if (event.pointer != _fingerPointer) return;
    _finger?.addPosition(event.timeStamp, event.localPosition);
    final drag = _curlDrag;
    if (drag == null || drag.released.isCompleted) return;
    // Once the reader has started a drag, Flutter's own pointer drives it: the
    // reader's moves arrive later, and stop altogether when a turn loads the
    // next chapter under the finger. Waiting to notice that froze the page.
    drag.followingNatively = true;
    drag.show?.call(drag.follow(event.localPosition));
  }

  void _onFingerUp(PointerEvent event) {
    if (event.pointer != _fingerPointer) return;
    _fingerPointer = null;
    _fingerLiftedAt = DateTime.now();
    _fingerLiftedWhere = event.localPosition;
    // The reader's velocity is in px per ms, positive to the right.
    _fingerLiftVx = event is PointerUpEvent
        ? (_finger?.getVelocity().pixelsPerSecond.dx ?? 0) / 1000
        : 0;
    final drag = _curlDrag;
    if (drag != null && !drag.released.isCompleted) {
      _letGo(drag, event.localPosition, _fingerLiftVx);
    }
  }

  /// The finger is off the glass: the page goes at once, without waiting for
  /// the reader's end, which lags and after a chapter change never comes.
  void _letGo(_CurlDrag drag, Offset at, double vx) {
    if (drag.released.isCompleted) return;
    _curlDragWatchdog?.cancel();
    drag.followingNatively = true;
    drag.show?.call(drag.follow(at));
    drag.released.complete(vx);
    _armCurlRescue(drag);
  }

  /// Turning back: a flick to the right, or a page more than half unrolled,
  /// lays it down.
  bool _laysDown(double vx, _CurlDrag drag) {
    const flick = 0.25; // px per ms
    return vx > flick || (vx >= -flick && drag.progress >= 0.5);
  }

  bool _turnsAway(double vx, Offset finger, Size size) {
    const flick = 0.25; // px per ms
    return vx < -flick || (vx <= flick && finger.dx < size.width / 2);
  }

  Future<void> _followCurlDrag(_CurlDrag drag) async {
    final overlay = _pageCurlKey.currentState;
    if (overlay == null) {
      await drag.released.future;
      return;
    }
    final owner = ++_curlOwner;
    final rushing = _rushing;
    final settleWithin = rushing ? _rushedSettle : null;
    if (rushing) _curlTiming?.note('rush', 'yes');
    final size = overlay.size;
    final away = turnedAwayFinger(size, drag.grab);
    _curlTiming?.note('key', drag.key != null ? 'touch' : 'asked');
    final here = drag.key ?? await _readerPageKey();
    ui.Image? keep;
    try {
      if (!drag.forward) {
        final previous = _previousPageImage(here);
        _curlTiming?.note('cache', previous != null ? 'hit' : 'miss');
        if (previous != null) {
          // Back to the page just left: it is already in hand, so it follows
          // the finger at once over the live page, and the reader turns back
          // only if the page is laid down.
          overlay.curl(page: previous, grab: drag.grab, finger: drag.finger);
          _curlTiming?.mark('shown');
          drag.show = overlay.moveFinger;
          final vx = await drag.released.future;
          final laidDown = _laysDown(vx, drag);
          await overlay.settle(
              laidDown ? drag.grab : rolledAtLeftFinger(size, drag.grab),
              within: settleWithin);
          if (laidDown) await _turnInstantly(false);
          return;
        }
      }

      final kept = _pageImageAt(here);
      _curlTiming?.note('here', kept != null ? 'hit' : 'miss');
      // A full-size picture costs about 100 ms, paid on nearly every turn of
      // a run because the prefetch never gets an idle moment. Half the width
      // is half the wait, and the curled page is shaded and bent anyway.
      final current = kept ?? await _snapshotReader(width: rushing ? size.width / 2 : null);
      if (current == null) {
        final vx = await drag.released.future;
        if (drag.forward ? vx < 0 : vx > 0) await _turnInstantly(drag.forward);
        return;
      }
      final from = here ?? cfi;
      if (drag.forward) {
        keep = current.clone();
        overlay.curl(page: current, grab: drag.grab, finger: drag.finger);
        _curlTiming?.mark('shown');
        drag.show = overlay.moveFinger;
        await _turnInstantly(true, quick: rushing);
        if (rushing) unawaited(_captureHereNow(size.width / 2));
      } else {
        overlay.cover(current);
        _curlTiming?.mark('covered');
        await _turnInstantly(false, quick: rushing);
        final previous =
            await _snapshotReader(width: rushing ? size.width / 2 : null);
        if (previous == null) {
          await drag.released.future;
          return;
        }
        _curlTiming?.mark('shown');
        keep = previous.clone();
        overlay.curl(
            page: previous, under: current, grab: drag.grab, finger: drag.finger);
        drag.show = overlay.moveFinger;
      }

      final vx = await drag.released.future;
      _curlTiming?.mark('released');
      final bool completed;
      if (drag.forward) {
        completed = _turnsAway(vx, drag.finger, size);
        await overlay.settle(completed ? away : drag.grab, within: settleWithin);
      } else {
        completed = _laysDown(vx, drag);
        await overlay.settle(
            completed ? drag.grab : rolledAtLeftFinger(size, drag.grab),
            within: settleWithin);
      }
      // The reader already shows the page the turn was heading for; if the
      // hand went the other way, put it back before uncovering it.
      if (!completed) {
        await _turnInstantly(!drag.forward);
      } else {
        unawaited(_rememberArrival(
            from: from, picture: keep, forward: drag.forward));
        keep = null;
      }
    } finally {
      keep?.dispose();
      if (owner == _curlOwner) overlay.clear();
    }
  }

  Future<ui.Image?> _snapshotReader({double? width, bool quiet = false}) async {
    final watch = Stopwatch()..start();
    final timing = quiet ? null : _curlTiming;
    final bytes = await _curlStep(
      webViewController.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          compressFormat: CompressFormat.JPEG,
          // A curled page is bent and shaded; through a run the bytes and the
          // decode matter more than the last of the detail.
          quality: width == null ? 90 : 75,
          afterScreenUpdates: true,
          snapshotWidth: width,
        ),
      ),
      1200,
      'snapshot',
    );
    if (bytes == null) return null;
    final captured = watch.elapsedMilliseconds;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    timing
      ?..add('capture', captured)
      ..add('decode', watch.elapsedMilliseconds - captured)
      ..note('jpeg', '${bytes.length ~/ 1024}KB ${frame.image.width}x${frame.image.height}');
    if (watch.elapsedMilliseconds > 150) {
      AnxLog.info('Page curl: snapshot took ${watch.elapsedMilliseconds} ms');
    }
    return frame.image;
  }

  void prevPage() {
    if (_usePageCurl) {
      _curlTurn(forward: false);
      return;
    }
    webViewController.evaluateJavascript(source: '''
      if (typeof clearSelection === 'function') { clearSelection(); }
      prevPage();
      ''');
  }

  void nextPage() {
    if (_usePageCurl) {
      _curlTurn(forward: true);
      return;
    }
    webViewController.evaluateJavascript(source: '''
      if (typeof clearSelection === 'function') { clearSelection(); }
      nextPage();
      ''');
  }

  void prevChapter() {
    webViewController.evaluateJavascript(source: '''
      prevSection()
      ''');
  }

  void nextChapter() {
    webViewController.evaluateJavascript(source: '''
      nextSection()
      ''');
  }

  void setTranslationMode(TranslationModeEnum mode) {
    webViewController.evaluateJavascript(source: '''
      if (typeof reader.view !== 'undefined' && reader.view.setTranslationMode) {
        reader.view.setTranslationMode('${mode.code}');
      }
      ''');
  }

  Future<void> goToPercentage(double value) async {
    await webViewController.evaluateJavascript(source: '''
      goToPercent($value); 
      ''');
  }

  void setSelectionClearLocked(bool locked) {
    _selectionClearLocked = locked;
    if (!locked && _selectionClearPending) {
      _selectionClearPending = false;
      _lastSelectionContextText = null;
      removeOverlay();
      restoreReaderFocus();
    }
  }

  void restoreReaderFocus() {
    readingPageKey.currentState?.requestReaderFocus();
  }

  void changeTheme(ReadTheme readTheme) {
    // Kept page pictures no longer look like the pages.
    _forgetPageImages();
    textColor = readTheme.textColor;
    backgroundColor = readTheme.backgroundColor;

    String bc = convertDartColorToJs(readTheme.backgroundColor);
    String tc = convertDartColorToJs(readTheme.textColor);

    webViewController.evaluateJavascript(source: '''
      changeStyle({
        backgroundColor: '#$bc',
        fontColor: '#$tc',
      })
      ''');
  }

  void changeStyle(BookStyle? bookStyle) {
    // Kept page pictures no longer look like the pages.
    _forgetPageImages();
    styleTimer?.cancel();
    String bgimgUrl = Prefs().bgimg.getEffectiveUrl(
          isDarkMode: isDarkMode,
          autoAdjust: Prefs().autoAdjustReadingTheme,
        );

    styleTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      BookStyle style = bookStyle ?? Prefs().bookStyle;
      webViewController.evaluateJavascript(source: '''
      changeStyle({
        fontSize: ${style.fontSize},
        spacing: ${style.lineHeight},
        fontWeight: ${style.fontWeight},
        paragraphSpacing: ${style.paragraphSpacing},
        topMargin: ${style.topMargin},
        bottomMargin: ${style.bottomMargin},
        sideMargin: ${style.sideMargin},
        letterSpacing: ${style.letterSpacing},
        textIndent: ${style.indent},
        maxColumnCount: ${style.maxColumnCount},
        columnThreshold: ${style.columnThreshold},
        writingMode: '${Prefs().writingMode.code}',
        textAlign: '${Prefs().textAlignment.code}',
        backgroundImage: '$bgimgUrl',
        bgimgBlur: ${Prefs().bgimg.blur},
        bgimgOpacity: ${Prefs().bgimg.opacity},
        bgimgFit: '${Prefs().bgimgFit.code}',
        customCSS: `${Prefs().customCSS.replaceAll('`', '\\`')}`,
        customCSSEnabled: ${Prefs().customCSSEnabled},
        useBookStyles: ${Prefs().useBookStyles},
        headingFontSize: ${style.headingFontSize},
        codeHighlightTheme: '${Prefs().codeHighlightTheme.code}',
      })
      ''');
    });
  }

  void changeBgimgEffect() {
    // Kept page pictures no longer look like the pages.
    _forgetPageImages();
    if (!mounted) return;
    final bgimg = Prefs().bgimg;
    final bgimgUrl = bgimg.getEffectiveUrl(
      isDarkMode: isDarkMode,
      autoAdjust: Prefs().autoAdjustReadingTheme,
    );
    webViewController.evaluateJavascript(source: '''
      changeStyle({
        backgroundImage: '$bgimgUrl',
        bgimgBlur: ${bgimg.blur},
        bgimgOpacity: ${bgimg.opacity},
        bgimgFit: '${Prefs().bgimgFit.code}',
      })
    ''');
  }

  void changeReadingRules(ReadingRules readingRules) {
    webViewController.evaluateJavascript(source: '''
      readingFeatures({
        convertChineseMode: '${readingRules.convertChineseMode.name}',
        bionicReadingMode: ${readingRules.bionicReading},
      })
    ''');
  }

  void changeFont(FontModel font) {
    // Kept page pictures no longer look like the pages.
    _forgetPageImages();
    webViewController.evaluateJavascript(source: '''
      changeStyle({
        fontName: '${font.name}',
        fontPath: '${font.path}',
      })
    ''');
  }

  void changePageTurnStyle(PageTurn pageTurnStyle) {
    // Kept page pictures no longer look like the pages.
    _forgetPageImages();
    webViewController.evaluateJavascript(source: '''
      changeStyle({
        pageTurnStyle: '${pageTurnStyle.name}',
      })
    ''');
  }

  void goToHref(String href) =>
      webViewController.evaluateJavascript(source: "goToHref('$href')");

  void goToCfi(String cfi) =>
      webViewController.evaluateJavascript(source: "goToCfi('$cfi')");

  void addAnnotation(BookNote bookNote) {
    // Kept page pictures would miss the new highlight.
    _forgetPageImages();
    _scheduleSnapshotHere();
    final noteContent =
        (bookNote.content).replaceAll('\n', ' ').replaceAll("'", "\\'");
    webViewController.evaluateJavascript(source: '''
      addAnnotation({
        id: ${bookNote.id},
        type: '${bookNote.type}',
        value: '${bookNote.cfi}',
        color: '#${bookNote.color}',
        note: '$noteContent',
      })
      ''');
  }

  void addBookmark(BookmarkModel bookmark) {
    _forgetPageImages();
    _scheduleSnapshotHere();
    webViewController.evaluateJavascript(source: '''
      addAnnotation({
        id: ${bookmark.id},
        type: 'bookmark',
        value: '${bookmark.cfi}',
        color: '#000000',
        note: 'None',
      })
      ''');
  }

  void addBookmarkHere() {
    webViewController.evaluateJavascript(source: '''
      addBookmarkHere()
      ''');
  }

  void removeAnnotation(String cfi) {
    _forgetPageImages();
    _scheduleSnapshotHere();
    webViewController.evaluateJavascript(source: "removeAnnotation('$cfi')");
  }

  void clearSearch() {
    ref.read(tocSearchProvider.notifier).clear();
    _clearSearchHighlights();
  }

  void search(String text) {
    final sanitized = text.trim();
    if (sanitized.isEmpty) {
      clearSearch();
      return;
    }
    _clearSearchHighlights();
    ref.read(tocSearchProvider.notifier).start(sanitized);
    webViewController.evaluateJavascript(source: '''
      search('$sanitized', {
        'scope': 'book',
        'matchCase': false,
        'matchDiacritics': false,
        'matchWholeWords': false,
      })
    ''');
  }

  Future<void> runAiBookSearch(String keyword) async {
    ref.read(tocSearchProvider.notifier).start(keyword);
    final escaped = jsonEncode(keyword);
    await webViewController.evaluateJavascript(source: 'clearSearch()');
    await webViewController.evaluateJavascript(
      source:
        'search($escaped, {"scope":"book","matchCase":false,"matchDiacritics":false,"matchWholeWords":false})',
    );
  }

  void _clearSearchHighlights() {
    webViewController.evaluateJavascript(source: "clearSearch()");
  }

  Future<void> initTts({String? fromCfi}) async {
    if (fromCfi != null && fromCfi.isNotEmpty) {
      await webViewController.evaluateJavascript(
          source: "window.ttsFromCfi('$fromCfi')");
    } else {
      await webViewController.evaluateJavascript(source: "window.ttsHere()");
    }
  }

  /// Starts narration on the sentence it last stopped on when that sentence
  /// is still on this page, and from the page otherwise. Returns the sentence
  /// it resumed on, so narration starts with it rather than the one after.
  Future<String?> initTtsResuming() async {
    final saved = Prefs().takeTtsResumeCfi(widget.book.id);
    if (saved != null && saved.isNotEmpty) {
      try {
        final result = await webViewController.callAsyncJavaScript(
          functionBody: 'return await ttsResumeAt(${jsonEncode(saved)})',
        );
        final text = result?.value;
        if (text is String && text.isNotEmpty) return text;
      } catch (_) {
        // Fall through to starting from the page.
      }
    }
    await initTts();
    return null;
  }

  /// Saves the sentence being narrated, for [initTtsResuming] to return to.
  Future<void> rememberTtsPosition() async {
    try {
      final cfi = (await ttsCurrentDetail())?.cfi;
      if (cfi != null && cfi.isNotEmpty) {
        Prefs().setTtsResumeCfi(widget.book.id, cfi);
      }
    } catch (_) {}
  }

  void ttsStop() => webViewController.evaluateJavascript(source: "ttsStop()");

  Future<String> ttsNext() async => (await webViewController
          .callAsyncJavaScript(functionBody: "return await ttsNext()"))
      ?.value;

  Future<String> ttsPrev() async => (await webViewController
          .callAsyncJavaScript(functionBody: "return await ttsPrev()"))
      ?.value;

  Future<String> ttsPrevSection() async => (await webViewController
          .callAsyncJavaScript(functionBody: "return await ttsPrevSection()"))
      ?.value;

  Future<String> ttsNextSection() async => (await webViewController
          .callAsyncJavaScript(functionBody: "return await ttsNextSection()"))
      ?.value;

  Future<String> ttsPrepare() async =>
      (await webViewController.evaluateJavascript(source: "ttsPrepare()"));

  TtsSentence? _parseTtsSentence(dynamic value) {
    if (value is Map<dynamic, dynamic>) {
      try {
        return TtsSentence.fromMap(value);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  List<TtsSentence> _parseTtsSentences(dynamic value) {
    if (value is! List) return const [];

    final sentences = <TtsSentence>[];
    for (final item in value) {
      final sentence = _parseTtsSentence(item);
      if (sentence != null) {
        sentences.add(sentence);
      }
    }
    return sentences;
  }

  Future<TtsSentence?> ttsCurrentDetail() async {
    final result = await webViewController.callAsyncJavaScript(
      functionBody: 'return ttsCurrentDetail()',
    );
    return _parseTtsSentence(result?.value);
  }

  Future<List<TtsSentence>> ttsCollectDetails({
    required int count,
    bool includeCurrent = false,
    int offset = 1,
  }) async {
    final result = await webViewController.callAsyncJavaScript(
      functionBody:
          'return ttsCollectDetails($count, ${includeCurrent ? 'true' : 'false'}, $offset)',
    );
    return _parseTtsSentences(result?.value);
  }

  Future<void> ttsHighlightByCfi(String cfi) async {
    await webViewController.callAsyncJavaScript(
      functionBody: 'return ttsHighlightByCfi(${jsonEncode(cfi)})',
    );
  }

  Future<bool> isFootNoteOpen() async => (await webViewController
      .evaluateJavascript(source: "window.isFootNoteOpen()"));

  void backHistory() {
    webViewController.evaluateJavascript(source: "back()");
  }

  void forwardHistory() {
    webViewController.evaluateJavascript(source: "forward()");
  }

  void refreshToc() {
    webViewController.evaluateJavascript(source: "refreshToc()");
  }

  Future<String> theChapterContent() async =>
      await webViewController.evaluateJavascript(
        source: "theChapterContent()",
      );

  Future<String> previousContent(int count) async =>
      await webViewController.evaluateJavascript(
        source: "previousContent($count)",
      );

  Future<String> _getCurrentChapterContent({int? maxCharacters}) async {
    final raw = await theChapterContent();
    return _normalizeChapterContent(raw, maxCharacters);
  }

  Future<String> _getChapterContentByHref(
    String href, {
    int? maxCharacters,
  }) async {
    if (href.isEmpty) {
      return '';
    }

    final result = await webViewController.callAsyncJavaScript(
      functionBody:
          'return await getChapterContentByHref("${href.replaceAll('"', '\\"')}")',
    );

    final value = result?.value;
    if (value is String) {
      return _normalizeChapterContent(value, maxCharacters);
    }
    return '';
  }

  String _normalizeChapterContent(String? content, int? maxCharacters) {
    if (content == null || content.isEmpty) {
      return '';
    }
    final trimmed = content.trim();
    if (maxCharacters != null &&
        maxCharacters > 0 &&
        trimmed.length > maxCharacters) {
      return trimmed.substring(0, maxCharacters);
    }
    return trimmed;
  }

  void _registerChapterContentBridge() {
    ref.read(chapterContentBridgeProvider.notifier).state =
        ChapterContentHandlers(
      fetchCurrentChapter: ({int? maxCharacters}) =>
          _getCurrentChapterContent(maxCharacters: maxCharacters),
      fetchChapterByHref: (href, {int? maxCharacters}) =>
          _getChapterContentByHref(href, maxCharacters: maxCharacters),
    );
  }

  Future<void> _handleExternalLink(dynamic rawLink) async {
    String? normalizeExternalLink(dynamic raw) {
      if (raw == null) {
        return null;
      }
      if (raw is String && raw.trim().isNotEmpty) {
        return raw.trim();
      }
      if (raw is Map && raw['href'] is String) {
        final href = raw['href'].toString().trim();
        return href.isEmpty ? null : href;
      }
      return null;
    }

    final link = normalizeExternalLink(rawLink);
    if (!mounted || link == null) {
      return;
    }

    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme.isEmpty || uri.scheme == 'javascript') {
      AnxLog.warning('Ignored invalid external link: $link');
      return;
    }

    final shouldOpen = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = L10n.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.readingPageOpenExternalLinkTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.readingPageOpenExternalLinkMessage),
              const SizedBox(height: 8),
              SelectableText(link),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.readingPageOpenExternalLinkAction),
            ),
          ],
        );
      },
    );

    if (shouldOpen != true) {
      return;
    }

    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      AnxLog.warning('Failed to open external link: $link');
    }
  }

  void onClick(Map<String, dynamic> location) {
    readingPageKey.currentState?.resetAwakeTimer();
    if (contextMenuEntry != null) {
      removeOverlay();
      return;
    }
    final x = location['x'];
    final y = location['y'];
    final part = coordinatesToPart(x, y);

    PageTurningType action;
    final pageTurnMode = PageTurnMode.fromCode(Prefs().pageTurnMode);

    if (pageTurnMode == PageTurnMode.simple) {
      // Use predefined page turning types
      final currentPageTurningType = Prefs().pageTurningType;
      final pageTurningType = pageTurningTypes[currentPageTurningType];
      action = pageTurningType[part];

      // Apply swap if enabled
      if (Prefs().swapPageTurnArea) {
        if (action == PageTurningType.prev) {
          action = PageTurningType.next;
        } else if (action == PageTurningType.next) {
          action = PageTurningType.prev;
        }
      }
    } else {
      // Use custom configuration
      final customConfig = Prefs().customPageTurnConfig;
      action = PageTurningType.values[customConfig[part]];
    }

    // Disable mouse/touch page turning when keyboard shortcuts are enabled
    if (Prefs().keyboardShortcutTurnPage) {
      // Only allow menu action, disable prev/next page turning
      if (action == PageTurningType.prev || action == PageTurningType.next) {
        return;
      }
    }

    switch (action) {
      case PageTurningType.prev:
        prevPage();
        break;
      case PageTurningType.next:
        nextPage();
        break;
      case PageTurningType.menu:
        widget.showOrHideAppBarAndBottomBar(true);
        break;
      case PageTurningType.none:
        break;
    }
  }

  Future<void> renderAnnotations(InAppWebViewController controller) async {
    List<BookNote> annotationList =
        await bookNoteDao.selectBookNotesByBookId(widget.book.id);
    String allAnnotations =
        jsonEncode(annotationList.map((e) => e.toJson()).toList())
            .replaceAll('\'', '\\\'');
    controller.evaluateJavascript(source: '''
     const allAnnotations = $allAnnotations
     renderAnnotations()
    ''');
  }

  void getThemeColor() {
    if (Prefs().autoAdjustReadingTheme) {
      List<ReadTheme> themes = widget.initialThemes;
      final isDayMode =
          Theme.of(navigatorKey.currentContext!).brightness == Brightness.light;
      backgroundColor =
          isDayMode ? themes[0].backgroundColor : themes[1].backgroundColor;
      textColor = isDayMode ? themes[0].textColor : themes[1].textColor;
    } else {
      backgroundColor = Prefs().readTheme.backgroundColor;
      textColor = Prefs().readTheme.textColor;
    }
  }

  Future<void> setHandler(InAppWebViewController controller) async {
    controller.addJavaScriptHandler(
        handlerName: 'onLoadEnd',
        callback: (args) {
          widget.onLoadEnd();
        });

    controller.addJavaScriptHandler(
        handlerName: 'onRelocated',
        callback: (args) {
          Map<String, dynamic> location = args[0];
          if (cfi == location['cfi']) return;
          // if (chapterHref != location['chapterHref']) {
          //   refreshToc();
          // }
          setState(() {
            cfi = location['cfi'] ?? '';
            percentage =
                double.tryParse(location['percentage'].toString()) ?? 0.0;
            chapterTitle = location['chapterTitle'] ?? '';
            chapterHref = location['chapterHref'] ?? '';
            chapterCurrentPage = location['chapterCurrentPage'] ?? 0;
            chapterTotalPages = location['chapterTotalPages'] ?? 0;
            bookmarkExists = location['bookmark']['exists'] ?? false;
            bookmarkCfi = location['bookmark']['cfi'] ?? '';
            writingMode =
                WritingModeEnum.fromCode(location['writingMode'] ?? '');
          });
          ref.read(currentReadingProvider.notifier).update(
                cfi: cfi,
                percentage: percentage,
                chapterTitle: chapterTitle,
                chapterHref: chapterHref,
                chapterCurrentPage: chapterCurrentPage,
                chapterTotalPages: chapterTotalPages,
              );
          widget.updateParent();
          saveReadingProgress();
          readingPageKey.currentState?.resetAwakeTimer();
          _scheduleSnapshotHere();
        });
    controller.addJavaScriptHandler(
        handlerName: 'onCurlDrag',
        callback: (args) {
          final detail = args.isNotEmpty ? args[0] : null;
          if (detail is Map) _onCurlDrag(detail);
        });
    controller.addJavaScriptHandler(
        handlerName: 'onClick',
        callback: (args) {
          Map<String, dynamic> location = args[0];
          onClick(location);
        });
    controller.addJavaScriptHandler(
      handlerName: 'onExternalLink',
      callback: (args) async {
        final payload = args.isNotEmpty ? args.first : null;
        await _handleExternalLink(payload);
      },
    );
    controller.addJavaScriptHandler(
        handlerName: 'onSetToc',
        callback: (args) {
          List<dynamic> t = args[0];
          final toc = t.map((i) => TocItem.fromJson(i)).toList();
          ref.read(bookTocProvider.notifier).setToc(toc);
        });
    controller.addJavaScriptHandler(
        handlerName: 'onSelectionEnd',
        callback: (args) {
          removeOverlay();
          Map<String, dynamic> location = args[0];
          String cfi = location['cfi'];
          String text = location['text'];
          bool footnote = location['footnote'];
          final rawContextText = location['contextText']?.toString();
          _lastSelectionContextText =
              (rawContextText?.trim().isEmpty ?? true) ? null : rawContextText;
          double left = (location['pos']['left'] as num).toDouble();
          double top = (location['pos']['top'] as num).toDouble();
          double right = (location['pos']['right'] as num).toDouble();
          double bottom = (location['pos']['bottom'] as num).toDouble();
          showContextMenu(
            context,
            left,
            top,
            right,
            bottom,
            text,
            cfi,
            null,
            footnote,
            writingMode.isVertical ? Axis.vertical : Axis.horizontal,
            contextText: _lastSelectionContextText,
          );
        });
    controller.addJavaScriptHandler(
        handlerName: 'onSelectionCleared',
        callback: (args) {
          if (_selectionClearLocked) {
            _selectionClearPending = true;
            return;
          }
          _lastSelectionContextText = null;
          removeOverlay();
          restoreReaderFocus();
        });
    controller.addJavaScriptHandler(
        handlerName: 'onAnnotationClick',
        callback: (args) {
          Map<String, dynamic> annotation = args[0];

          if (annotation['annotation'] == null) {
            // Check if TTS is active and the click is on the currently read text
            final currentTtsState = TtsHandler().ttsStateNotifier.value;
            if (currentTtsState == TtsStateEnum.playing ||
                currentTtsState == TtsStateEnum.paused) {
              if (currentTtsState == TtsStateEnum.playing) {
                audioHandler.pause();
              } else {
                audioHandler.play();
              }
              return;
            }
          }

          int id = annotation['annotation']['id'];
          String cfi = annotation['annotation']['value'];
          String note = annotation['annotation']['note'];
          final rawContextText = annotation['contextText']?.toString();
          _lastSelectionContextText =
              (rawContextText?.trim().isEmpty ?? true) ? null : rawContextText;
          double left = (annotation['pos']['left'] as num).toDouble();
          double top = (annotation['pos']['top'] as num).toDouble();
          double right = (annotation['pos']['right'] as num).toDouble();
          double bottom = (annotation['pos']['bottom'] as num).toDouble();
          showContextMenu(
            context,
            left,
            top,
            right,
            bottom,
            note,
            cfi,
            id,
            false,
            writingMode.isVertical ? Axis.vertical : Axis.horizontal,
            contextText: _lastSelectionContextText,
          );
        });
    controller.addJavaScriptHandler(
      handlerName: 'onSearch',
      callback: (args) {
        Map<String, dynamic> search = args[0];
        setState(() {
          final tocSearch = ref.read(tocSearchProvider.notifier);
          if (search['process'] != null) {
            final progress = search['process'].toDouble();
            tocSearch.updateProgress(progress);
          } else {
            tocSearch.addResult(SearchResultModel.fromJson(search));
          }
        });
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'renderAnnotations',
      callback: (args) {
        renderAnnotations(controller);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onPushState',
      callback: (args) {
        Map<String, dynamic> state = args[0];
        if (!mounted) return;
        setState(() {
          canGoBack = state['canGoBack'];
          canGoForward = state['canGoForward'];
          showHistory = canGoBack || canGoForward;
        });
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onImageClick',
      callback: (args) {
        String image = args[0];
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) => ImageViewer(
                      image: image,
                      bookName: widget.book.title,
                    )));
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onFootnoteClose',
      callback: (args) {
        removeOverlay();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onPullUp',
      callback: (args) {
        widget.showOrHideAppBarAndBottomBar(true);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'handleBookmark',
      callback: (args) async {
        Map<String, dynamic> detail = args[0]['detail'];
        bool remove = args[0]['remove'];
        String cfi = detail['cfi'] ?? '';
        double percentage = double.parse(detail['percentage'].toString());
        String content = detail['content'];

        if (remove) {
          ref.read(bookmarkProvider(widget.book.id).notifier).removeBookmark(
                cfi: cfi,
              );
          bookmarkCfi = '';
          bookmarkExists = false;
        } else {
          BookmarkModel bookmark = await ref
              .read(BookmarkProvider(widget.book.id).notifier)
              .addBookmark(
                BookmarkModel(
                  bookId: widget.book.id,
                  cfi: cfi,
                  percentage: percentage,
                  content: content,
                  chapter: chapterTitle,
                  updateTime: DateTime.now(),
                  createTime: DateTime.now(),
                ),
              );
          bookmarkCfi = cfi;
          bookmarkExists = true;
          addBookmark(bookmark);
        }
        widget.updateParent();
        setState(() {});
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'translateText',
      callback: (args) async {
        try {
          String text = args[0];
          final service = Prefs().fullTextTranslateService;
          final from = Prefs().fullTextTranslateFrom;
          final to = Prefs().fullTextTranslateTo;

          return await service.provider
              .translateTextOnly(text, from, to, isFullText: true);
        } catch (e) {
          AnxLog.severe('Translation error: $e');
          return 'Translation error: $e';
        }
      },
    );
  }

  Future<void> onWebViewCreated(InAppWebViewController controller) async {
    if (AnxPlatform.isAndroid) {
      await InAppWebViewController.setWebContentsDebuggingEnabled(true);
    }
    webViewController = controller;
    setHandler(controller);
    _registerChapterContentBridge();

    // Initialize translation mode based on book-specific settings
    Future.delayed(const Duration(milliseconds: 300), () {
      setTranslationMode(Prefs().getBookTranslationMode(widget.book.id));
    });
  }

  void removeOverlay() {
    _selectionClearLocked = false;
    _selectionClearPending = false;
    if (contextMenuEntry == null || contextMenuEntry?.mounted == false) return;
    contextMenuEntry?.remove();
    contextMenuEntry = null;
  }

  Future<void> _handlePointerEvents(PointerEvent event) async {
    if (await isFootNoteOpen() || Prefs().pageTurnStyle == PageTurn.scroll) {
      return;
    }
    // Disable scroll wheel page turning when keyboard shortcuts are enabled
    if (Prefs().keyboardShortcutTurnPage) {
      return;
    }
    if (event is PointerScrollEvent) {
      _accumulatedScrollDelta += event.scrollDelta.dy;

      _scrollDebounceTimer?.cancel();
      _scrollDebounceTimer = Timer(const Duration(milliseconds: 80), () {
        if (_accumulatedScrollDelta.abs() >= _scrollThreshold) {
          if (_accumulatedScrollDelta > 0) {
            nextPage();
          } else {
            prevPage();
          }
        }
        _accumulatedScrollDelta = 0;
      });
    }
  }

  @override
  void initState() {
    book = widget.book;
    getThemeColor();

    contextMenu = ContextMenu(
      settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
      onCreateContextMenu: (hitTestResult) async {
        // webViewController.evaluateJavascript(source: "showContextMenu()");
      },
      onHideContextMenu: () {
        // removeOverlay();
      },
    );
    if (Prefs().openBookAnimation) {
      _animationController = AnimationController(
        duration: const Duration(milliseconds: 600),
        vsync: this,
      );
      _animation =
          Tween<double>(begin: 1.0, end: 0.0).animate(_animationController!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _animationController!.forward();
      });
    }
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  /// Whether the reader page has finished loading at least once, so a later
  /// check that finds no reader means it was lost, not still starting.
  bool _pageLoaded = false;
  bool _recovering = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_pageLoaded) return;
    // iOS may kill the web content process of an app in the background to
    // reclaim memory. The page is then gone and the reader stays white; the
    // termination callback is not always delivered, so look for ourselves.
    Future.delayed(const Duration(milliseconds: 600), () async {
      if (!mounted || _recovering) return;
      Object? alive;
      try {
        alive = await webViewController
            .evaluateJavascript(source: 'typeof reader')
            .timeout(const Duration(seconds: 2));
      } catch (e) {
        alive = 'error: $e';
      }
      if (alive != 'object') {
        await _recoverWebView('reader gone after resume ($alive)');
      }
    });
  }

  /// Loads the reader again at the current position after its page was lost.
  Future<void> _recoverWebView(String why) async {
    if (!mounted || _recovering) return;
    _recovering = true;
    final at = cfi.isNotEmpty ? cfi : widget.book.lastReadPosition;
    AnxLog.info('Reader: $why; reloading at ${at.isEmpty ? 'the start' : at}');
    try {
      _forgetPageImages();
      _pageCurlKey.currentState?.clear();
      final bookUrl = 'http://127.0.0.1:${Server().port}/book/'
          '${Uri.encodeComponent(widget.book.fileFullPath)}';
      await webViewController.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(generateUrl(
            bookUrl,
            at,
            backgroundColor: backgroundColor,
            textColor: textColor,
            isDarkMode: Theme.of(context).brightness == Brightness.dark,
          )),
        ),
      );
    } catch (e) {
      AnxLog.info('Reader: reload failed: $e');
    } finally {
      _recovering = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  Future<void> saveReadingProgress() async {
    if (cfi == '' || widget.cfi != null) return;
    Book book = widget.book;
    book.lastReadPosition = cfi;
    book.readingPercentage = percentage;
    await bookDao.updateBook(book);
    if (mounted) {
      ref.read(bookListProvider.notifier).refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollDebounceTimer?.cancel();
    _curlDragWatchdog?.cancel();
    _curlRescueTimer?.cancel();
    _forgetPageImages();
    _animationController?.dispose();
    saveReadingProgress();
    removeOverlay();
    super.dispose();
  }

  // PDF pages are fixed; pinching in is the only way to read small print.
  late final InAppWebViewSettings initialSettings = InAppWebViewSettings(
    supportZoom: widget.book.filePath.toLowerCase().endsWith('.pdf'),
    transparentBackground: true,
    isInspectable: kDebugMode,
    useHybridComposition: true,
  );

  bool get isDarkMode =>
      Theme.of(navigatorKey.currentContext!).brightness == Brightness.dark;

  void changeReadingInfo() {
    setState(() {});
  }

  Widget _buildHistoryCapsule() {
    final l10n = L10n.of(context);
    final buttonColor = Color(int.parse('0x$textColor')).withAlpha(200);

    // Common button style for all history navigation buttons
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(32),
      ),
    );

    // Helper method to create history navigation buttons
    Widget createHistoryButton(
        IconData icon, String label, VoidCallback onPressed) {
      return TextButton.icon(
        icon: Icon(icon, size: 18, color: buttonColor),
        label: Text(label, style: TextStyle(color: buttonColor, fontSize: 14)),
        onPressed: onPressed,
        style: buttonStyle,
      );
    }

    // Build buttons list
    final List<Widget> buttons = [];

    if (canGoBack) {
      buttons.add(createHistoryButton(
        Icons.arrow_back,
        l10n.historyBack,
        backHistory,
      ));
    }

    buttons.add(createHistoryButton(
      Icons.close,
      l10n.historyClose,
      () => setState(() => showHistory = false),
    ));

    if (canGoForward) {
      buttons.add(createHistoryButton(
        Icons.arrow_forward,
        l10n.historyForward,
        forwardHistory,
      ));
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
            child: Container(
              height: 32,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainer
                    .withAlpha(123),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: buttons,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget readingInfoWidget() {
    if (chapterCurrentPage == 0 && percentage == 0.0) {
      return const SizedBox();
    }

    final readingInfoColor = Color(int.parse('0x$textColor')).withAlpha(150);
    final iconColor = Color(int.parse('0x$textColor'));

    Widget getWidget(ReadingInfoEnum readingInfoEnum, TextStyle textStyle) {
      final batteryTextStyle = TextStyle(
        color: iconColor,
        fontSize: (textStyle.fontSize ?? 10) - 1,
      );
      final batteryIconSize = (textStyle.fontSize ?? 10) * 2.7;

      final chapterTitleWidget = Text(
        (chapterCurrentPage == 1 ? widget.book.title : chapterTitle),
        style: textStyle,
      );

      final chapterProgressWidget = Text(
        '$chapterCurrentPage/$chapterTotalPages',
        style: textStyle,
      );

      final bookProgressWidget =
          Text('${(percentage * 100).toStringAsFixed(2)}%', style: textStyle);

      final timeWidget = MinuteClock(textStyle: textStyle);

      final batteryWidget = FutureBuilder(
          future: Battery().batteryLevel,
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        0, (textStyle.fontSize ?? 10) * 0.08, 2, 0),
                    child: Text('${snapshot.data}', style: batteryTextStyle),
                  ),
                  Icon(
                    HeroIcons.battery_0,
                    size: batteryIconSize,
                    color: iconColor,
                  ),
                ],
              );
            } else {
              return const SizedBox();
            }
          });

      Widget batteryAndTimeWidget() => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              batteryWidget,
              const SizedBox(width: 5),
              timeWidget,
            ],
          );

      switch (readingInfoEnum) {
        case ReadingInfoEnum.chapterTitle:
          return chapterTitleWidget;
        case ReadingInfoEnum.chapterProgress:
          return chapterProgressWidget;
        case ReadingInfoEnum.bookProgress:
          return bookProgressWidget;
        case ReadingInfoEnum.battery:
          return batteryWidget;
        case ReadingInfoEnum.time:
          return timeWidget;
        case ReadingInfoEnum.batteryAndTime:
          return batteryAndTimeWidget();
        case ReadingInfoEnum.none:
          return const SizedBox(width: 30);
      }
    }

    final readingInfo = Prefs().readingInfo;

    final headerTextStyle = TextStyle(
      color: readingInfoColor,
      fontSize: readingInfo.header.fontSize,
    );
    final footerTextStyle = TextStyle(
      color: readingInfoColor,
      fontSize: readingInfo.footer.fontSize,
    );

    List<Widget> headerWidgets = [
      getWidget(readingInfo.header.left, headerTextStyle),
      getWidget(readingInfo.header.center, headerTextStyle),
      getWidget(readingInfo.header.right, headerTextStyle),
    ];

    List<Widget> footerWidgets = [
      getWidget(readingInfo.footer.left, footerTextStyle),
      getWidget(readingInfo.footer.center, footerTextStyle),
      getWidget(readingInfo.footer.right, footerTextStyle),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            top: readingInfo.header.verticalMargin,
            left: readingInfo.header.leftMargin,
            right: readingInfo.header.rightMargin,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: headerWidgets,
          ),
        ),
        const Spacer(),
        Padding(
          padding: EdgeInsets.only(
            bottom: readingInfo.footer.verticalMargin,
            left: readingInfo.footer.leftMargin,
            right: readingInfo.footer.rightMargin,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: footerWidgets,
          ),
        ),
      ],
    );
  }

  Widget buildWebviewWithIOSWorkaround(
      BuildContext context, String url, String initialCfi) {
    final webView = InAppWebView(
      webViewEnvironment: webViewEnvironment,
      initialUrlRequest: URLRequest(
        url: WebUri(
          generateUrl(
            url,
            initialCfi,
            backgroundColor: backgroundColor,
            textColor: textColor,
            isDarkMode: Theme.of(context).brightness == Brightness.dark,
          ),
        ),
      ),
      initialSettings: initialSettings,
      contextMenu: contextMenu,
      onLoadStop: (controller, uri) {
        _pageLoaded = true;
        onWebViewCreated(controller);
      },
      onWebContentProcessDidTerminate: (controller) {
        webViewController = controller;
        _recoverWebView('web content process terminated');
      },
      onConsoleMessage: webviewConsoleMessage,
    );

    if (!AnxPlatform.isIOS) {
      return SizedBox.expand(child: webView);
    }

    return SizedBox.expand(
      child: Stack(
        children: [
          webView,
          Positioned.fill(
            child: PointerInterceptor(
              intercepting: !_isTopOfNavigationStack,
              debug: false,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String uri = Uri.encodeComponent(widget.book.fileFullPath);
    String url = 'http://127.0.0.1:${Server().port}/book/$uri';
    String initialCfi = widget.cfi ?? widget.book.lastReadPosition;

    return Listener(
      onPointerSignal: (event) {
        _handlePointerEvents(event);
      },
      onPointerDown: _onFingerDown,
      onPointerMove: _onFingerMove,
      onPointerUp: _onFingerUp,
      onPointerCancel: _onFingerUp,
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            buildWebviewWithIOSWorkaround(context, url, initialCfi),
            Positioned.fill(
              child: IgnorePointer(child: PageCurlOverlay(key: _pageCurlKey, paper: _paperColor)),
            ),
            readingInfoWidget(),
            if (showHistory) _buildHistoryCapsule(),
            if (Prefs().openBookAnimation)
              SizedBox.expand(
                  child: IgnorePointer(
                ignoring: true,
                child: FadeTransition(
                    opacity: _animation!, child: BookCover(book: widget.book)),
              )),
          ],
        ),
      ),
    );
  }
}

class _CurlDrag {
  _CurlDrag({
    required this.forward,
    required this.grab,
    required this.start,
    required this.size,
    required this.finger,
    this.key,
  });

  final bool forward;

  /// Where the reader was when the finger went down, as it reported with the
  /// touch.
  final String? key;
  final Offset grab;

  /// Where the finger went down.
  final Offset start;
  final Size size;

  /// Where the grabbed page edge is drawn: under the finger when turning
  /// forward; when turning back, unrolled in proportion to the drag.
  Offset finger;

  /// Turning back: how far the previous page has been laid down, 0 to 1.
  double progress = 0;

  Offset follow(Offset point) {
    if (forward) return finger = point;
    final mapped = backTurnFinger(size: size, grab: grab, start: start, point: point);
    progress = mapped.progress;
    return finger = mapped.finger;
  }

  /// Flutter's own pointer events drive the drag; the reader's are ignored.
  bool followingNatively = false;

  /// Where finger moves go once the curl is on screen.
  void Function(Offset finger)? show;

  /// Completes with the horizontal velocity, in px per ms, when the finger lifts.
  final Completer<double> released = Completer<double>();
}

/// What one curl spent its time on. Milliseconds from its start.
class _CurlTiming {
  _CurlTiming({required this.kind, required this.forward});

  final String kind;
  final bool forward;
  final _watch = Stopwatch()..start();
  final _marks = <String, int>{};
  final _durations = <String, int>{};
  final _notes = <String, String>{};
  final frames = <ui.FrameTiming>[];
  final _bridge = <int>[];

  void mark(String name) => _marks.putIfAbsent(name, () => _watch.elapsedMilliseconds);
  void add(String name, int ms) => _durations[name] = (_durations[name] ?? 0) + ms;
  void note(String name, String value) => _notes[name] = value;
  void bridge(int ms) => _bridge.add(ms);

  String summary() {
    final spans = [for (final f in frames) f.totalSpan.inMicroseconds / 1000];
    // 120 Hz on a ProMotion phone leaves 8.3 ms a frame; 60 Hz leaves 16.7.
    final over8 = spans.where((ms) => ms > 8.4).length;
    final over16 = spans.where((ms) => ms > 16.8).length;
    final worst = spans.isEmpty ? 0 : spans.reduce(math.max);
    final build = frames.isEmpty
        ? 0
        : frames.map((f) => f.buildDuration.inMicroseconds).reduce(math.max) / 1000;
    final raster = frames.isEmpty
        ? 0
        : frames.map((f) => f.rasterDuration.inMicroseconds).reduce(math.max) / 1000;
    final bridge = _bridge.isEmpty
        ? '-'
        : 'avg ${(_bridge.reduce((a, b) => a + b) / _bridge.length).round()} max ${_bridge.reduce(math.max)} ms over ${_bridge.length}';
    return 'Page curl timing: $kind ${forward ? 'forward' : 'back'} '
        'marks=$_marks durations=$_durations notes=$_notes '
        'frames=${frames.length} over8ms=$over8 over16ms=$over16 '
        'worst=${worst.toStringAsFixed(1)}ms maxBuild=${build.toStringAsFixed(1)}ms '
        'maxRaster=${raster.toStringAsFixed(1)}ms bridge=$bridge';
  }
}
