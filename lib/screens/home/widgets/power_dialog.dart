import 'package:flutter/material.dart';
import 'package:sigg_launcher/services/page_nav_controller.dart';

/// Choice reported by [PowerDialog].
enum PowerAction { shutdown, reboot }

/// Confirmation dialog opened by the home header's power button.
///
/// While open it registers a horizontal [PageNavController] on
/// [PageFocusHub], so it follows the same input contract as the home shell
/// and sub-pages: D-pad Left/Right move the highlight, A/Start (and keyboard
/// Enter) confirm, B/Escape close. "Fechar" starts focused so a stray
/// confirm can't trigger a host shutdown or reboot by accident.
class PowerDialog extends StatefulWidget {
  const PowerDialog({super.key});

  @override
  State<PowerDialog> createState() => _PowerDialogState();
}

class _PowerDialogState extends State<PowerDialog> {
  static const List<_PowerAction> _actions = [
    _PowerAction(label: 'Desligar', icon: Icons.power_settings_new),
    _PowerAction(label: 'Reiniciar', icon: Icons.restart_alt),
    _PowerAction(label: 'Fechar', icon: Icons.close),
  ];

  final PageNavController _nav = PageNavController(axis: Axis.horizontal);

  /// Guards against popping twice. The hub controller and a natively focused
  /// button (keyboard) — or a double click / repeated confirm during the exit
  /// animation — could otherwise both call [Navigator.pop], and the second pop
  /// would remove the home route (the whole UI disappearing).
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    PageFocusHub.instance.push(_nav);
    _nav.setCount(_actions.length);
    _nav.focus(_actions.length - 1); // Safe default: "Fechar".
    _nav
      ..onActivate = _activateFocused
      ..addListener(_onNavChanged);
  }

  @override
  void dispose() {
    PageFocusHub.instance.pop(_nav);
    _nav
      ..removeListener(_onNavChanged)
      ..dispose();
    super.dispose();
  }

  void _onNavChanged() {
    if (mounted) setState(() {});
  }

  void _activateFocused() {
    if (_dismissed) return;
    _dismissed = true;
    switch (_nav.index) {
      case 0:
        Navigator.pop(context, PowerAction.shutdown);
        break;
      case 1:
        Navigator.pop(context, PowerAction.reboot);
        break;
      default:
        Navigator.pop(context);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('O que você gostaria de fazer?'),
      actions: <Widget>[
        for (var i = 0; i < _actions.length; i++)
          _PowerActionButton(
            label: _actions[i].label,
            icon: _actions[i].icon,
            focused: _nav.index == i,
            colorScheme: colorScheme,
            onTap: () {
              // Taps move the D-pad cursor too, then run the action.
              _nav.focus(i);
              _activateFocused();
            },
          ),
      ],
    );
  }
}

/// One power dialog action: its label and leading icon.
class _PowerAction {
  const _PowerAction({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

class _PowerActionButton extends StatelessWidget {
  const _PowerActionButton({
    required this.label,
    required this.icon,
    required this.focused,
    required this.colorScheme,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool focused;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // ExcludeFocus: the hub controller owns D-pad/Enter/Space activation.
    // Leaving the buttons natively focusable would let the focus system fire
    // the focused button's onPressed *in addition to* the hub's activate(),
    // double-popping the navigator (dialog + home route). Same contract as the
    // home header, which wraps its tappable content in ExcludeFocus. Mouse
    // taps still work (focus is irrelevant to gestures).
    return ExcludeFocus(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: focused
              ? colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: focused ? colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: TextButton(
          onPressed: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}
