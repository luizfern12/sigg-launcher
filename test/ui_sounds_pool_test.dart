import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sigg_launcher/services/ui_sounds.dart';

import 'fake_soloud_backend.dart';

Future<void> waitFor(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail(reason ?? 'condition was not met in time');
}

void main() {
  setUp(() {
    UiSounds.instance.debugReset();
  });

  tearDown(() {
    UiSounds.instance.debugReset();
  });

  test('source is loaded once and reused for every tick', () async {
    final engine = FakeSoloudBackend();
    UiSounds.instance.debugReset(engine: engine);

    for (var i = 0; i < 6; i++) {
      await UiSounds.instance.selectionChanged();
    }

    // One source load, six plays.
    expect(engine.loadCalls.length, equals(1));
    expect(engine.loadCalls.first.kind, 'asset');
    expect(engine.loadCalls.first.path, 'assets/sfx/click.wav');
    expect(engine.playCalls.length, equals(6));
    expect(engine.playCalls.every((call) => call.volume == 1.0), isTrue);
  });

  test('volume is applied to every new tick', () async {
    final engine = FakeSoloudBackend();
    UiSounds.instance.debugReset(engine: engine);

    await UiSounds.instance.selectionChanged();
    await UiSounds.instance.setVolume(0.4);
    await UiSounds.instance.selectionChanged();
    await UiSounds.instance.selectionChanged();

    expect(engine.playCalls.map((c) => c.volume), [1.0, 0.4, 0.4]);

    // Setting the same volume must not hit the engine again (no-op check
    // happens in setVolume before any engine call).
    await UiSounds.instance.setVolume(0.4);
    expect(engine.playCalls.length, equals(3), reason: 'unchanged volume must not add plays');
  });

  test(
    'disabling disposes the source and re-enabling reloads lazily',
    () async {
      final engine = FakeSoloudBackend();
      UiSounds.instance.debugReset(engine: engine);

      await UiSounds.instance.selectionChanged();
      expect(engine.loadCalls.length, equals(1));
      expect(engine.disposedSourceIds, isEmpty);

      UiSounds.instance.setEnabled(false);
      await waitFor(
        () => engine.disposedSourceIds.length == 1,
        reason: 'source was not disposed',
      );

      await UiSounds.instance.selectionChanged();
      expect(engine.loadCalls.length, equals(1),
          reason: 'disabled source must be idle (no reload)');

      UiSounds.instance.setEnabled(true);
      await UiSounds.instance.selectionChanged();
      expect(engine.loadCalls.length, equals(2));
      expect(engine.playCalls.length, equals(2));
    },
  );

  test('overlapping ticks create distinct voices from the same source', () async {
    final engine = FakeSoloudBackend();
    UiSounds.instance.debugReset(engine: engine);

    await Future.wait([
      UiSounds.instance.selectionChanged(),
      UiSounds.instance.selectionChanged(),
      UiSounds.instance.selectionChanged(),
    ]);

    expect(engine.loadCalls.length, equals(1),
        reason: 'source must be loaded once, not per tick');
    expect(engine.playCalls.length, equals(3),
        reason: 'three ticks must create three voices');
    expect(engine.playCalls.every((c) => c.sourceId == engine.playCalls.first.sourceId), isTrue,
        reason: 'all voices must use the same source');
  });

  test('engine failure latches sound off', () async {
    final engine = FakeSoloudBackend()
      ..loadError = MissingPluginException('no plugin');
    UiSounds.instance.debugReset(engine: engine);

    await UiSounds.instance.selectionChanged();
    expect(engine.loadCalls.length, equals(1));
    expect(engine.playCalls, isEmpty,
        reason: 'play must not be attempted after load failure');
    // No source was created, so nothing to dispose.
    expect(engine.disposedSourceIds.length, equals(0));

    await UiSounds.instance.selectionChanged();
    expect(engine.loadCalls.length, equals(1),
        reason: 'latched engine must not reload');
  });
}
