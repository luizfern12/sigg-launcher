import 'package:flutter_test/flutter_test.dart';
import 'package:sigg_launcher/services/system_service.dart';

void main() {
  test('SystemService treats test sessions as unsafe for the host', () {
    // flutter test runs with asserts enabled (kDebugMode), so power actions
    // must never reach the host from here.
    expect(SystemService.instance.isSafeSession, isTrue);
  });

  test('SystemService power actions are no-ops in test sessions', () async {
    expect(
      await SystemService.instance.request(PowerRequest.powerOff),
      isFalse,
      reason: 'shutdown must be skipped in a test session',
    );
    expect(
      await SystemService.instance.request(PowerRequest.reboot),
      isFalse,
      reason: 'reboot must be skipped in a test session',
    );
  });
}
