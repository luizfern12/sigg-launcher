import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';
import 'package:sigg_launcher/screens/home/pages/achievements_page.dart';
import 'package:sigg_launcher/screens/home/pages/library_page.dart';
import 'package:sigg_launcher/screens/home/pages/settings_page.dart';
import 'package:sigg_launcher/screens/home/pages/store_page.dart';
import 'package:sigg_launcher/screens/home/widgets/games_row.dart';
import 'package:sigg_launcher/screens/home/widgets/header.dart';
import 'package:sigg_launcher/screens/home/widgets/hero_banner.dart';
import 'package:sigg_launcher/screens/home/widgets/mock_games.dart';
import 'package:sigg_launcher/screens/home/widgets/power_dialog.dart';
import 'package:sigg_launcher/screens/home/widgets/user_switcher.dart';
import 'package:sigg_launcher/services/achievement_service.dart';
import 'package:sigg_launcher/services/bgm_player.dart';
import 'package:sigg_launcher/services/game_launcher.dart';
import 'package:sigg_launcher/services/game_loader.dart';
import 'package:sigg_launcher/services/game_run_state.dart';
import 'package:sigg_launcher/services/gamepad_nav.dart';
import 'package:sigg_launcher/services/image_cache.dart';
import 'package:sigg_launcher/services/nav_controller.dart';
import 'package:sigg_launcher/services/page_nav_controller.dart';
import 'package:sigg_launcher/services/software_registry.dart';
import 'package:sigg_launcher/services/system_service.dart';

const double _gamesSectionMinHeight = 240;

class Library extends StatefulWidget {
  const Library({
    super.key,
    this.games,
    this.gamepadEvents,
    this.gamepadLayout,
    this.achievementsService,
  });

  /// Pre-computed game list. Used by tests to inject a future resolved
  /// outside of Flutter's fake-async test zone; when null the screen loads
  /// software from the [kSoftwareFolder] registry (games + apps).
  final Future<List<GameEntry>>? games;

  /// Raw gamepad event source, matching the `xyz.luan/gamepads` wire. Used by
  /// tests to drive navigation with synthetic events; when null the real
  /// [Gamepads.events] stream is used.
  final Stream<GamepadEvent>? gamepadEvents;

  /// Overrides the raw key numbering of [gamepadEvents]; when null it is
  /// detected from the embedder (see [detectGamepadKeyLayout]). Tests inject
  /// [GamepadKeyLayout.sdl3] to exercise the ivi-homescreen contract.
  final GamepadKeyLayout? gamepadLayout;

  /// Trophy daemon client. Used by tests to inject a fake daemon into the
  /// trophies submenu; when null the real unix-socket [AchievementService] is
  /// used (it just fails to connect and the page shows the unavailable state).
  final AchievementService? achievementsService;

  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  late Future<List<GameEntry>> _games;
  late final GamepadNavBridge _gamepadBridge;
  List<GameEntry> _gamesList = const [];
  final ValueNotifier<GameEntry?> _selected = ValueNotifier<GameEntry?>(null);
  final ValueNotifier<bool> _gamesActive = ValueNotifier<bool>(true);
  final ValueNotifier<int> _gamesIndex = ValueNotifier<int>(0);
  final ValueNotifier<bool> _headerActive = ValueNotifier<bool>(false);
  final ValueNotifier<int> _headerIndex = ValueNotifier<int>(0);
  bool _wasGameRunning = false;
  Size _heroSize = Size.zero;
  Timer? _preloadDebounce;
  final ScrollController _gamesScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadGames();
    NavController.instance.addListener(_onNavChanged);
    GameRunState.instance.addListener(_onRunStateChanged);
    // Installs/uninstalls in the store re-scan the registry so new software
    // shows up in the home row without a restart.
    SoftwareRegistry.instance.addListener(_onRegistryChanged);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    NavController.instance.onActivate = _onActivate;
    _gamepadBridge = GamepadNavBridge(
      events: widget.gamepadEvents,
      layout: widget.gamepadLayout,
    );
    GamepadStatus.instance.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        NavController.instance.setGamesCount(_gamesList.length + 1);
      }
    });
    _headerActive.value = NavController.instance.isHeaderActive;
    _headerIndex.value = NavController.instance.headerIndex;
  }

  @override
  void dispose() {
    NavController.instance.removeListener(_onNavChanged);
    GameRunState.instance.removeListener(_onRunStateChanged);
    SoftwareRegistry.instance.removeListener(_onRegistryChanged);
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    if (NavController.instance.onActivate == _onActivate) {
      NavController.instance.onActivate = null;
    }
    _gamepadBridge.dispose();
    GamepadStatus.instance.stop();
    _preloadDebounce?.cancel();
    _selected.dispose();
    _gamesActive.dispose();
    _gamesIndex.dispose();
    _headerActive.dispose();
    _headerIndex.dispose();
    _gamesScroll.dispose();
    super.dispose();
  }

  /// (Re)reads the game list. First run happens in [initState]; later runs
  /// come from [_onRegistryChanged] after a store install/uninstall. Swaps
  /// the future so the existing `FutureBuilder` re-runs with the fresh list.
  void _loadGames() {
    _games = (widget.games ??
            GameLoader(
              gamesFolder: kGamesFolder,
              appsFolder: kAppsFolder,
            ).load())
        .then((list) {
          _gamesList = list;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              // +1 for the trailing "Ver todos" card, which is D-pad
              // focusable so the full library is reachable without a mouse.
              NavController.instance.setGamesCount(list.length + 1);
              if (list.isNotEmpty) _preloadAdjacent(list.first);
              _resyncSelection(list);
            }
          });
          return list;
        });
    setState(() {});
  }

  /// The registry changed (install/uninstall): re-scan so the home row and
  /// hero pick up the new software without an app restart.
  void _onRegistryChanged() {
    if (!mounted) return;
    _loadGames();
  }

  /// After a reload the selected entry is a stale object (fresh scan) or is
  /// gone entirely (uninstalled): re-point it so the hero never shows a
  /// removed game. BGM is only touched when the selection really changed —
  /// a plain reload rebuilds instances but keeps the same game, and the
  /// initial load has no selection yet (BGM starts on the first move, not
  /// on startup).
  void _resyncSelection(List<GameEntry> list) {
    final previous = _selected.value;
    if (previous == null) return; // Initial load: hero falls back to first.
    if (list.isEmpty) {
      _selected.value = null;
      BgmPlayer.instance.stop();
      return;
    }
    final index = NavController.instance.gamesIndex.clamp(0, list.length - 1);
    final next = list[index];
    if (identical(previous, next)) return;
    _selected.value = next;
    if (previous.id != next.id) {
      final bgm = next.bgmPath;
      if (bgm != null) {
        BgmPlayer.instance.play(bgm);
      } else {
        BgmPlayer.instance.stop();
      }
    }
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }
    // Directions intentionally repeat for list navigation; confirm and back
    // are edge-triggered. Repeating Enter/Escape during a route transition can
    // push the same submenu twice or pop through more than one page.
    if (event is KeyRepeatEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
            event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.escape)) {
      return true;
    }
    // Only drive navigation while Home is the active route. The Launcher
    // keyboard listener stays alive under pushed submenus, so it owns the
    // keyboard back shortcut there (submenus have no back button; gamepad B is
    // the primary way out and keyboard users get Escape). It also drives the
    // D-pad-navigable submenus (trophies, store, settings, profile switcher)
    // with the same keys the gamepad bridge uses: arrows move the topmost
    // page's focus, Enter/Space confirm, Escape backs out. Any other pushed
    // page (dialogs) owns no focus controller, so arrows are inert there —
    // exact gamepad parity.
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) {
      final page = PageFocusHub.instance.active;
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          page?.moveUp();
          return page != null;
        case LogicalKeyboardKey.arrowDown:
          page?.moveDown();
          return page != null;
        case LogicalKeyboardKey.arrowLeft:
          page?.moveLeft();
          return page != null;
        case LogicalKeyboardKey.arrowRight:
          page?.moveRight();
          return page != null;
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.numpadEnter:
        case LogicalKeyboardKey.space:
          page?.activate();
          return page != null;
        case LogicalKeyboardKey.escape:
          Navigator.of(context).maybePop();
          return true;
        default:
          return false;
      }
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        NavController.instance.moveUp();
        return true;
      case LogicalKeyboardKey.arrowDown:
        NavController.instance.moveDown();
        return true;
      case LogicalKeyboardKey.arrowLeft:
        NavController.instance.moveLeft();
        return true;
      case LogicalKeyboardKey.arrowRight:
        NavController.instance.moveRight();
        return true;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.space:
        NavController.instance.activate();
        return true;
      default:
        return false;
    }
  }

  void _onNavChanged() {
    if (!mounted) return;
    _gamesActive.value = NavController.instance.isGamesActive;
    _gamesIndex.value = NavController.instance.gamesIndex;
    _headerActive.value = NavController.instance.isHeaderActive;
    _headerIndex.value = NavController.instance.headerIndex;
    if (NavController.instance.isGamesActive) {
      final games = _snapshotData();
      final index = NavController.instance.gamesIndex;
      if (index >= 0 && index < games.length) {
        _selectGame(games[index]);
      }
    }
  }

  void _onRunStateChanged() {
    if (!mounted) return;
    final running = GameRunState.instance.running;
    if (_wasGameRunning && !running) {
      _resumeSelectedBgm();
    }
    _wasGameRunning = running;
  }

  void _resumeSelectedBgm() {
    final selected = _selected.value;
    if (selected == null) return;
    final bgm = selected.bgmPath;
    if (bgm != null) {
      BgmPlayer.instance.play(bgm);
    } else {
      BgmPlayer.instance.stop();
    }
  }

  void _onActivate() {
    if (!mounted) return;
    if (NavController.instance.isHeaderActive) {
      _activateHeader(NavController.instance.headerIndex);
      return;
    }
    // The trailing "Ver todos" card is the cell right after the last game.
    if (NavController.instance.gamesIndex >= _gamesList.length) {
      _openLibrary();
      return;
    }
    _activateGame(_selected.value);
  }

  void _activateHeader(int index) {
    switch (index) {
      case 0:
        showUserSwitcher(context);
        break;
      case 1:
        _openPage(const StorePage());
        break;
      case 2:
        _openPage(
          AchievementsPage(
            games: Future.value(_gamesList),
            service: widget.achievementsService,
          ),
        );
        break;
      case 3:
        _openPage(const SettingsPage());
        break;
      case 4:
        _showPowerDialog();
        break;
    }
  }

  void _activateGame(GameEntry? game) {
    if (game == null) return;
    GameLauncher.launch(context, game);
  }

  void _openLibrary() {
    _openPage(LibraryPage(games: Future.value(_gamesList)));
  }

  /// Shutdown/reboot confirmation dialog opened from the power button.
  ///
  /// The dialog registers its own [PageNavController] on [PageFocusHub] (like
  /// a pushed sub-page), so gamepad/keyboard input routes to its buttons
  /// instead of leaking into the home shell — hence no [PageFocusHub.suspend]
  /// here. Debug and test sessions never reach the host (see [SystemService]).
  Future<void> _showPowerDialog() async {
    final choice = await showDialog<PowerAction>(
      context: context,
      builder: (context) => const PowerDialog(),
    );
    if (choice == null) return;
    // Debug/test sessions never reach the host.
    if (SystemService.instance.isSafeSession) return;
    final ok = await SystemService.instance.request(
      choice == PowerAction.shutdown
          ? PowerRequest.powerOff
          : PowerRequest.reboot,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Não foi possível desligar ou reiniciar o sistema.'),
            duration: Duration(seconds: 4),
          ),
        );
    }
  }

  List<GameEntry> _snapshotData() => _gamesList;

  void _selectGame(GameEntry game) {
    if (identical(_selected.value, game)) return;
    _selected.value = game;
    _scheduleHeroPreload(game);
    final bgm = game.bgmPath;
    if (bgm != null) {
      BgmPlayer.instance.play(bgm);
    } else {
      BgmPlayer.instance.stop();
    }
  }

  void _scheduleHeroPreload(GameEntry game) {
    // Debounced: a fast burst of moves settles into a single preload of the
    // final hero's neighborhood instead of re-decoding 5 heroes per keystroke
    // (which saturated the image cache and force-evicted completers mid-frame,
    // triggering the Flutter framework "_nextFrame != null" animation race).
    _preloadDebounce?.cancel();
    _preloadDebounce = Timer(
      const Duration(milliseconds: 150),
      () => _preloadAdjacent(game),
    );
  }

  void _preloadAdjacent(GameEntry game) {
    final games = _gamesList;
    if (games.isEmpty || _heroSize == Size.zero) return;
    final index = games.indexOf(game);
    if (index < 0) return;
    ImagePreloader.preloadHeroes(context, games, index, _heroSize, range: 2);
  }

  void _openPage(Widget page) {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ExcludeFocus(
        child: FutureBuilder<List<GameEntry>>(
          future: _games,
          builder: (context, snapshot) {
            // On a registry-triggered reload the previous list keeps showing
            // (no spinner flash); the initial load has nothing cached yet.
            final games = snapshot.data ?? _gamesList;
            if (snapshot.connectionState != ConnectionState.done &&
                games.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (games.isEmpty) {
              return const Center(
                child: Text('Nenhum jogo encontrado na pasta "games".'),
              );
            }

            return _FadeIn(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final ratioHeroHeight =
                      constraints.maxWidth / heroAspectRatio;
                  final maxHeroHeight =
                      (constraints.maxHeight - _gamesSectionMinHeight).clamp(
                        0.0,
                        double.infinity,
                      );
                  final heroHeight = math.min(ratioHeroHeight, maxHeroHeight);
                  _heroSize = Size(constraints.maxWidth, heroHeight);

                  return Column(
                    children: [
                      SizedBox(
                        height: heroHeight,
                        width: double.infinity,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ListenableBuilder(
                                listenable: _selected,
                                builder: (context, _) {
                                  final selected =
                                      _selected.value ?? games.first;
                                  return AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 300),
                                    switchInCurve: Curves.easeOut,
                                    switchOutCurve: Curves.easeInOut,
                                    transitionBuilder: (child, animation) {
                                      return FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      );
                                    },
                                    child: KeyedSubtree(
                                      key: ObjectKey(selected),
                                      child: HeroBanner(game: selected),
                                    ),
                                  );
                                },
                              ),
                            ),
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: ListenableBuilder(
                                listenable: Listenable.merge([
                                  _headerActive,
                                  _headerIndex,
                                ]),
                                builder: (context, _) {
                                  return Header(
                                    active: _headerActive.value,
                                    focusedIndex: _headerIndex.value,
                                    onStoreTap: () {
                                      NavController.instance.focusHeaderItem(1);
                                      _openPage(const StorePage());
                                    },
                                    onTrophiesTap: () {
                                      NavController.instance.focusHeaderItem(2);
                                      _openPage(
                                        AchievementsPage(
                                          games: Future.value(_gamesList),
                                          service: widget.achievementsService,
                                        ),
                                      );
                                    },
                                    onSettingsTap: () {
                                      NavController.instance.focusHeaderItem(3);
                                      _openPage(const SettingsPage());
                                    },
                                    onPowerTap: () async {
                                      NavController.instance.focusHeaderItem(4);
                                      await _showPowerDialog();
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: ListenableBuilder(
                                    listenable: Listenable.merge([
                                      _gamesActive,
                                      _gamesIndex,
                                    ]),
                                    builder: (context, _) {
                                      return GamesRow(
                                        games: games,
                                        active: _gamesActive.value,
                                        focusIndex: _gamesIndex.value,
                                        scrollController: _gamesScroll,
                                        onGameTap: (game) {
                                          // Taps move the D-pad cursor too, so
                                          // the highlighted cover always
                                          // matches the hero/BGM selection.
                                          final index = games.indexOf(game);
                                          if (index >= 0) {
                                            NavController.instance
                                                .focusGamesItem(index);
                                          }
                                          _selectGame(game);
                                        },
                                        onSeeAllTap: () {
                                          // Park the home cursor on the card
                                          // so Enter re-opens the library
                                          // after coming back.
                                          NavController.instance.focusGamesItem(
                                            games.length,
                                          );
                                          _openLibrary();
                                        },
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FadeIn extends StatefulWidget {
  const _FadeIn({required this.child});

  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  )..forward();
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}
