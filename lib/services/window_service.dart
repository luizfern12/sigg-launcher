import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the platform did with a [WindowService] request.
///
/// The launcher must keep working whichever embedder it runs under: the GTK
/// runner hides the real toplevel, the ivi-homescreen embedder parks frame
/// production, and a test harness has neither. Callers only ever log this, so
/// a request that could not fully take effect never blocks a game launch.
enum WindowVisibility {
  /// The request was accepted. For `hide` that means frames stopped (the
  /// embedder parked vsync); for `show` the window is visible again.
  applied,

  /// The platform has no window channel at all (tests, `flutter test`, or a
  /// runner that never registered it). Nothing to do; not an error.
  unavailable,

  /// The embedder has the channel but cannot stop frame production (e.g. the
  /// Wayland host advertises no `wp_presentation`, or `IVI_WL_VSYNC=0`).
  /// The window stays visible over the game; the launch still proceeds.
  notParked,
}

/// Thin wrapper over the `sigg_launcher/window` platform channel.
///
/// The embedder is free to implement `hide`/`show` differently (GTK hides the
/// window; ivi-homescreen parks vsync), so this service deliberately knows
/// nothing about either: it sends the same two method names and, if the
/// platform answers with a `{parked: bool}` map, reports [WindowVisibility].
class WindowService {
  WindowService._();

  static const String channelName = 'sigg_launcher/window';

  static MethodChannel? _override;

  static MethodChannel get _channel =>
      _override ?? const MethodChannel(channelName);

  /// Replaces the channel for tests. Pass null to restore the real one.
  @visibleForTesting
  static set debugChannel(MethodChannel? channel) => _override = channel;

  /// Asks the platform to hide the window while a game runs.
  static Future<WindowVisibility> hide() => _invoke('hide', parkOnSuccess: true);

  /// Asks the platform to show the window again.
  static Future<WindowVisibility> show() =>
      _invoke('show', parkOnSuccess: false);

  static Future<WindowVisibility> _invoke(
    String method, {
    required bool parkOnSuccess,
  }) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method);
      return _parse(result, parkOnSuccess: parkOnSuccess);
    } on MissingPluginException {
      // No channel registered: tests and non-window embedders.
      return WindowVisibility.unavailable;
    } on PlatformException catch (e) {
      if (e.code == 'not-parked') {
        // Expected on a host without presentation feedback. Not fatal: the
        // game is already starting and the launcher simply stays visible.
        debugPrint(
          'WindowService.$method: platform cannot park frame production '
          '(${e.message ?? e.code}); continuing.',
        );
        return WindowVisibility.notParked;
      }
      // Any other platform error is reported, never thrown: a failed window
      // request must not abort a launch or strand the launcher hidden.
      debugPrint('WindowService.$method failed: ${e.code} ${e.message ?? ''}');
      return WindowVisibility.unavailable;
    }
  }

  /// `{parked: bool}` comes from ivi-homescreen. The GTK runner answers
  /// nothing (null), which means "done, nothing to report".
  ///
  /// Only `hide` treats `parked: false` as a failure: it means frames are
  /// still being produced. After `show`, `parked` may still be true because
  /// another reason holds the view (its output is gone) -- the launcher can do
  /// nothing about that, so the request itself still succeeded.
  static WindowVisibility _parse(
    Object? result, {
    required bool parkOnSuccess,
  }) {
    if (result is Map) {
      final parked = result['parked'];
      if (parkOnSuccess && parked is bool && !parked) {
        return WindowVisibility.notParked;
      }
    }
    return WindowVisibility.applied;
  }
}
