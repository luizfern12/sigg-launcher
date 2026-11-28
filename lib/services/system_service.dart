import 'dart:io';

import 'package:flutter/foundation.dart';

/// Host power actions available from the home header's power button.
enum PowerRequest { powerOff, reboot }

/// Talks to the host's service manager to power off or reboot the machine.
///
/// Invoking these from a debug or test session must never touch the host:
/// [isSafeSession] is true while running with asserts enabled (debug builds
/// and `flutter test` alike) and whenever `SIGG_SKIP_SHUTDOWN` is present in
/// the environment — CI, packaging or sandboxed runs can set it to force safe
/// mode. Every power method is a no-op in that case.
class SystemService {
  SystemService._();

  static final SystemService instance = SystemService._();

  /// Whether host power actions are currently disabled. True for debug builds
  /// and test sessions (asserts are enabled there), and when
  /// `SIGG_SKIP_SHUTDOWN` is set in the environment.
  bool get isSafeSession {
    if (Platform.environment.containsKey('SIGG_SKIP_SHUTDOWN')) {
      return true;
    }
    if (kDebugMode) {
      return true;
    }
    final env = Platform.environment;
    if (env.containsKey('FLUTTER_TEST') ||
        (env.containsKey('CI') && env.containsKey('GITHUB_ACTIONS'))) {
      return true;
    }
    return false;
  }

  /// Requests [action] on the host. Returns `true` when the action was
  /// dispatched to `systemctl`, `false` when it was skipped (safe session or
  /// unsupported platform) or failed. Never throws.
  Future<bool> request(PowerRequest action) async {
    if (isSafeSession) {
      debugPrint('SystemService: skipping $action (safe session: debug/test)');
      return false;
    }
    if (!Platform.isLinux) {
      debugPrint(
        'SystemService: power actions are only supported on Linux '
        '(${Platform.operatingSystem})',
      );
      return false;
    }
    try {
      final result = await Process.run(
        'systemctl',
        action == PowerRequest.powerOff ? <String>['poweroff'] : <String>['reboot'],
      );
      return result.exitCode == 0;
    } catch (error, stackTrace) {
      debugPrint('SystemService: $action failed: $error\n$stackTrace');
      return false;
    }
  }
}
