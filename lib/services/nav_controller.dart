import 'package:flutter/foundation.dart';

import 'ui_sounds.dart';

/// The two navigable zones of the Home screen. The hero (and its Play
/// button) is intentionally not focusable.
enum HomeSection { header, games }

/// Console-style navigation state shared by every input source (keyboard
/// today, a gamepad later). Inputs only mutate this controller; the UI
/// reacts through listeners. A selection tick plays whenever focus actually
/// moves (keyboard and gamepad both route through the move methods; mouse
/// clicks use [focusHeaderItem] and intentionally stay silent).
class NavController extends ChangeNotifier {
  NavController._();

  static final NavController instance = NavController._();

  static const int headerCount = 5;

  HomeSection _section = HomeSection.games;
  int _headerIndex = 0;
  int _gamesIndex = 0;
  int _gamesCount = 0;

  HomeSection get section => _section;

  int get headerIndex => _headerIndex;

  int get gamesIndex => _gamesIndex;

  int get gamesCount => _gamesCount;

  bool get isHeaderActive => _section == HomeSection.header;

  bool get isGamesActive => _section == HomeSection.games;

  void setGamesCount(int count) {
    final clamped = count < 0 ? 0 : count;
    if (clamped == _gamesCount) return;
    _gamesCount = clamped;
    if (_gamesIndex >= _gamesCount) {
      _gamesIndex = _gamesCount > 0 ? _gamesCount - 1 : 0;
    }
    notifyListeners();
  }

  /// Callback invoked by [activate]. Home wires this up once games are ready.
  void Function()? onActivate;

  /// Resets navigation state to a freshly-launched Home (used by tests; the
  /// controller is a process-wide singleton).
  @visibleForTesting
  void debugReset() {
    _section = HomeSection.games;
    _headerIndex = 0;
    _gamesIndex = 0;
    _gamesCount = 0;
    onActivate = null;
    notifyListeners();
  }

  void moveUp() {
    if (_section == HomeSection.games) {
      _section = HomeSection.header;
      _playTick();
      notifyListeners();
    }
  }

  void moveDown() {
    if (_section == HomeSection.header) {
      _section = HomeSection.games;
      _playTick();
      notifyListeners();
    }
  }

  void focusHeader() {
    if (_section != HomeSection.header) {
      _section = HomeSection.header;
      _playTick();
      notifyListeners();
    }
  }

  /// Moves focus to the header zone and positions the selection on the given
  /// header item. Used when a header entry is clicked, so that pressing
  /// Enter afterwards re-activates that same item.
  void focusHeaderItem(int index) {
    final clamped = index.clamp(0, headerCount - 1);
    final changed = _section != HomeSection.header || _headerIndex != clamped;
    _section = HomeSection.header;
    _headerIndex = clamped;
    if (changed) notifyListeners();
  }

  /// Moves focus to the games zone and positions the selection on the given
  /// cell (used when a cover / "Ver todos" card is clicked, so pressing Enter
  /// afterwards re-activates that same item).
  void focusGamesItem(int index) {
    final max = _gamesCount > 0 ? _gamesCount - 1 : 0;
    final clamped = index.clamp(0, max);
    final changed = _section != HomeSection.games || _gamesIndex != clamped;
    _section = HomeSection.games;
    _gamesIndex = clamped;
    if (changed) notifyListeners();
  }

  void moveLeft() {
    switch (_section) {
      case HomeSection.header:
        if (_headerIndex > 0) {
          _headerIndex--;
          _playTick();
          notifyListeners();
        }
        break;
      case HomeSection.games:
        if (_gamesIndex > 0) {
          _gamesIndex--;
          _playTick();
          notifyListeners();
        }
        break;
    }
  }

  void moveRight() {
    switch (_section) {
      case HomeSection.header:
        if (_headerIndex < headerCount - 1) {
          _headerIndex++;
          _playTick();
          notifyListeners();
        }
        break;
      case HomeSection.games:
        if (_gamesCount > 0 && _gamesIndex < _gamesCount - 1) {
          _gamesIndex++;
          _playTick();
          notifyListeners();
        }
        break;
    }
  }

  /// Confirms the currently focused item. The actual action is provided by
  /// the Home screen via [onActivate], so gamepad input can trigger it too.
  void activate() {
    onActivate?.call();
  }

  /// Console selection blip, fired every time focus actually moves. Played
  /// from here — not the UI listener — so keyboard, gamepad and synthetic
  /// inputs all sound the same, while mouse-driven paths ([focusHeaderItem],
  /// taps) stay silent.
  void _playTick() {
    UiSounds.instance.selectionChanged();
  }
}
