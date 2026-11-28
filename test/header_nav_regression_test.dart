import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sigg_launcher/app_widget.dart';
import 'package:sigg_launcher/screens/home/home.dart';
import 'package:sigg_launcher/screens/home/pages/store_page.dart';
import 'package:sigg_launcher/screens/home/widgets/mock_games.dart';
import 'package:sigg_launcher/services/bgm_player.dart';
import 'package:sigg_launcher/services/game_loader.dart';
import 'package:sigg_launcher/services/gamepad_nav.dart';
import 'package:sigg_launcher/services/nav_controller.dart';
import 'package:sigg_launcher/services/ui_sounds.dart';

import 'gamepad_test_harness.dart';

const _gameProcessPattern =
    r'DELTARUNE|Funkin|superTux|supertux2|UNDERTALE|Half-Life|rungameid';

Future<bool> anyGameProcessRunning() async {
  final result = await Process.run('pgrep', ['-f', _gameProcessPattern]);
  return result.exitCode == 0;
}

Future<void> killGameProcesses() async {
  await Process.run('pkill', ['-9', '-f', _gameProcessPattern]);
}

Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await settle(tester);
}

Future<bool> isGameProcessRunning(WidgetTester tester) async {
  var running = false;
  await tester.runAsync(() async {
    running = await anyGameProcessRunning();
  });
  return running;
}

Future<void> killGameProcessesInTest(WidgetTester tester) async {
  await tester.runAsync(killGameProcesses);
}

void main() {
  setUp(() async {
    await killGameProcesses();
    installFakeGamepads();
    BgmPlayer.instance.debugDisable();
    UiSounds.instance.debugDisable();
    NavController.instance.debugReset();
    GamepadStatus.instance.debugReset();
    LauncherRouteObserver.instance.debugReset();
  });

  tearDown(() async {
    await killGameProcesses();
  });

  Future<Future<List<GameEntry>>> resolveGames(WidgetTester tester) async {
    final completer = Completer<List<GameEntry>>();
    await tester.runAsync(() async {
      final games = await GameLoader(
        gamesFolder: kGamesFolder,
        appsFolder: kAppsFolder,
      ).load();
      completer.complete(games);
    });
    return completer.future;
  }

  Future<void> pumpLibrary(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    final games = await resolveGames(tester);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Library(games: games),
      ),
    );
    await settle(tester);
  }

  Future<void> stall(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await settle(tester);
  }

  Future<void> expectNoLaunch(WidgetTester tester) async {
    await stall(tester);
    expect(
      await isGameProcessRunning(tester),
      isFalse,
      reason: 'a game process was started unexpectedly',
    );
  }

  testWidgets('Enter in the games zone still launches the selected game', (
    tester,
  ) async {
    await pumpLibrary(tester);
    expect(NavController.instance.isGamesActive, isTrue);

    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    expect(NavController.instance.isGamesActive, isTrue);
    expect(NavController.instance.gamesIndex, 1);

    await pressKey(tester, LogicalKeyboardKey.enter);
    await stall(tester);

    expect(
      await isGameProcessRunning(tester),
      isTrue,
      reason: 'sanity: pressing Enter on a game cover must launch a game',
    );
    await killGameProcessesInTest(tester);
  });

  testWidgets(
    'clicking a header icon and later pressing Enter must NOT launch a game',
    (tester) async {
      await pumpLibrary(tester);
      expect(NavController.instance.isGamesActive, isTrue);

      await tester.tap(find.byIcon(Icons.local_mall));
      await settle(tester);

      expect(
        find.byType(StorePage),
        findsOneWidget,
        reason: 'clicking the store icon must open the store page',
      );
      await expectNoLaunch(tester);

      await pressKey(tester, LogicalKeyboardKey.escape);
      await settle(tester);

      expect(
        NavController.instance.isHeaderActive,
        isTrue,
        reason: 'clicking the header icon must put the header zone in focus',
      );

      await pressKey(tester, LogicalKeyboardKey.enter);

      expect(
        find.byType(StorePage),
        findsOneWidget,
        reason: 'Enter after closing must re-open the store (header action)',
      );
      await expectNoLaunch(tester);
    },
  );

  testWidgets('navigating the header by keyboard then Enter opens the page', (
    tester,
  ) async {
    await pumpLibrary(tester);

    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(NavController.instance.isHeaderActive, isTrue);

    await pressKey(tester, LogicalKeyboardKey.arrowRight);

    await pressKey(tester, LogicalKeyboardKey.enter);

    expect(
      find.byType(StorePage),
      findsOneWidget,
      reason: 'Enter on the store icon must open the store page',
    );
    await expectNoLaunch(tester);
  });

  testWidgets('focused header items reveal a tooltip for nav input', (
    tester,
  ) async {
    await pumpLibrary(tester);

    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(
      find.text('Perfil'),
      findsOneWidget,
      reason: 'entering the header zone must show the profile tooltip',
    );

    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('IFSCstation Store'), findsOneWidget);

    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Troféus'), findsOneWidget);

    await pressKey(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Configurações'), findsOneWidget);

    await pressKey(tester, LogicalKeyboardKey.arrowDown);
    expect(
      find.text('Configurações'),
      findsNothing,
      reason: 'leaving the header zone must hide the tooltip',
    );
  });

  testWidgets('the power button is the last header item and opens its dialog', (
    tester,
  ) async {
    await pumpLibrary(tester);

    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    expect(NavController.instance.headerIndex, 0);

    for (var i = 0; i < 4; i++) {
      await pressKey(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(NavController.instance.headerIndex, 4);
    expect(
      find.text('Desligar'),
      findsOneWidget,
      reason: 'the power button must show its tooltip when focused',
    );

    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);

    expect(
      find.text('O que você gostaria de fazer?'),
      findsOneWidget,
      reason: 'Enter on the power button must open the shutdown dialog',
    );

    // Fechar closes the dialog; test sessions never reach the host.
    await tester.tap(find.text('Fechar'));
    await settle(tester);

    expect(
      find.text('O que você gostaria de fazer?'),
      findsNothing,
      reason: 'tapping Fechar must close the dialog',
    );
  });

  testWidgets('Enter in the power dialog pops only the dialog, not home', (
    tester,
  ) async {
    await pumpLibrary(tester);

    await pressKey(tester, LogicalKeyboardKey.arrowUp);
    for (var i = 0; i < 4; i++) {
      await pressKey(tester, LogicalKeyboardKey.arrowRight);
    }
    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.text('O que você gostaria de fazer?'), findsOneWidget);

    // Tab used to move native focus onto a dialog button; Enter then fired
    // both the hub controller and the focused button's onPressed, popping the
    // dialog AND the home route. The dialog keeps activation hub-only, so the
    // same sequence must leave the home screen intact.
    await pressKey(tester, LogicalKeyboardKey.tab);
    await pressKey(tester, LogicalKeyboardKey.enter);
    await settle(tester);

    expect(find.text('O que você gostaria de fazer?'), findsNothing);
    expect(
      find.byType(Library),
      findsOneWidget,
      reason: 'the home route must survive the dialog pop',
    );
  });
}
