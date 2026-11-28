import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sigg_launcher/services/audio_log.dart';
import 'package:sigg_launcher/services/soloud_backend.dart';

/// Plays the short UI "selection changed" tick (XMB-style), fired by
/// keyboard/gamepad navigation whenever the focused item moves.
///
/// Deliberately separate from [BgmPlayer]: it is a one-shot, non-looping
/// blip that should not fight the game's background music over volume or
/// release mode. It is best-effort — plugin failures permanently disable it
/// so navigation never breaks on sound.
///
/// The click [AudioSource] is loaded once into memory and reused for every
/// tick. Overlapping ticks (e.g. gamepad auto-repeat at ~8 Hz) create
/// multiple simultaneous voices from the same source — no source creation or
/// disposal per tick, which was the single most expensive audio operation
/// under `audioplayers`.
///
/// A shared load future ensures that rapid, overlapping `selectionChanged()`
/// calls trigger exactly one `loadAsset` — subsequent calls await the same
/// future instead of each starting their own load.
class UiSounds {
  UiSounds._();

  static final UiSounds instance = UiSounds._();

  /// The SoLoud engine. Inject a fake in tests via [debugReset].
  SoloudBackend _engine = SoloudEngine.instance;

  int? _tickSourceId;
  Future<int>? _tickSourceLoadFuture;

  bool _unavailable = false;
  bool _enabled = true;
  double _volume = 1.0;

  bool _reportedInitFailure = false;

  @visibleForTesting
  int debugSourcesLoaded = 0;

  @visibleForTesting
  int debugSourcesDisposed = 0;

  bool get enabled => _enabled;

  double get volume => _volume;

  /// Silences the player (used by tests where no audio plugin exists). Mirrors
  /// the permanent latched state an engine failure triggers in production.
  @visibleForTesting
  void debugDisable() {
    _unavailable = true;
    unawaited(_disposeSource());
  }

  @visibleForTesting
  void debugReset({SoloudBackend? engine}) {
    _engine = engine ?? SoloudEngine.instance;
    _unavailable = false;
    _enabled = true;
    _volume = 1.0;
    debugSourcesLoaded = 0;
    debugSourcesDisposed = 0;
    unawaited(_disposeSource());
  }

  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      unawaited(_disposeSource());
    }
  }

  Future<void> setVolume(double volume) async {
    final next = volume.clamp(0.0, 1.0).toDouble();
    if (_volume == next) return;
    _volume = next;
    // The tick source is shared across all voices; volume applies to new
    // playback. Already-playing voices keep their volume until they end.
  }

  Future<void> selectionChanged() async {
    if (_unavailable || !_enabled) return;
    // If the engine failed to initialize, report the original failure once and
    // permanently disable UI sounds instead of repeatedly throwing
    // "SoloudEngine not initialized".
    if (_engine.initError != null) {
      if (!_reportedInitFailure) {
        logAudioError(
          'ui-init',
          'SoloudEngine failed to initialize: ${_engine.initError}; '
          'UI sounds are unavailable',
        );
        _reportedInitFailure = true;
      }
      _unavailable = true;
      unawaited(_disposeSource());
      return;
    }
    try {
      final sourceId = await _ensureTickSource();
      if (_unavailable) return;
      _engine.play(sourceId, volume: _volume);
    } catch (error, stackTrace) {
      logAudioError('ui-sound', error, stackTrace);
      _unavailable = true;
      await _disposeSource();
    }
  }

  /// Ensures the click source is loaded, sharing a single load future across
  /// concurrent callers so rapid overlapping ticks trigger exactly one load.
  Future<int> _ensureTickSource() async {
    if (_tickSourceId != null) return _tickSourceId!;
    _tickSourceLoadFuture ??= _engine.loadAsset('assets/sfx/click.wav');
    final loadFuture = _tickSourceLoadFuture!;
    try {
      final sourceId = await loadFuture;
      _tickSourceId = sourceId;
      return sourceId;
    } finally {
      _tickSourceLoadFuture = null;
    }
  }

  Future<void> _disposeSource() async {
    final sourceId = _tickSourceId;
    _tickSourceId = null;
    _tickSourceLoadFuture = null;
    if (sourceId == null) return;
    try {
      await _engine.disposeSource(sourceId);
      debugSourcesDisposed++;
    } catch (error, stackTrace) {
      logAudioError('ui-dispose-source', error, stackTrace);
    }
  }
}
