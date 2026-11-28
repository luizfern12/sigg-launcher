import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sigg_launcher/services/window_service.dart';

/// The launcher runs under two embedders plus tests, so [WindowService] has to
/// turn every possible platform answer into a value, never an exception:
///
/// * GTK runner: `hide`/`show` succeed with no result.
/// * ivi-homescreen: `{parked: bool}`, or `PlatformException("not-parked")`
///   when vsync parking cannot take effect.
/// * tests / no channel: `MissingPluginException`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(WindowService.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);

  tearDown(() {
    WindowService.debugChannel = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('hide reports applied when the embedder parked vsync', () async {
    answer((_) => {'parked': true});

    expect(await WindowService.hide(), WindowVisibility.applied);
    expect(calls.single.method, 'hide');
  });

  test('hide reports notParked, without throwing, when frames continue',
      () async {
    answer((_) => {'parked': false});

    expect(await WindowService.hide(), WindowVisibility.notParked);
  });

  test('hide maps PlatformException("not-parked") to notParked', () async {
    answer((_) {
      throw PlatformException(
        code: 'not-parked',
        message: 'vsync parking is unavailable on this display',
      );
    });

    expect(await WindowService.hide(), WindowVisibility.notParked);
  });

  test('an unexpected platform error is reported, not thrown', () async {
    answer((_) => throw PlatformException(code: 'boom'));

    expect(await WindowService.hide(), WindowVisibility.unavailable);
  });

  test('a missing channel is unavailable, not an error', () async {
    // No handler installed: MethodChannel throws MissingPluginException.
    messenger.setMockMethodCallHandler(channel, null);

    expect(await WindowService.hide(), WindowVisibility.unavailable);
  });

  test('show accepts the GTK runner\'s empty answer', () async {
    answer((_) => null);

    expect(await WindowService.show(), WindowVisibility.applied);
    expect(calls.single.method, 'show');
  });

  test('show is applied even if another reason still holds the view parked',
      () async {
    answer((_) => {'parked': true});

    expect(await WindowService.show(), WindowVisibility.applied);
  });

  test('a mocked channel can replace the real one', () async {
    final mock = MethodChannel('${WindowService.channelName}.test');
    final mockCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(mock, (call) async {
      mockCalls.add(call);
      return {'parked': true};
    });
    WindowService.debugChannel = mock;

    expect(await WindowService.hide(), WindowVisibility.applied);
    expect(mockCalls.single.method, 'hide');
  });
}
