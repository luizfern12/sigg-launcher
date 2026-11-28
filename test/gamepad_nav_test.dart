import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart';
import 'package:sigg_launcher/app_widget.dart';
import 'package:sigg_launcher/screens/home/home.dart';
import 'package:sigg_launcher/screens/home/pages/store_page.dart';
import 'package:sigg_launcher/screens/home/widgets/header.dart';
import 'package:sigg_launcher/screens/home/widgets/mock_games.dart';
import 'package:sigg_launcher/services/bgm_player.dart';
import 'package:sigg_launcher/services/game_run_state.dart';
import 'package:sigg_launcher/services/gamepad_nav.dart';
import 'package:sigg_launcher/services/nav_controller.dart';
import 'package:sigg_launcher/services/ui_sounds.dart';
import 'package:sigg_launcher/services/page_nav_controller.dart';

import 'gamepad_test_harness.dart';

Future<void> _settle(WidgetTester tester, [int rounds = 6]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _pumpLibrary(
  WidgetTester tester,
  Stream<GamepadEvent> events,
) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      navigatorObservers: [LauncherRouteObserver.instance],
      home: Library(
        games: Future.value(mockGames),
        gamepadEvents: events,
        gamepadLayout: GamepadKeyLayout.sdl3,
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _press(
  WidgetTester tester,
  StreamController<GamepadEvent> ctrl,
  GamepadEvent event,
) async {
  ctrl.add(event);
  await tester.pump();
}

Future<void> _tap(
  WidgetTester tester,
  StreamController<GamepadEvent> ctrl,
  GamepadButton button,
) async {
  await _press(tester, ctrl, buttonEvent(button, 1));
  await _press(tester, ctrl, buttonEvent(button, 0));
  await _settle(tester);
}

void main() {
  setUp(() async {
    installFakeGamepads();
    BgmPlayer.instance.debugDisable();
    UiSounds.instance.debugDisable();
    NavController.instance.debugReset();
    GamepadStatus.instance.debugReset();
    GameRunState.instance.debugReset();
    LauncherRouteObserver.instance.debugReset();
    PageFocusHub.instance.debugReset();
  });

  testWidgets('d-pad moves the selection across game covers', (tester) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    addTearDown(ctrl.close);
    await _pumpLibrary(tester, ctrl.stream);

    expect(NavController.instance.isGamesActive, isTrue);
    expect(NavController.instance.gamesIndex, 0);

    await _tap(tester, ctrl, GamepadButton.dpadRight);

    expect(NavController.instance.gamesIndex, 1);
  });

  testWidgets('left stick drives navigation like the d-pad', (tester) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    addTearDown(ctrl.close);
    await _pumpLibrary(tester, ctrl.stream);

    expect(NavController.instance.gamesIndex, 0);

    await _press(tester, ctrl, axisEvent(GamepadAxis.leftStickX, 1.0));
    expect(NavController.instance.gamesIndex, 1);
    await _press(tester, ctrl, axisEvent(GamepadAxis.leftStickX, 0.0));
    expect(NavController.instance.gamesIndex, 1);

    await _press(tester, ctrl, axisEvent(GamepadAxis.leftStickY, 1.0));
    expect(NavController.instance.isHeaderActive, isTrue);
    expect(NavController.instance.headerIndex, 0);
    await _press(tester, ctrl, axisEvent(GamepadAxis.leftStickY, 0.0));
  });

  testWidgets('holding a direction keeps repeating the move', (tester) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    addTearDown(ctrl.close);
    await _pumpLibrary(tester, ctrl.stream);

    expect(NavController.instance.gamesIndex, 0);

    await _press(tester, ctrl, buttonEvent(GamepadButton.dpadRight, 1));
    expect(NavController.instance.gamesIndex, 1);

    await tester.pump(const Duration(milliseconds: 350));
    expect(NavController.instance.gamesIndex, 2);

    await tester.pump(const Duration(milliseconds: 120));
    expect(NavController.instance.gamesIndex, 3);

    await _press(tester, ctrl, buttonEvent(GamepadButton.dpadRight, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(NavController.instance.gamesIndex, 3);
  });

  testWidgets('A opens the focused header page, B pops back, and nav is gated '
      'while a page is on top', (tester) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    addTearDown(ctrl.close);
    await _pumpLibrary(tester, ctrl.stream);

    await _tap(tester, ctrl, GamepadButton.b);
    expect(
      find.byType(StorePage),
      findsNothing,
      reason: 'B on the home shell must do nothing',
    );

    await _tap(tester, ctrl, GamepadButton.dpadUp);
    expect(NavController.instance.isHeaderActive, isTrue);
    expect(NavController.instance.headerIndex, 0);

    await _tap(tester, ctrl, GamepadButton.dpadRight);
    expect(NavController.instance.headerIndex, 1);

    await _tap(tester, ctrl, GamepadButton.a);
    expect(find.byType(StorePage), findsOneWidget);

    await _tap(tester, ctrl, GamepadButton.dpadRight);
    expect(
      NavController.instance.headerIndex,
      1,
      reason: 'gamepad input must not leak into the home shell',
    );
    expect(NavController.instance.gamesIndex, 0);

    await _tap(tester, ctrl, GamepadButton.b);
    expect(find.byType(StorePage), findsNothing);
    expect(LauncherRouteObserver.instance.isHomeTop, isTrue);
  });

  testWidgets('Start acts as confirm', (tester) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    addTearDown(ctrl.close);
    await _pumpLibrary(tester, ctrl.stream);

    await _tap(tester, ctrl, GamepadButton.dpadUp);
    await _tap(tester, ctrl, GamepadButton.dpadRight);
    await _tap(tester, ctrl, GamepadButton.start);

    expect(
      find.byType(StorePage),
      findsOneWidget,
      reason: 'Start on the store header item must open the store',
    );
  });

  testWidgets('d-pad drives the power dialog and A/B confirm or close it', (
    tester,
  ) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    addTearDown(ctrl.close);
    await _pumpLibrary(tester, ctrl.stream);

    // The power action is the last header item.
    await _tap(tester, ctrl, GamepadButton.dpadUp);
    for (var i = 0; i < 4; i++) {
      await _tap(tester, ctrl, GamepadButton.dpadRight);
    }
    expect(NavController.instance.headerIndex, 4);

    await _tap(tester, ctrl, GamepadButton.a);
    expect(find.text('O que você gostaria de fazer?'), findsOneWidget);

    // The dialog owns a focus controller; "Fechar" (last) starts focused.
    final dialogNav = PageFocusHub.instance.active;
    expect(dialogNav, isNotNull);
    expect(dialogNav!.index, 2);

    await _tap(tester, ctrl, GamepadButton.dpadLeft);
    expect(PageFocusHub.instance.active!.index, 1);
    await _tap(tester, ctrl, GamepadButton.dpadLeft);
    expect(PageFocusHub.instance.active!.index, 0);
    await _tap(tester, ctrl, GamepadButton.dpadRight);
    expect(PageFocusHub.instance.active!.index, 1);

    // A on "Reiniciar" closes the dialog; test sessions never touch the host.
    await _tap(tester, ctrl, GamepadButton.a);
    expect(find.text('O que você gostaria de fazer?'), findsNothing);
    expect(PageFocusHub.instance.active, isNull);
    expect(LauncherRouteObserver.instance.isHomeTop, isTrue);

    // Reopen and close with B.
    await _tap(tester, ctrl, GamepadButton.a);
    expect(find.text('O que você gostaria de fazer?'), findsOneWidget);
    await _tap(tester, ctrl, GamepadButton.b);
    expect(find.text('O que você gostaria de fazer?'), findsNothing);
  });

  testWidgets('gamepad input is ignored while a game is running', (
    tester,
  ) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    addTearDown(ctrl.close);
    await _pumpLibrary(tester, ctrl.stream);

    await _tap(tester, ctrl, GamepadButton.dpadRight);
    expect(NavController.instance.gamesIndex, 1);

    GameRunState.instance.setRunning(true);
    await _tap(tester, ctrl, GamepadButton.dpadRight);
    expect(
      NavController.instance.gamesIndex,
      1,
      reason: 'd-pad must be ignored while a game runs',
    );
    await _tap(tester, ctrl, GamepadButton.dpadUp);
    expect(
      NavController.instance.isGamesActive,
      isTrue,
      reason: 'zone switching must be ignored while a game runs',
    );
    await _tap(tester, ctrl, GamepadButton.a);
    await _tap(tester, ctrl, GamepadButton.b);
    expect(NavController.instance.gamesIndex, 1);
    expect(
      find.byType(StorePage),
      findsNothing,
      reason: 'confirm and B-back must be ignored while a game runs',
    );

    GameRunState.instance.setRunning(false);
    await _tap(tester, ctrl, GamepadButton.dpadRight);
    expect(NavController.instance.gamesIndex, 2);
  });

  testWidgets('held-direction repeat is cancelled when a game opens', (
    tester,
  ) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    addTearDown(ctrl.close);
    await _pumpLibrary(tester, ctrl.stream);

    await _press(tester, ctrl, buttonEvent(GamepadButton.dpadRight, 1));
    expect(NavController.instance.gamesIndex, 1);
    await tester.pump(const Duration(milliseconds: 350));
    expect(NavController.instance.gamesIndex, 2);

    GameRunState.instance.setRunning(true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      NavController.instance.gamesIndex,
      2,
      reason: 'repeat must stop once a game is open',
    );

    await _press(tester, ctrl, buttonEvent(GamepadButton.dpadRight, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(NavController.instance.gamesIndex, 2);

    GameRunState.instance.setRunning(false);
    await _tap(tester, ctrl, GamepadButton.dpadRight);
    expect(NavController.instance.gamesIndex, 3);
  });

  testWidgets('gamepad indicator shows connection state', (tester) async {
    final ctrl = StreamController<GamepadEvent>.broadcast();
    final status = GamepadStatus(
      namesLoader: () async => const ['Xbox Test Pad'],
      events: ctrl.stream,
    );
    addTearDown(ctrl.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GamepadIndicator(status: status)),
      ),
    );
    await status.refresh();
    await tester.pump();

    final connected = tester.widget<Icon>(find.byIcon(Icons.sports_esports));
    expect(connected.color, Colors.white);
    expect(find.byTooltip('Xbox Test Pad'), findsOneWidget);
  });
}
